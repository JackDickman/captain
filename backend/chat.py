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

Real-time web search (the `web_search` tool):
  You have access to a live web search tool. Use it when, and only when, the user's question genuinely requires current or local information that you can't be confident of from training alone — current contractor reviews or recommendations in their specific area, recent regulatory or rebate changes, current local conditions where the weather context above isn't enough, or anything where "right now" matters.
  Do NOT search for general home-care advice that doesn't depend on current info (how to caulk a tub, what mulch type to use, when to prune a hydrangea, what a P-trap is). Do NOT search for things you already know from the profiles. Prefer one concise, specific query (include city/state when local results matter) over multiple speculative ones.
  When results are weak or empty, just say so plainly and answer with what you do know — never pretend to have found something useful.

Product recommendations (the `find_products` tool):
  When the conversation surfaces a concrete product the user might want to order — restocking an HVAC filter, buying a specific paint or stain, picking up a tool for a job, finding a pet-safe lawn product — use the `find_products` tool to pull live Amazon picks the user can tap straight through to.
  The pattern is offered, never pushed: "Want me to pull up a few options?" — matching how you'd offer to find a contractor. Only call the tool after the user signals shopping intent, or after you've offered and they've said yes. Don't tool-call on the first turn of a topic just because a product is mentioned in passing.
  `num_options=1` when you have a single specific recommendation in mind (you'll embed the link inline in your prose with a markdown link). `num_options=2` or `3` when you're offering a small set to compare (cards render below your text — keep your text short and conversational; don't enumerate the picks in prose).
  Re-recommend brands the user has used before when the profile tells you what they bought — this is one of the best moments to call the tool ("same Honeywell pack you bought last fall").
  NEVER mention price in your prose. The user sees the price when they tap through. Captain stays calm and out of the cost conversation (PRD §5).
  When the tool returns empty / unhelpful, say so plainly and suggest a brand the user could look up themselves — don't fabricate links.

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


# ---------- Web search tool ----------

# OpenAI tool definition for the `web_search` function. Captain's chat model
# is given access to this and decides on its own when calling it would help.
# Description carries the calibration ("use for current/local info you can't
# be confident of from training; skip for general advice"); the underlying
# implementation hits Firecrawl.
WEB_SEARCH_TOOL = {
    "type": "function",
    "function": {
        "name": "web_search",
        "description": (
            "Search the live web for current information. USE THIS when "
            "the user's question requires information you can't be "
            "confident of from training alone: current product prices "
            "or specs, current contractor availability or reviews in a "
            "specific area, recent regulatory or rebate changes, recent "
            "news, current weather/pollen/seasonality where the existing "
            "weather context isn't enough, or anything else where 'live "
            "right now' matters. DO NOT use for general home-care advice "
            "that doesn't depend on current info (how to caulk a tub, "
            "what mulch to use, when to prune a hydrangea) or for facts "
            "already covered in the home/owner profile. Prefer one "
            "concise, specific query over multiple speculative ones."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": (
                        "Concise, specific search query. Include the "
                        "city/state when local results matter."
                    ),
                },
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    },
}

# OpenAI tool definition for the `find_products` function. The model
# invokes this when the conversation surfaces a product the user might
# want to buy. Returns 1 or 2-3 picks — the model picks the count based
# on whether it's a single recommendation (mention inline) or a small
# comparison (renders as cards in iOS).
FIND_PRODUCTS_TOOL = {
    "type": "function",
    "function": {
        "name": "find_products",
        "description": (
            "Find specific products to recommend to the homeowner. USE "
            "THIS when the conversation surfaces a concrete product need "
            "the user might want to order — an HVAC filter to reorder, a "
            "specific paint or stain to buy, a tool for a job, a pet-safe "
            "lawn product, etc. Especially good for restocking something "
            "they've used before (their profile may name the brand). DO "
            "NOT use for service or contractor recommendations (use "
            "web_search for those), and DO NOT use for general advice "
            "where no purchase is implied. ALWAYS frame Captain's pitch "
            "as 'want me to pull up a few options?' — offered, never "
            "pushed. `num_options=1` means you'll mention one specific "
            "pick inline as a markdown link in your prose; "
            "`num_options=2` or `3` means a small set of options will "
            "render as compact cards below your text — keep your text "
            "short and conversational in that case."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": (
                        "Concrete product search query. Be specific — "
                        "include the brand, size, type, MERV rating, "
                        "color, etc. that the conversation suggests."
                    ),
                },
                "num_options": {
                    "type": "integer",
                    "description": (
                        "1 if you're recommending one specific pick "
                        "(you'll embed the link inline in prose). "
                        "2 or 3 if you're offering options to compare "
                        "(cards will render below your text)."
                    ),
                    "minimum": 1,
                    "maximum": 3,
                },
                "reason_hint": {
                    "type": "string",
                    "description": (
                        "One short sentence (under 12 words) you'd "
                        "show to the user about why this category fits. "
                        "Shown on the cards. Skip when num_options=1."
                    ),
                },
            },
            "required": ["query", "num_options"],
            "additionalProperties": False,
        },
    },
}

# Hard cap on tool-call rounds per chat turn so a confused model can't
# rack up cost by re-searching repeatedly. After this many rounds the
# tools are no longer offered and the model must answer with what it has.
MAX_TOOL_ROUNDS = 2


def _do_web_search(query: str) -> str:
    """Run a Firecrawl search and condense the results into something the
    LLM can consume as a tool result.

    Returns a string that's always non-empty so the model has something
    to ground on. On any error or zero-result outcome, returns a brief
    note explaining the situation — the model is prompted to handle that
    gracefully (answer from what it knows, acknowledge the gap)."""
    api_key = os.getenv("FIRECRAWL_API_KEY")
    if not api_key:
        return (
            "Web search is unavailable right now (no API key configured). "
            "Answer from what you already know and note that you couldn't "
            "look it up."
        )

    try:
        # Imported lazily to avoid the top-level dependency on the
        # repo-root first_session module from chat.py.
        from first_session import firecrawl_search
        results = firecrawl_search(api_key, query)
    except Exception as e:  # noqa: BLE001
        print(f"[web_search] firecrawl error: {e}")
        return (
            f"Web search failed: {type(e).__name__}. Answer from what "
            "you already know and note that you couldn't look it up."
        )

    if not results:
        return (
            "Web search returned no results for that query. Answer from "
            "what you already know and note that you couldn't find live "
            "information."
        )

    # Condense top results — title, URL, and a short content excerpt.
    # The model gets enough to ground a real answer without bloating
    # context with full scraped pages.
    blocks: list[str] = []
    for i, r in enumerate(results[:3], start=1):
        title = r.get("title") or "(untitled)"
        url = (
            r.get("url")
            or (r.get("metadata") or {}).get("sourceURL")
            or ""
        )
        content = (
            r.get("markdown")
            or r.get("description")
            or r.get("snippet")
            or ""
        )
        # Trim each result so the combined block stays well under the
        # model's effective tool-result budget.
        excerpt = content[:1500].strip()
        blocks.append(f"[{i}] {title}\n{url}\n{excerpt}")
    return "\n\n---\n\n".join(blocks)


def _affiliate_url(url: str) -> str:
    """Wrap an Amazon product URL with our affiliate tag (when set).

    Idempotent: if the URL already carries a `tag=` param we leave it
    alone. If `CAPTAIN_AMAZON_TAG` isn't configured, the URL is returned
    unchanged — the link still works, just without earning revenue. Lets
    the feature run end-to-end in dev without an affiliate account."""
    tag = os.getenv("CAPTAIN_AMAZON_TAG")
    if not tag:
        return url
    if "amazon." not in url:
        return url
    if "tag=" in url:
        return url
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}tag={tag}"


def _find_products(query: str, num_options: int) -> tuple[str, list[dict]]:
    """Run an Amazon-scoped product search via Firecrawl, normalize the
    results into structured product picks, and return (text_for_model,
    structured_picks).

    `text_for_model` is what gets fed back to the LLM as the tool
    result — concise, just enough for the model to embed a link in
    prose (num_options=1) or write a short intro (num_options>=2).

    `structured_picks` is the list iOS will render as compact product
    cards. Empty when num_options==1 (the model handles that case
    inline) OR when the search yielded nothing.
    """
    api_key = os.getenv("FIRECRAWL_API_KEY")
    if not api_key:
        return (
            "Product search is unavailable right now (no API key). "
            "Suggest a brand the user could look up themselves and "
            "acknowledge you couldn't pull links.",
            [],
        )

    try:
        from first_session import firecrawl_search
        # site:amazon.com keeps results constrained to product pages we
        # can affiliate-tag. Firecrawl's search supports the operator.
        results = firecrawl_search(api_key, f"site:amazon.com {query}")
    except Exception as e:  # noqa: BLE001
        print(f"[find_products] firecrawl error: {e}")
        return (
            f"Product search failed: {type(e).__name__}. Suggest a "
            "brand the user could look up themselves and acknowledge "
            "you couldn't pull links.",
            [],
        )

    # Filter to actual Amazon product URLs only (Firecrawl can return
    # category / search pages too; we want individual products so a tap
    # lands on something orderable).
    amazon_products: list[dict] = []
    for r in results:
        url = (
            r.get("url")
            or (r.get("metadata") or {}).get("sourceURL")
            or ""
        )
        if "amazon." not in url:
            continue
        if "/dp/" not in url and "/gp/product/" not in url:
            # Search-result or category pages; skip — not orderable.
            continue
        amazon_products.append({
            "title": (r.get("title") or "").strip(),
            "url": _affiliate_url(url),
            "description": (
                r.get("description") or r.get("snippet") or ""
            )[:200].strip(),
        })
        if len(amazon_products) >= max(num_options, 3):
            break

    if not amazon_products:
        return (
            "No clean Amazon product results were returned. Suggest a "
            "brand or category the user could look up themselves and "
            "acknowledge you couldn't pull links.",
            [],
        )

    picks = amazon_products[:num_options]

    # Compose the model-facing text. For num_options==1 we want the
    # model to weave the link inline, so we give it title + URL plainly.
    # For >=2 we tell the model not to enumerate in prose (cards do
    # that) and just write a short conversational intro.
    if num_options == 1:
        p = picks[0]
        text_for_model = (
            f"One product to recommend (embed as a markdown link in "
            f"your prose):\n\n"
            f"Title: {p['title']}\n"
            f"URL: {p['url']}\n"
            f"Blurb: {p['description']}"
        )
        # num_options==1 → no structured cards (model does it inline).
        return text_for_model, []

    bullet_lines = []
    for i, p in enumerate(picks, start=1):
        bullet_lines.append(
            f"  {i}. {p['title']} — {p['description']}"
        )
    text_for_model = (
        "Product options to compare. DO NOT list them in your prose — "
        "the cards render automatically below your response. Just "
        "write a short conversational intro (e.g. 'A few worth "
        "comparing — the first matches your existing setup, the "
        "second's a tier up') and let the cards do the work.\n\n"
        + "\n".join(bullet_lines)
    )

    # Structured picks for iOS to render as cards. Each pick gets a
    # `retailer` field so we can extend to multi-retailer later without
    # iOS schema churn.
    structured = [
        {
            "title": p["title"],
            "retailer": "Amazon",
            "url": p["url"],
            "blurb": p["description"],
        }
        for p in picks
    ]
    return text_for_model, structured


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
    on_stage: callable | None = None,
) -> dict:
    """Foreground: call LLM with full context + web-search tool, persist
    messages, return a structured result.

    `on_stage(stage, **kwargs)` is invoked when the chat phase changes
    so the iOS loading bubble can show what Captain is doing right now:
      - on_stage("thinking")                       — model is responding
      - on_stage("searching", query="...")         — tool call in flight
      - on_stage("writing")                        — model is composing
                                                     final answer after a
                                                     tool result came back

    Returns: {"text": str, "searches": [str]}
      `searches` is the list of search queries the model issued during
      this turn (in order). iOS uses this to badge the assistant bubble
      with a "🌐 searched the web for X" footer.
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
    searches: list[str] = []
    product_picks: list[dict] = []
    assistant_text = ""

    # Tool-calling loop: keep calling the model until it stops invoking
    # tools, or until we hit the round cap. After the cap the tools are
    # removed from the request so the model has to commit to a final
    # answer with whatever it has.
    if on_stage:
        on_stage("thinking")

    for round_idx in range(MAX_TOOL_ROUNDS + 1):
        tools = (
            [WEB_SEARCH_TOOL, FIND_PRODUCTS_TOOL]
            if round_idx < MAX_TOOL_ROUNDS else None
        )
        resp = client.chat.completions.create(
            model=CHAT_MODEL,
            messages=messages,
            tools=tools,
            temperature=0.7,
        )
        choice = resp.choices[0].message
        tool_calls = getattr(choice, "tool_calls", None) or []

        if not tool_calls:
            assistant_text = choice.content or ""
            break

        # Persist the assistant turn that holds the tool call(s). The
        # OpenAI API requires the function-call message in history
        # before the matching tool-result messages.
        messages.append({
            "role": "assistant",
            "content": choice.content or "",
            "tool_calls": [
                {
                    "id": tc.id,
                    "type": "function",
                    "function": {
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    },
                }
                for tc in tool_calls
            ],
        })

        # Execute every tool call the model made this round. Unknown
        # names get a polite stub so the loop can recover.
        for tc in tool_calls:
            try:
                args = json.loads(tc.function.arguments or "{}")
            except json.JSONDecodeError:
                args = {}

            if tc.function.name == "web_search":
                query = (args.get("query") or "").strip()
                if not query:
                    tool_result = "No query was provided."
                else:
                    searches.append(query)
                    if on_stage:
                        on_stage("searching", query=query)
                    print(f"[chat] web_search: {query!r}")
                    tool_result = _do_web_search(query)

            elif tc.function.name == "find_products":
                query = (args.get("query") or "").strip()
                num_options = args.get("num_options") or 2
                num_options = max(1, min(3, int(num_options)))
                if not query:
                    tool_result = "No query was provided."
                else:
                    if on_stage:
                        # Same "searching" stage label — from the user's
                        # POV this is identical to a web search in
                        # progress, just scoped to products.
                        on_stage("searching", query=query)
                    print(
                        f"[chat] find_products: {query!r} "
                        f"(n={num_options})"
                    )
                    tool_result, picks = _find_products(query, num_options)
                    # Picks are accumulated across all tool calls this
                    # turn — if the model decides on a comparison later,
                    # those cards land on the assistant message too.
                    product_picks.extend(picks)
            else:
                tool_result = (
                    f"Unknown tool '{tc.function.name}'. Answer without it."
                )

            messages.append({
                "role": "tool",
                "tool_call_id": tc.id,
                "content": tool_result,
            })

        if on_stage:
            on_stage("writing")
        # Loop back — model now sees the tool result and either issues
        # another tool call or produces the final answer.

    # Persist user + assistant messages. The intermediate tool turns are
    # NOT persisted to chat history (that's an internal LLM mechanism
    # the user doesn't need to see scroll-back through). Product picks
    # are attached to the assistant message so cards re-render on
    # reload, not just immediately after the send.
    store.add_message(conv_id, "user", user_message, image_urls=image_urls)
    store.add_message(
        conv_id, "assistant", assistant_text,
        product_picks=product_picks if product_picks else None,
    )

    return {
        "text": assistant_text,
        "searches": searches,
        "product_picks": product_picks,
    }


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
