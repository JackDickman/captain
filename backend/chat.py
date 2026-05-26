"""
Chat handler + background memory updates.

Each user message triggers:
  1. (Foreground) Build a system prompt from ALL context — the home and
     owner markdown profiles, recent calendar, weather, current date/time,
     recent conversation — call the LLM, persist user + assistant
     messages, return.
  2. (Background) Two parallel jobs:
     a. Rewrite the markdown profiles (home.md + user.md) integrating any
        new specifics from the exchange. See profiles.py.
     b. Extract any dated calendar entries (past events / future intents /
        recurring / observations) and append them to the structured
        calendar table.

The profile rewrite is the durable narrative memory. The calendar stays
structured because dates need to be queryable for the radar + digest
features.

Both LLM models are swappable per env var (PRD §9.1).
"""

from __future__ import annotations

import base64
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

from openai import OpenAI

from . import profiles, radar, store

# Chat is the user-facing brain — the success criterion "noticeably better
# than ChatGPT" lives here. Use the strongest mini we can.
CHAT_MODEL = os.getenv("CAPTAIN_CHAT_MODEL", "gpt-5.4-mini")
# Calendar extraction is simple structured JSON; nano is plenty.
CALENDAR_MODEL = os.getenv("CAPTAIN_CALENDAR_MODEL", "gpt-5.4-nano")
# Scope gate runs on every text message before the main chat call.
# Nano-class — a yes/no/yes-but classifier, not a reasoning task.
SCOPE_MODEL = os.getenv("CAPTAIN_SCOPE_MODEL", "gpt-5.4-nano")

# Hardcoded for v1. When iOS sends a real address, first-session should
# geocode and persist lat/lng to home row.
DEFAULT_LAT = 41.500
DEFAULT_LNG = -81.555

CALENDAR_SCHEMA = {
    "type": "object",
    "properties": {
        "new_calendar_entries": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "text": {"type": "string"},
                    "occurred_at": {
                        "type": ["string", "null"],
                        "description": (
                            "ISO date (YYYY-MM-DD) or datetime, or null "
                            "for undated intents / recurring items."
                        ),
                    },
                    "kind": {
                        "type": "string",
                        "enum": [
                            "past", "future", "recurring", "observation",
                        ],
                    },
                },
                "required": ["text", "occurred_at", "kind"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["new_calendar_entries"],
    "additionalProperties": False,
}


# ---------- Scope gate ----------

SCOPE_SCHEMA = {
    "type": "object",
    "properties": {
        "scope": {
            "type": "string",
            "enum": ["in_scope", "off_topic", "out_of_capability"],
        },
        "reason": {
            "type": "string",
            "description": "One short sentence; for server logs only.",
        },
    },
    "required": ["scope", "reason"],
    "additionalProperties": False,
}

# Canned replies for the two gated cases. Tone-matched to Captain
# (quiet, observant, gently redirecting — never a chatbot guardrail).
OFF_TOPIC_REPLY = (
    "That's a bit outside my lane — I stay close to your home and the "
    "work of keeping it up. Happy to dig into anything about the house, "
    "the yard, household routines, vendors, or how the weather's "
    "affecting things."
)

OUT_OF_CAPABILITY_REPLY = (
    "I can talk that through with you, but I can't do it myself — I "
    "can't generate images, send messages, browse the live web, or "
    "take actions out in the world. If you want to think through the "
    "decision or what your next step is, I'm here for that."
)


def classify_message_scope(user_message: str) -> tuple[str, str]:
    """Cheap pre-flight on an incoming chat message. Returns (scope, reason).

    scope:
      - "in_scope": anything about the home, its care, household life
        related to the home, vendor decisions, the owner's preferences,
        or normal small-talk continuation in that thread. DEFAULT —
        lean lenient.
      - "off_topic": clearly not about the home or homeownership —
        homework help, coding questions, dating, sports debates,
        unrelated work problems, current events, etc.
      - "out_of_capability": asks Captain to DO something it can't —
        generate images, send emails / messages, browse the live web,
        control smart devices, place orders, take actions in the world.

    `reason` is captured for server logs only; iOS sees only the canned
    user-facing reply for the gated cases.

    Soft-fails open: on any classifier exception, we return in_scope so
    a flaky model never blocks a real user.
    """
    sys_prompt = (
        "You are a fast topic + capability gate for Captain, an AI helper "
        "dedicated to a single homeowner and their specific home. Captain "
        "helps with: home maintenance, repairs, landscaping, decor, "
        "vendors, seasonal upkeep, neighborhood context, household "
        "routines, weather-aware decisions, and anything else where the "
        "user's home or life-as-a-homeowner is the subject.\n\n"
        "Captain CAN reason and converse but CANNOT: generate images, "
        "send messages or emails on the user's behalf, browse the live "
        "web, control smart devices or appliances, place orders, schedule "
        "appointments, or take any other actions out in the world.\n\n"
        "Classify the user's message into exactly one of:\n"
        "  - in_scope: about the home, its care, owner's home life, or "
        "    a continuation/small-talk in that thread.\n"
        "  - off_topic: clearly not about the home — homework, code, "
        "    dating, sports trivia, unrelated work problems, etc.\n"
        "  - out_of_capability: asking Captain to DO something it can't.\n\n"
        "LEAN GENEROUS on in_scope. Short answers, feelings about the "
        "house, tangents that touch home life, vague questions where home "
        "context is plausible — all in_scope. Mark off_topic only when "
        "the message has nothing to do with the user's home or life in "
        "it. Mark out_of_capability only when the user is asking Captain "
        "to PERFORM an action it can't, not just discuss it.\n\n"
        f"Message: {user_message}"
    )

    try:
        client = OpenAI()
        resp = client.chat.completions.create(
            model=SCOPE_MODEL,
            messages=[{"role": "system", "content": sys_prompt}],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "scope_check",
                    "schema": SCOPE_SCHEMA,
                    "strict": True,
                },
            },
        )
        payload = json.loads(resp.choices[0].message.content)
        return (
            payload.get("scope", "in_scope"),
            payload.get("reason", ""),
        )
    except Exception as e:  # noqa: BLE001
        print(f"[scope] classifier failed (accepting message): {e}")
        return "in_scope", ""


def _build_system_prompt(home: dict, calendar: list[dict],
                         weather: str) -> str:
    """Build the chat system prompt from markdown profiles + structured
    calendar + ambient context (weather, date/time)."""
    now = datetime.now(timezone.utc).astimezone()
    today = now.strftime("%A, %B %-d, %Y")
    local_time = now.strftime("%-I:%M %p")

    home_md = profiles.read_home_md().strip()
    user_md = profiles.read_user_md().strip()

    calendar_block = (
        "\n".join(
            f"  - [{c['kind']}] {c['text']}"
            + (f" ({c['occurred_at']})" if c["occurred_at"] else "")
            for c in calendar[:15]
        )
        if calendar else "  (empty)"
    )
    weather_block = weather or "(weather unavailable right now)"

    return f"""You are Captain — a quiet, observant, attentive AI helper for the homeowner of a specific home. You are NOT a generic chatbot. Your domain is this person's home, its care, and the practical work of being a homeowner.

Identity and tone:
  - The home is the main character. The owner is its steward. You're its biographer.
  - You speak in plain language; define jargon inline ONLY if the owner profile suggests they need it. If they've shown technical familiarity, skip basics.
  - You're calm and concrete, never barky or task-driven. You don't perform enthusiasm.
  - You help the owner *decide* what to do and *who* to call. You're a judgment layer, not a search engine.
  - You NEVER mention sale prices, market values, tax assessments, or any other financial valuation of the home. This app deliberately avoids financial surfaces.
  - You don't read the profiles back to the owner unless they ask — they don't want a recital, they want help.
  - When the owner shares a new fact about the home or themselves, acknowledge briefly and naturally — don't make a fuss about remembering it. The memory layer handles that silently in the background.

Today is {today}. Local time is approximately {local_time}.

Weather forecast for this location:
{weather_block}

THIS HOME (everything you know — written narrative, do NOT recite verbatim):
```markdown
{home_md}
```

THIS OWNER (everything you know about them — written narrative):
```markdown
{user_md}
```

RECENT EVENTS AND UPCOMING ITEMS ON THIS HOME'S CALENDAR (most recent first):
{calendar_block}

When you respond:
  - Use the context above to be specific to THIS home and THIS owner. Generic answers betray the whole product.
  - Keep responses concise unless the question genuinely warrants depth. Long lectures break the conversation.

Drawing out durable details (the biographer's instinct):
  Part of your job is to capture specifics the owner will be glad to have a year from now. When a conversation naturally touches a moment where a concrete number, brand, vendor, or measurement would be useful later, ask one quiet follow-up — at the END of your response, after you've actually helped — to surface it. Examples:
    - mulching the beds → "Out of curiosity, how many bags did you end up needing? Worth jotting down for next spring."
    - painting the trim → "What paint did you use? — handy to have on file when you need to touch up."
    - had a plumber out → "Who did the work? I'll keep their name on hand."
    - planted hostas → "How many did you put in? And what variety, if you know?"
    - replaced a furnace filter → "What size and brand? I'll remember it for the next swap."
    - paid for tree trimming → "Roughly how often do you have that done?" (NEVER ask the cost — financial surfaces are off-limits.)
  Hard rules for these questions:
    - One question per response, maximum. Two questions in one turn reads as an interview.
    - Never lead with the question. Help first; ask second, only if there's a real fact worth pinning.
    - Skip the ask when the owner clearly wants a quick answer, is venting/frustrated, or the conversation is about feelings/aesthetics rather than concrete work.
    - Skip the ask if the answer is already in the home or owner profile.
    - Phrasing should feel like a curious friend, not a form: "Out of curiosity…", "Worth noting — did you…", "What brand did you go with?" — never "Please provide…" or "For my records…".
    - NEVER ask about prices paid, costs, or financial figures."""


def _image_part(path: Path) -> dict:
    """Encode an on-disk image as an OpenAI vision content part."""
    img_b64 = base64.b64encode(path.read_bytes()).decode()
    suffix = path.suffix.lower().lstrip(".")
    mime = "jpeg" if suffix == "jpg" else suffix
    return {
        "type": "image_url",
        "image_url": {"url": f"data:image/{mime};base64,{img_b64}"},
    }


def respond_to_message(
    home_id: int, user_message: str,
    image_paths: list[Path] | None = None,
    image_urls: list[str] | None = None,
) -> str:
    """Foreground: call LLM with full context, persist messages, return text.

    If any `image_paths` are given, they're included in the LLM's user
    message as vision inputs. `image_urls` are the relative paths stored
    on the message row so iOS can render bubbles.
    """
    from .weather import get_forecast_summary

    home = store.get_home() or {}
    calendar = store.get_calendar(home_id)

    lat = home.get("lat") or DEFAULT_LAT
    lng = home.get("lng") or DEFAULT_LNG
    weather = get_forecast_summary(lat, lng)

    conv_id = store.get_or_create_conversation(home_id)
    history = store.get_recent_messages(conv_id, limit=20)

    system_prompt = _build_system_prompt(home, calendar, weather)
    messages: list[dict] = [{"role": "system", "content": system_prompt}]
    # Replay history as plain text (we don't re-send historical images —
    # the model has already seen their extracted facts via the profile
    # markdown, and re-uploading them every turn would explode cost).
    for m in history:
        messages.append({"role": m["role"], "content": m["content"]})

    # Latest user message: optionally multimodal with N images.
    valid_paths = [p for p in (image_paths or []) if p.exists()]
    if valid_paths:
        content: list[dict] = [{
            "type": "text",
            "text": user_message
                or f"(attached {len(valid_paths)} photo"
                   f"{'s' if len(valid_paths) > 1 else ''})",
        }]
        for p in valid_paths:
            content.append(_image_part(p))
        messages.append({"role": "user", "content": content})
    else:
        messages.append({"role": "user", "content": user_message})

    client = OpenAI()
    resp = client.chat.completions.create(
        model=CHAT_MODEL,
        messages=messages,
        temperature=0.7,
    )
    assistant_text = resp.choices[0].message.content or ""

    store.add_message(conv_id, "user", user_message, image_urls=image_urls)
    store.add_message(conv_id, "assistant", assistant_text)

    return assistant_text


def extract_calendar_updates(home_id: int, user_message: str,
                             assistant_message: str) -> dict:
    """Background: scan the exchange for any dated events worth pinning to
    the calendar. Separate from the profile rewrite because (a) calendar
    stays structured and (b) different LLM call concerns => fewer failure
    coupling.
    """
    sys_prompt = (
        "You scan the latest message exchange in a homeowner-care app and "
        "extract any dated events worth adding to the home's calendar. "
        "Be conservative: only extract entries with a clear date or "
        "recurring pattern, not vague mentions.\n\n"
        "Kinds:\n"
        " - past: completed work or observed events (\"I replaced the "
        "filter today\")\n"
        " - future: stated intentions (\"planning to repaint the deck in "
        "May\")\n"
        " - recurring: routine patterns (\"I always mow on Saturdays\")\n"
        " - observation: noticed issues (\"there's a crack in the wall\")\n\n"
        "For dates: use ISO YYYY-MM-DD. If the owner says \"today\" use "
        f"{datetime.now().date().isoformat()}. \"Tomorrow\" = "
        f"{(datetime.now().date() + timedelta(days=1)).isoformat()}. "
        "\"This weekend\" = the upcoming Saturday. \"Next month\" = first "
        "of next month. If no date is implied at all, set occurred_at to "
        "null.\n\n"
        "If nothing in this exchange warrants a calendar entry, return "
        "an empty array. Empty is the most common case — don't reach for "
        "entries that aren't there.\n\n"
        "LATEST EXCHANGE:\n"
        f"OWNER: {user_message}\n"
        f"CAPTAIN: {assistant_message}"
    )

    try:
        client = OpenAI()
        resp = client.chat.completions.create(
            model=CALENDAR_MODEL,
            messages=[{"role": "system", "content": sys_prompt}],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "calendar_updates",
                    "schema": CALENDAR_SCHEMA,
                    "strict": True,
                },
            },
        )
        updates = json.loads(resp.choices[0].message.content)
    except Exception as e:  # noqa: BLE001
        print(f"[calendar] extraction failed: {e}")
        return {"new_calendar_entries": []}

    new_entries = updates.get("new_calendar_entries") or []
    for c in new_entries:
        store.add_calendar_entry(
            home_id, c["text"], c.get("occurred_at"),
            kind=c["kind"], source="chat",
        )
    if new_entries:
        print(f"[calendar] added {len(new_entries)} entries from chat")
    return updates


def update_memory_from_exchange(
    home_id: int, user_message: str, assistant_message: str,
    image_paths: list[Path] | None = None,
) -> None:
    """Background entrypoint: rewrite markdown profiles AND extract any
    calendar entries from this exchange. The photos (if any) are passed to
    the profile rewriter so it can extract visible-only facts (a dog's
    breed, an appliance brand, a plant species). Failures in either don't
    affect the foreground response."""
    try:
        profiles.update_profiles_from_exchange(
            user_message, assistant_message, image_paths=image_paths,
        )
    except Exception as e:  # noqa: BLE001
        print(f"[memory] profile rewrite failed: {e}")
    try:
        extract_calendar_updates(home_id, user_message, assistant_message)
    except Exception as e:  # noqa: BLE001
        print(f"[memory] calendar extraction failed: {e}")
    # Profiles or calendar may have changed — drop the radar cache so the
    # next /radar call regenerates against the fresh context. Cheap to
    # invalidate; the next foreground load will absorb a 2-5s LLM call.
    try:
        radar.invalidate_cache()
    except Exception as e:  # noqa: BLE001
        print(f"[memory] radar cache invalidation failed: {e}")


# ---------- fixture ----------

def fixture_chat_response(user_message: str) -> str:
    """Canned response for dev / iOS UI work when CAPTAIN_DEV_FIXTURE=1."""
    return (
        "(dev fixture) I heard: " + (user_message[:120] or "(empty)")
        + ". In real mode I'd respond using everything I know about your home."
    )
