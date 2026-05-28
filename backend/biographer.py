"""
Biographer surfaces (PRD §6.7 "the home's biography").

Captain's calendar is meant to be felt presence, not a passive log. This
module returns a single short prose line for the home screen on the days
when something in the home's past lines up with today — "On this day last
year, you noticed the lilacs were about to bloom." The PRD calls this
out as one of the highest-emotional-register moments in the app.

How it works:
  - Scan calendar entries with a concrete `occurred_at` date.
  - Find ones whose month/day matches today (or yesterday/tomorrow — a
    3-day window so a single missed day doesn't dead-air a real
    anniversary) AND that are at least ~330 days in the past.
  - Pick the most evocative (longest text wins as a v1 heuristic — fuller
    entries tend to carry more story).
  - Ask the LLM for ONE short biographer line tied to it.

Returns None when nothing fits — a brand-new home has no anniversaries,
and silence is correct in that case. The iOS surface renders nothing
when the response is null.

Cached for 24 hours per home; invalidate via /biographer?refresh=1 if
needed (dev convenience).
"""

from __future__ import annotations

import json
import os
import time
from datetime import date, datetime, timezone
from pathlib import Path

from . import llm, store

CACHE_DIR = Path(__file__).parent / "cache"
CACHE_FILE = CACHE_DIR / "biographer.json"
CACHE_TTL_SECONDS = 24 * 60 * 60

BIOGRAPHER_MODEL = os.getenv("CAPTAIN_BIOGRAPHER_MODEL", "gpt-5.4-nano")

# How wide a window around today counts as "this day" — covers a day
# missed entirely (e.g. user opens app every other day).
ANNIVERSARY_WINDOW_DAYS = 3
# Minimum age in days before an entry counts as an "anniversary" — keeps
# recent items from showing up as their own anniversaries.
MIN_AGE_DAYS = 330


def _parse_date(s: str | None) -> date | None:
    if not s:
        return None
    # Accept YYYY-MM-DD or full ISO datetime.
    try:
        return date.fromisoformat(s[:10])
    except ValueError:
        return None


def _candidate_entry(
    calendar: list[dict], today: date,
) -> dict | None:
    """Pick the most evocative calendar entry whose month/day is within
    the anniversary window around today and which is old enough to count
    as a real anniversary. Returns None when nothing fits."""
    best: dict | None = None
    best_len = -1
    for entry in calendar:
        d = _parse_date(entry.get("occurred_at"))
        if d is None:
            continue
        age = (today - d).days
        if age < MIN_AGE_DAYS:
            continue
        # Within +/- N days of today's month/day in any prior year.
        # Compare by projecting the entry's month/day into the current
        # year and taking the absolute day distance.
        try:
            projected = date(today.year, d.month, d.day)
        except ValueError:
            # Feb 29 in a non-leap year, etc. Skip.
            continue
        if abs((projected - today).days) > ANNIVERSARY_WINDOW_DAYS:
            continue
        text_len = len(entry.get("text") or "")
        if text_len > best_len:
            best_len = text_len
            best = entry
    return best


def _read_cache() -> dict | None:
    if not CACHE_FILE.exists():
        return None
    try:
        cached = json.loads(CACHE_FILE.read_text())
        if time.time() - cached.get("generated_at", 0) < CACHE_TTL_SECONDS:
            return cached
    except Exception:  # noqa: BLE001
        return None
    return None


def _write_cache(payload: dict) -> None:
    CACHE_DIR.mkdir(exist_ok=True)
    CACHE_FILE.write_text(json.dumps(payload))


def invalidate_cache() -> None:
    """Force the next /biographer call to regenerate. Used after big
    calendar changes (a manual entry, a deletion that removed the
    current anniversary)."""
    try:
        CACHE_FILE.unlink()
    except FileNotFoundError:
        pass


def get_recall(
    home_id: int, *, now: datetime | None = None, refresh: bool = False,
) -> dict | None:
    """Return a short recall line for the home screen, or None when
    there's nothing biographically interesting today.

    Shape: {"text": "On this day last year, …", "occurred_at": "...",
            "entry_text": "..."}
    """
    if not refresh:
        cached = _read_cache()
        if cached is not None:
            return cached.get("recall")

    if now is None:
        now = datetime.now(timezone.utc).astimezone()
    today = now.date()

    calendar = store.get_calendar(home_id, limit=500)
    entry = _candidate_entry(calendar, today)
    if entry is None:
        _write_cache({"generated_at": time.time(), "recall": None})
        return None

    occurred = _parse_date(entry.get("occurred_at"))
    years_ago = max(1, today.year - occurred.year) if occurred else 1
    when_phrase = "last year" if years_ago == 1 else f"{years_ago} years ago"

    sys_prompt = (
        "You are Captain — the quiet biographer of a homeowner's home. "
        "Today is " + today.isoformat() + ". On this day "
        f"{when_phrase}, the home's calendar carries this entry:\n\n"
        f"  \"{entry.get('text', '')}\"\n"
        f"  (kind: {entry.get('kind', '?')}, "
        f"date: {entry.get('occurred_at', '?')})\n\n"
        "Write ONE short biographer line (under 16 words) that the "
        "homeowner will see on their home screen — a quiet 'on this "
        "day' recall. Plain prose, no preamble, no quoting the entry "
        "verbatim. Avoid 'I remember' (Captain doesn't dramatize). "
        "Just observe. Example shape: 'A year ago today you noticed "
        "the lilacs were about to bloom.' or 'Last spring around now, "
        "the front-bed mulching went down.' "
        "Return JSON: {\"text\": \"<line>\"}."
    )

    try:
        resp = llm.chat_completion(
            model=BIOGRAPHER_MODEL,
            messages=[{"role": "system", "content": sys_prompt}],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "biographer_recall",
                    "schema": {
                        "type": "object",
                        "properties": {"text": {"type": "string"}},
                        "required": ["text"],
                        "additionalProperties": False,
                    },
                    "strict": True,
                },
            },
        )
        text = (json.loads(resp.text or "{}").get("text") or "").strip()
    except Exception as e:  # noqa: BLE001
        print(f"[biographer] generation failed: {e}")
        text = ""

    if not text:
        _write_cache({"generated_at": time.time(), "recall": None})
        return None

    recall = {
        "text": text,
        "occurred_at": entry.get("occurred_at"),
        "entry_text": entry.get("text"),
    }
    _write_cache({"generated_at": time.time(), "recall": recall})
    return recall
