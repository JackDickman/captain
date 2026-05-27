"""
Radar — what's on the owner's plate right now.

Two streams blended into one response:
  1. Future + recurring calendar items pulled fresh from the DB (these
     have explicit dates and were captured through chat).
  2. LLM-generated suggestions based on the full context — home profile,
     owner profile, calendar past+future, weather, current date. These
     proactively surface things to consider in the next ~30 days.

Suggestions are cached to disk for 2 hours so multiple home-view loads
in a single session don't repeatedly burn API spend. Calendar items are
never cached (always fresh from the DB).
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

from openai import OpenAI

from . import profiles, store
from .weather import get_forecast_summary

CACHE_DIR = Path(__file__).parent / "cache"
CACHE_FILE = CACHE_DIR / "radar.json"
CACHE_TTL_SECONDS = 2 * 60 * 60  # 2 hours

# Radar suggestions are inferential but not deeply reasoned — mini works.
RADAR_MODEL = os.getenv("CAPTAIN_RADAR_MODEL", "gpt-5.4-mini")

# Hardcoded fallback location for weather when home has no lat/lng yet
# (matches the defaults in chat.py).
DEFAULT_LAT = 41.500
DEFAULT_LNG = -81.555

SUGGESTIONS_SCHEMA = {
    "type": "object",
    "properties": {
        "suggestions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "title": {
                        "type": "string",
                        "description": (
                            "Concise imperative or noun phrase, like 'Prune "
                            "the panicle hydrangeas' or 'Check the gutters'."
                        ),
                    },
                    "reason": {
                        "type": "string",
                        "description": (
                            "1-2 sentences explaining WHY now, tied to "
                            "context (season, weather, owner profile, home "
                            "specifics). Reference things from the profiles "
                            "when relevant — 'Since Jackie sniffs the lawn…'."
                        ),
                    },
                    "timeframe": {
                        "type": "string",
                        "description": (
                            "When to do it: 'this weekend', 'next 2 weeks', "
                            "'before fall', 'late May', etc."
                        ),
                    },
                    "category": {
                        "type": "string",
                        "description": (
                            "One of: exterior, interior, landscaping, "
                            "systems, seasonal, followup"
                        ),
                    },
                },
                "required": ["title", "reason", "timeframe", "category"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["suggestions"],
    "additionalProperties": False,
}


def _read_cache() -> list[dict] | None:
    if not CACHE_FILE.exists():
        return None
    try:
        cached = json.loads(CACHE_FILE.read_text())
        if time.time() - cached.get("generated_at", 0) < CACHE_TTL_SECONDS:
            return cached.get("suggestions") or []
    except Exception:  # noqa: BLE001
        return None
    return None


def _write_cache(suggestions: list[dict]) -> None:
    CACHE_DIR.mkdir(exist_ok=True)
    CACHE_FILE.write_text(json.dumps({
        "generated_at": time.time(),
        "suggestions": suggestions,
    }))


def invalidate_cache() -> None:
    """Force the next /radar call to regenerate suggestions. Call this
    whenever the profile or calendar changes meaningfully."""
    try:
        CACHE_FILE.unlink()
    except FileNotFoundError:
        pass


def generate_suggestions(home_id: int,
                         *, now: datetime | None = None) -> list[dict]:
    """LLM-generated radar suggestions. Cached for CACHE_TTL_SECONDS.

    `now` is the user's current local datetime — used in the prompt's
    "Today is …" line so seasonal/timely suggestions track the user's
    clock. Falls back to server local time when not provided."""
    cached = _read_cache()
    if cached is not None:
        return cached

    home = store.get_home() or {}
    home_md = profiles.read_home_md()
    user_md = profiles.read_user_md()
    calendar = store.get_calendar(home_id)

    lat = home.get("lat") or DEFAULT_LAT
    lng = home.get("lng") or DEFAULT_LNG
    weather = get_forecast_summary(lat, lng)

    if now is None:
        now = datetime.now(timezone.utc).astimezone()
    today = now.strftime("%A, %B %-d, %Y")

    calendar_block = (
        "\n".join(
            f"- [{c['kind']}] {c['text']}"
            + (f" ({c['occurred_at']})" if c.get("occurred_at") else "")
            for c in calendar[:25]
        )
        if calendar else "(empty)"
    )

    sys_prompt = f"""You are Captain — the quiet, observant AI helper dedicated to a specific home and its owner.

Today is {today}. Weather forecast for this location:
{weather or "(unavailable)"}

THIS HOME (markdown profile):
```markdown
{home_md}
```

THIS OWNER (markdown profile):
```markdown
{user_md}
```

CALENDAR (past + upcoming events Captain has gathered):
{calendar_block}

Your job: generate 2-4 short, useful things for the owner to consider doing in the next 30 days.

Hard rules:
 - Be SPECIFIC to THIS home and THIS owner. Reference things from the profiles when it sharpens the suggestion ("Since Jackie sniffs the lawn, choose a pet-safe…"). No generic homeowner advice.
 - Mix short-term (this weekend) and medium-term (next 2-4 weeks).
 - DO NOT duplicate items already on the calendar — those are shown separately in the radar. Add things that aren't already tracked.
 - NEVER mention sale prices, market values, tax assessments, or any other financial valuation. This app deliberately avoids financial surfaces.
 - Skip "monitor for issues" filler. Every suggestion must be a concrete action.
 - Calibrate tone to the owner's DIY comfort level (if shown in the profile). Skip basic instructions for handy owners; orient briefly for new ones.
 - If the profiles are mostly empty (early in the owner's journey), lean on season + weather + climate context — pruning windows for hardiness zone, weather-driven tasks, etc. — rather than fabricating profile details.
 - Categories are: exterior, interior, landscaping, systems, seasonal, followup.
 - If there's genuinely nothing worth suggesting right now, return an empty array. Better empty than padded.
"""

    client = OpenAI()
    try:
        resp = client.chat.completions.create(
            model=RADAR_MODEL,
            messages=[{"role": "system", "content": sys_prompt}],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "radar_suggestions",
                    "schema": SUGGESTIONS_SCHEMA,
                    "strict": True,
                },
            },
        )
    except Exception as e:  # noqa: BLE001
        print(f"[radar] LLM call failed: {e}")
        return []

    try:
        payload = json.loads(resp.choices[0].message.content)
        suggestions = payload.get("suggestions") or []
    except Exception as e:  # noqa: BLE001
        print(f"[radar] response parse failed: {e}")
        suggestions = []

    print(f"[radar] generated {len(suggestions)} suggestion(s)")
    _write_cache(suggestions)
    return suggestions


def build_radar_response(home_id: int,
                         *, now: datetime | None = None) -> dict:
    """Combine upcoming calendar entries + LLM suggestions for the iOS app.

    Calendar items: future (sorted soonest-first) followed by recurring.
    Past + observation entries are NOT included — they live in the
    profile drawer's calendar tab instead.

    `now` is forwarded to suggestion generation so the LLM prompt's
    "today" anchor tracks the user's clock.
    """
    cal = store.get_calendar(home_id)
    future = sorted(
        [c for c in cal if c["kind"] == "future"],
        key=lambda c: c.get("occurred_at") or "9999",
    )
    recurring = [c for c in cal if c["kind"] == "recurring"]

    suggestions: list[dict] = []
    try:
        suggestions = generate_suggestions(home_id, now=now)
    except Exception as e:  # noqa: BLE001
        print(f"[radar] suggestion generation failed: {e}")

    return {
        "calendar_items": future + recurring,
        "suggestions": suggestions,
        "generated_at": time.time(),
    }


# ---------- fixture ----------

def fixture_radar_response() -> dict:
    """Canned response for CAPTAIN_DEV_FIXTURE=1. Lets iOS exercise the
    radar UI without burning LLM spend."""
    return {
        "calendar_items": [
            {
                "id": 1,
                "text": "Planning to repaint the back deck",
                "occurred_at": "2026-06-15",
                "kind": "future",
                "source": "chat",
                "created_at": time.time(),
            },
            {
                "id": 2,
                "text": "Gutter clean before fall",
                "occurred_at": "2026-09-15",
                "kind": "future",
                "source": "chat",
                "created_at": time.time(),
            },
            {
                "id": 3,
                "text": "Mow the lawn",
                "occurred_at": None,
                "kind": "recurring",
                "source": "chat",
                "created_at": time.time(),
            },
        ],
        "suggestions": [
            {
                "title": "Prune the panicle hydrangeas",
                "reason": (
                    "Panicle hydrangeas bloom on new wood — your zone 6a "
                    "spring window for a hard prune is closing. Cutting "
                    "back ~1/3 now sets up vigorous summer blooms."
                ),
                "timeframe": "this weekend",
                "category": "landscaping",
            },
            {
                "title": "Pet-safe lawn treatment plan",
                "reason": (
                    "Since Jackie sniffs the grass constantly, switch to "
                    "an organic dandelion approach — vinegar-based spray "
                    "or hand-pulling — before the next mow."
                ),
                "timeframe": "next 2 weeks",
                "category": "landscaping",
            },
            {
                "title": "HVAC condenser check-up",
                "reason": (
                    "Cleveland summers ramp fast and your 1942 system is "
                    "likely the original era — clear debris around the "
                    "outdoor unit and check the contactor before the first "
                    "hot week."
                ),
                "timeframe": "late May",
                "category": "systems",
            },
        ],
        "generated_at": time.time(),
    }
