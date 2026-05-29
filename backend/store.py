"""
SQLite persistence for Captain.

V1 simplifications (revisit when we add auth + multi-tenancy):
  - Exactly one `home` row per backend instance.
  - Exactly one `conversation` per home.

The store is intentionally thin: small helpers around sqlite3, no ORM, no
async (sqlite3 calls are sub-millisecond on local disk). Callers do their
own JSON-encoding for blob fields where noted.
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

DB_PATH = Path(__file__).parent / "captain.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    -- v1: a single default row (id=1). Real auth + per-device tokens
    -- arrive with the multi-tenancy migration (PRD §11.10). The column
    -- set is intentionally tiny so the rest of the schema can carry a
    -- user_id FK today without committing to an auth shape.
    display_name TEXT,
    created_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS home (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL DEFAULT 1,
    address TEXT NOT NULL,
    palette_json TEXT,            -- JSON array of hex strings
    current_rendering_url TEXT,
    renderings_json TEXT,         -- JSON dict season -> url
    current_season TEXT,
    job_id TEXT,
    lat REAL,
    lng REAL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS features (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    home_id INTEGER NOT NULL,
    text TEXT NOT NULL,
    source TEXT NOT NULL,         -- image | web | chat | manual | both
    category TEXT,
    created_at REAL NOT NULL,
    FOREIGN KEY (home_id) REFERENCES home(id)
);
CREATE INDEX IF NOT EXISTS idx_features_home ON features(home_id);

CREATE TABLE IF NOT EXISTS user_profile (
    home_id INTEGER PRIMARY KEY,
    data_json TEXT NOT NULL,      -- free-form JSON blob (tone, household, etc.)
    updated_at REAL NOT NULL,
    FOREIGN KEY (home_id) REFERENCES home(id)
);

CREATE TABLE IF NOT EXISTS calendar_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    home_id INTEGER NOT NULL,
    text TEXT NOT NULL,
    occurred_at TEXT,             -- ISO date/datetime, null for undated intents
    kind TEXT NOT NULL,           -- past | future | recurring | observation
    source TEXT NOT NULL,         -- first-session | chat | manual
    created_at REAL NOT NULL,
    FOREIGN KEY (home_id) REFERENCES home(id)
);
CREATE INDEX IF NOT EXISTS idx_calendar_home ON calendar_entries(home_id);

CREATE TABLE IF NOT EXISTS conversations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    home_id INTEGER NOT NULL,
    -- Short LLM-generated label ("replacing the wax ring", "spring
    -- mulching plan"). NULL until the first exchange runs the
    -- background titler. iOS falls back to a derived label.
    title TEXT,
    -- Denormalized timestamp of the most recent message so the
    -- "active conversation" lookup is a single indexed query and the
    -- history list can sort newest-first without joining messages.
    last_message_at REAL,
    created_at REAL NOT NULL,
    FOREIGN KEY (home_id) REFERENCES home(id)
);
-- idx_conversations_home is created in init_db AFTER the ALTER TABLE
-- migrations run, so existing pre-migration DBs get the column before
-- the index references it.

CREATE TABLE IF NOT EXISTS hunt_progress (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    home_id INTEGER NOT NULL,
    item_id TEXT NOT NULL,
    status TEXT NOT NULL,         -- pending | done | skipped | not_applicable
    notes TEXT,                   -- user's captured text answer (or pre-fill)
    notes_source TEXT,            -- NULL | "documents" | "profile" — where pre-fill came from
    photo_url TEXT,               -- relative URL of the captured photo
    completed_at REAL,            -- unix epoch when status became 'done'
    UNIQUE(home_id, item_id),
    FOREIGN KEY (home_id) REFERENCES home(id)
);
CREATE INDEX IF NOT EXISTS idx_hunt_home ON hunt_progress(home_id);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL,
    role TEXT NOT NULL,           -- user | assistant
    content TEXT NOT NULL,
    image_url TEXT,               -- legacy single-photo field (kept for old rows)
    image_urls TEXT,              -- JSON array of relative URLs for attached photos
    product_picks TEXT,           -- JSON array of product cards (assistant-side only)
    searches TEXT,                -- JSON array of web-search queries this assistant turn ran
    created_at REAL NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id);

CREATE TABLE IF NOT EXISTS events (
    -- Lightweight usage telemetry. Used to measure PRD §13 success
    -- criteria (weekly opens, first-session-under-five-minutes, etc.)
    -- and to debug regressions. Payload is freeform JSON so iOS can
    -- attach context without schema churn.
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL DEFAULT 1,
    home_id INTEGER,
    event_type TEXT NOT NULL,
    payload_json TEXT,
    created_at REAL NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (home_id) REFERENCES home(id)
);
CREATE INDEX IF NOT EXISTS idx_events_user_type
    ON events(user_id, event_type, created_at);
"""

# v1: every row lives under this single user. When auth lands, this
# helper is the seam to replace — callers don't hardcode the id.
DEFAULT_USER_ID = 1


@contextmanager
def connect() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(DB_PATH, isolation_level=None, timeout=10.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    try:
        yield conn
    finally:
        conn.close()


def init_db() -> None:
    DB_PATH.parent.mkdir(exist_ok=True)
    with connect() as c:
        c.executescript(SCHEMA)
        # Idempotent migrations for columns added after v0.
        for ddl in [
            "ALTER TABLE messages ADD COLUMN image_url TEXT",
            "ALTER TABLE messages ADD COLUMN image_urls TEXT",
            "ALTER TABLE messages ADD COLUMN product_picks TEXT",
            "ALTER TABLE messages ADD COLUMN searches TEXT",
            "ALTER TABLE hunt_progress ADD COLUMN notes_source TEXT",
            # Multi-tenancy prep (PRD §11.10): existing pre-migration
            # home rows get DEFAULT 1 so they continue to belong to the
            # single v1 user.
            "ALTER TABLE home ADD COLUMN user_id INTEGER NOT NULL DEFAULT 1",
            # Conversation history v1: title + denormalized last-message
            # timestamp on every conversation row so the history list +
            # active-conversation lookup are cheap.
            "ALTER TABLE conversations ADD COLUMN title TEXT",
            "ALTER TABLE conversations ADD COLUMN last_message_at REAL",
        ]:
            try:
                c.execute(ddl)
            except sqlite3.OperationalError:
                pass  # column already exists
        # Indexes that reference migrated columns — created here so
        # they run after the ALTER TABLEs above add the column on
        # pre-migration DBs.
        c.execute(
            """CREATE INDEX IF NOT EXISTS idx_conversations_home
                 ON conversations(home_id, last_message_at)"""
        )
        # Seed the single v1 user if it doesn't exist yet. CONFLICT(id)
        # is a no-op on re-init.
        c.execute(
            """INSERT INTO users (id, display_name, created_at)
               VALUES (?, ?, ?)
               ON CONFLICT(id) DO NOTHING""",
            (DEFAULT_USER_ID, "Captain user", time.time()),
        )


# ---------- home ----------

def upsert_home(
    *,
    address: str,
    palette: list[str],
    current_rendering_url: str | None,
    renderings: dict[str, str],
    current_season: str,
    job_id: str,
    lat: float | None = None,
    lng: float | None = None,
    user_id: int = DEFAULT_USER_ID,
) -> int:
    """Replace the single home row. Returns its id."""
    now = time.time()
    with connect() as c:
        row = c.execute("SELECT id, created_at FROM home LIMIT 1").fetchone()
        if row is None:
            cur = c.execute(
                """INSERT INTO home (user_id, address, palette_json,
                                     current_rendering_url, renderings_json,
                                     current_season, job_id, lat, lng,
                                     created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (user_id, address, json.dumps(palette), current_rendering_url,
                 json.dumps(renderings), current_season, job_id, lat, lng,
                 now, now),
            )
            home_id = cur.lastrowid
        else:
            home_id = row["id"]
            c.execute(
                """UPDATE home
                   SET address = ?, palette_json = ?,
                       current_rendering_url = ?, renderings_json = ?,
                       current_season = ?, job_id = ?,
                       lat = COALESCE(?, lat), lng = COALESCE(?, lng),
                       updated_at = ?
                   WHERE id = ?""",
                (address, json.dumps(palette), current_rendering_url,
                 json.dumps(renderings), current_season, job_id,
                 lat, lng, now, home_id),
            )
    return home_id


def get_home() -> dict | None:
    with connect() as c:
        row = c.execute("SELECT * FROM home LIMIT 1").fetchone()
        if row is None:
            return None
        d = dict(row)
        d["palette"] = json.loads(d.pop("palette_json") or "[]")
        d["renderings"] = json.loads(d.pop("renderings_json") or "{}")
        return d


# ---------- features ----------

def replace_first_session_features(
    home_id: int, features: list[dict]
) -> None:
    """Used after first-session to wipe + re-seed image/web features.
    Chat-sourced features survive — only image/web/both get cleared.
    """
    now = time.time()
    with connect() as c:
        c.execute(
            """DELETE FROM features
               WHERE home_id = ? AND source IN ('image', 'web', 'both')""",
            (home_id,),
        )
        c.executemany(
            """INSERT INTO features (home_id, text, source, category, created_at)
               VALUES (?, ?, ?, ?, ?)""",
            [
                (home_id, f["text"], f["source"], f.get("category", ""), now)
                for f in features
            ],
        )


def add_feature(
    home_id: int, text: str, source: str = "chat", category: str = ""
) -> int:
    with connect() as c:
        cur = c.execute(
            """INSERT INTO features (home_id, text, source, category, created_at)
               VALUES (?, ?, ?, ?, ?)""",
            (home_id, text, source, category, time.time()),
        )
        return cur.lastrowid


def get_features(home_id: int) -> list[dict]:
    with connect() as c:
        rows = c.execute(
            """SELECT id, text, source, category, created_at
               FROM features WHERE home_id = ? ORDER BY id""",
            (home_id,),
        ).fetchall()
        return [dict(r) for r in rows]


# ---------- user profile ----------

def get_user_profile(home_id: int) -> dict:
    with connect() as c:
        row = c.execute(
            "SELECT data_json FROM user_profile WHERE home_id = ?", (home_id,)
        ).fetchone()
        if row is None:
            return {}
        return json.loads(row["data_json"])


def merge_user_profile(home_id: int, updates: dict[str, Any]) -> dict:
    """Shallow-merge `updates` into the existing profile and persist."""
    current = get_user_profile(home_id)
    current.update(updates)
    now = time.time()
    with connect() as c:
        c.execute(
            """INSERT INTO user_profile (home_id, data_json, updated_at)
               VALUES (?, ?, ?)
               ON CONFLICT(home_id) DO UPDATE SET
                   data_json = excluded.data_json,
                   updated_at = excluded.updated_at""",
            (home_id, json.dumps(current), now),
        )
    return current


# ---------- calendar ----------

def add_calendar_entry(
    home_id: int,
    text: str,
    occurred_at: str | None,
    kind: str,
    source: str,
) -> int:
    with connect() as c:
        cur = c.execute(
            """INSERT INTO calendar_entries
               (home_id, text, occurred_at, kind, source, created_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (home_id, text, occurred_at, kind, source, time.time()),
        )
        return cur.lastrowid


def get_calendar(home_id: int, limit: int = 50) -> list[dict]:
    with connect() as c:
        rows = c.execute(
            """SELECT id, text, occurred_at, kind, source, created_at
               FROM calendar_entries WHERE home_id = ?
               ORDER BY COALESCE(occurred_at, datetime(created_at, 'unixepoch')) DESC
               LIMIT ?""",
            (home_id, limit),
        ).fetchall()
        return [dict(r) for r in rows]


# ---------- conversation + messages ----------

# "Active" window: the most recent conversation is auto-resumed when its
# last message was within this many seconds. Twelve hours covers both
# the "still hammering on the same problem after a break" case and the
# "midnight cliff" case (a message at 11:55 PM and one at 12:30 AM stay
# together). Anything older than that on next send starts a fresh
# conversation. Twelve hours is a heuristic — tuneable by env var so we
# can adjust without a deploy if real usage suggests a different number.
ACTIVE_CONVERSATION_WINDOW_SECONDS = int(
    os.getenv("CAPTAIN_ACTIVE_CONVERSATION_WINDOW_SECONDS", "")
    or 12 * 60 * 60
)


def _most_recent_conversation(home_id: int) -> sqlite3.Row | None:
    """Most-recently-active conversation row for this home, by
    last_message_at (falling back to created_at for rows that have
    never received a message). None when the home has no conversations
    yet."""
    with connect() as c:
        return c.execute(
            """SELECT id, title, last_message_at, created_at
               FROM conversations WHERE home_id = ?
               ORDER BY COALESCE(last_message_at, created_at) DESC
               LIMIT 1""",
            (home_id,),
        ).fetchone()


def create_conversation(
    home_id: int, *, now: float | None = None, title: str | None = None,
) -> int:
    """Append a fresh conversation row for this home and return its id.
    `now` is unix epoch — pass the user's local-clock now() when you
    have it so the conversation's created_at matches when the user
    started talking, not when the worker thread ran the insert."""
    ts = now if now is not None else time.time()
    with connect() as c:
        cur = c.execute(
            """INSERT INTO conversations
                 (home_id, title, created_at, last_message_at)
               VALUES (?, ?, ?, NULL)""",
            (home_id, title, ts),
        )
        return cur.lastrowid


def get_or_create_active_conversation(
    home_id: int, *, now: float | None = None,
) -> int:
    """Return the id of the conversation the next user message should
    land in. Rule: pick the most recent conversation if its last
    message was within `ACTIVE_CONVERSATION_WINDOW_SECONDS`; otherwise
    create a fresh one. A brand-new home creates its first conversation
    here on the first chat turn."""
    ts = now if now is not None else time.time()
    row = _most_recent_conversation(home_id)
    if row is not None:
        anchor = row["last_message_at"] or row["created_at"]
        if ts - anchor <= ACTIVE_CONVERSATION_WINDOW_SECONDS:
            return row["id"]
    return create_conversation(home_id, now=ts)


def get_or_create_conversation(home_id: int) -> int:
    """Back-compat shim — delegates to the active-conversation helper.
    Existing callers that didn't carry a clock just want "the chat
    conversation right now," which is what the active rule resolves to.
    """
    return get_or_create_active_conversation(home_id)


def get_conversation(conv_id: int) -> dict | None:
    """Single conversation by id. Used by the chat handler to verify a
    user-supplied conversation_id and to read the current title before
    deciding whether to regenerate it."""
    with connect() as c:
        row = c.execute(
            """SELECT id, home_id, title, created_at, last_message_at
               FROM conversations WHERE id = ?""",
            (conv_id,),
        ).fetchone()
        return dict(row) if row else None


def list_conversations(home_id: int) -> list[dict]:
    """All conversations for this home, newest activity first. Each row
    carries enough metadata for the iOS history list — title (may be
    null), timestamps, message count, and a short snippet of the first
    user message for the fallback label / preview line."""
    with connect() as c:
        rows = c.execute(
            """SELECT c.id, c.title, c.created_at, c.last_message_at,
                      (SELECT COUNT(*) FROM messages m
                       WHERE m.conversation_id = c.id) AS message_count,
                      (SELECT m.content FROM messages m
                       WHERE m.conversation_id = c.id AND m.role = 'user'
                       ORDER BY m.id ASC LIMIT 1) AS first_user_text
               FROM conversations c WHERE c.home_id = ?
               ORDER BY COALESCE(c.last_message_at, c.created_at) DESC""",
            (home_id,),
        ).fetchall()
    return [dict(r) for r in rows]


def set_conversation_title(conv_id: int, title: str) -> None:
    """Persist a (probably LLM-generated) title for a conversation.
    Trimmed + capped at 80 chars to keep the iOS list from overflowing."""
    clean = (title or "").strip().strip('"').strip("'")[:80]
    if not clean:
        return
    with connect() as c:
        c.execute(
            "UPDATE conversations SET title = ? WHERE id = ?",
            (clean, conv_id),
        )


def touch_conversation(conv_id: int, *, when: float | None = None) -> None:
    """Bump `last_message_at` so the active-conversation lookup picks
    this thread up next time. Called from add_message — callers don't
    need to invoke it directly."""
    ts = when if when is not None else time.time()
    with connect() as c:
        c.execute(
            "UPDATE conversations SET last_message_at = ? WHERE id = ?",
            (ts, conv_id),
        )


def delete_conversation(conv_id: int) -> bool:
    """Remove one conversation and every message inside it. Returns
    True if a row was deleted. Used by the iOS history list's per-row
    delete affordance."""
    with connect() as c:
        c.execute(
            "DELETE FROM messages WHERE conversation_id = ?", (conv_id,)
        )
        cur = c.execute(
            "DELETE FROM conversations WHERE id = ?", (conv_id,)
        )
        return cur.rowcount > 0


def clear_all_conversations(home_id: int) -> int:
    """Wipe every message AND every conversation row for the home.
    Used by the profile drawer's "Clear chat history" affordance —
    preserves the v0 semantics (clear button = fresh slate)."""
    with connect() as c:
        c.execute(
            """DELETE FROM messages
               WHERE conversation_id IN
                 (SELECT id FROM conversations WHERE home_id = ?)""",
            (home_id,),
        )
        cur = c.execute(
            "DELETE FROM conversations WHERE home_id = ?", (home_id,)
        )
        return cur.rowcount


def _hydrate_message_row(r: sqlite3.Row) -> dict:
    """Convert a messages row to the shape iOS expects. Specifically:
    surface `image_urls` and `product_picks` as real lists, merging in
    the legacy single `image_url` if present so old rows still display
    correctly."""
    d = dict(r)
    urls_json = d.pop("image_urls", None)
    legacy_url = d.pop("image_url", None)
    urls: list[str] = []
    if urls_json:
        try:
            decoded = json.loads(urls_json)
            if isinstance(decoded, list):
                urls = [str(u) for u in decoded if u]
        except json.JSONDecodeError:
            pass
    if not urls and legacy_url:
        urls = [legacy_url]
    d["image_urls"] = urls

    picks_json = d.pop("product_picks", None)
    picks: list[dict] = []
    if picks_json:
        try:
            decoded = json.loads(picks_json)
            if isinstance(decoded, list):
                picks = [p for p in decoded if isinstance(p, dict)]
        except json.JSONDecodeError:
            pass
    d["product_picks"] = picks

    searches_json = d.pop("searches", None)
    searches: list[str] = []
    if searches_json:
        try:
            decoded = json.loads(searches_json)
            if isinstance(decoded, list):
                searches = [str(s) for s in decoded if s]
        except json.JSONDecodeError:
            pass
    d["searches"] = searches
    return d


def add_message(
    conversation_id: int, role: str, content: str,
    image_urls: list[str] | None = None,
    product_picks: list[dict] | None = None,
    searches: list[str] | None = None,
) -> int:
    urls_json = json.dumps(image_urls) if image_urls else None
    picks_json = json.dumps(product_picks) if product_picks else None
    searches_json = json.dumps(searches) if searches else None
    now = time.time()
    with connect() as c:
        cur = c.execute(
            """INSERT INTO messages
                 (conversation_id, role, content,
                  image_urls, product_picks, searches, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (conversation_id, role, content,
             urls_json, picks_json, searches_json, now),
        )
        # Keep the conversation's last_message_at in sync so the
        # active-conversation lookup and the history list both see
        # this turn immediately. Done in the same connection (and
        # autocommit) so a concurrent reader never sees one without
        # the other.
        c.execute(
            "UPDATE conversations SET last_message_at = ? WHERE id = ?",
            (now, conversation_id),
        )
        return cur.lastrowid


def get_recent_messages(conversation_id: int, limit: int = 20) -> list[dict]:
    """Returns most-recent `limit` messages, oldest-first."""
    with connect() as c:
        rows = c.execute(
            """SELECT id, role, content, image_url, image_urls,
                      product_picks, searches, created_at
               FROM messages WHERE conversation_id = ?
               ORDER BY id DESC LIMIT ?""",
            (conversation_id, limit),
        ).fetchall()
        return [_hydrate_message_row(r) for r in reversed(rows)]


def get_all_messages(conversation_id: int) -> list[dict]:
    """All messages, oldest-first. Used by iOS to hydrate the chat view."""
    with connect() as c:
        rows = c.execute(
            """SELECT id, role, content, image_url, image_urls,
                      product_picks, searches, created_at
               FROM messages WHERE conversation_id = ?
               ORDER BY id""",
            (conversation_id,),
        ).fetchall()
        return [_hydrate_message_row(r) for r in rows]


def clear_messages(conversation_id: int) -> int:
    """Delete every message in a conversation. Returns the number deleted.
    Used by the profile drawer's "clear chat history" affordance — fresh
    start for the same home (profile + calendar + rendering are NOT
    affected; just the chat scroll-back)."""
    with connect() as c:
        cur = c.execute(
            "DELETE FROM messages WHERE conversation_id = ?",
            (conversation_id,),
        )
        return cur.rowcount


# ---------- scavenger hunt progress ----------

def get_hunt_progress(home_id: int) -> list[dict]:
    """All hunt rows for this home (any status). Caller filters."""
    with connect() as c:
        rows = c.execute(
            """SELECT item_id, status, notes, notes_source,
                      photo_url, completed_at
               FROM hunt_progress WHERE home_id = ?""",
            (home_id,),
        ).fetchall()
        return [dict(r) for r in rows]


def get_hunt_item(home_id: int, item_id: str) -> dict | None:
    with connect() as c:
        row = c.execute(
            """SELECT item_id, status, notes, notes_source,
                      photo_url, completed_at
               FROM hunt_progress
               WHERE home_id = ? AND item_id = ?""",
            (home_id, item_id),
        ).fetchone()
        return dict(row) if row else None


def upsert_hunt_item(
    home_id: int, item_id: str, status: str,
    *, notes: str | None = None, photo_url: str | None = None,
    notes_source: str | None = None,
) -> None:
    """Insert or update a single item's progress. Status 'done' stamps
    completed_at; other transitions leave it alone (so re-skipping a
    previously-done item still records the original completion time).

    `notes_source` is preserved across status updates unless explicitly
    overwritten — when the user confirms a pre-filled item, we keep
    the provenance so iOS can keep showing the "from your docs" badge."""
    now = time.time() if status == "done" else None
    with connect() as c:
        # Pull existing row to preserve photo_url / notes / completed_at
        # / notes_source when callers update partial fields.
        existing = c.execute(
            """SELECT notes, notes_source, photo_url, completed_at
               FROM hunt_progress
               WHERE home_id = ? AND item_id = ?""",
            (home_id, item_id),
        ).fetchone()
        if existing:
            keep_notes = notes if notes is not None else existing["notes"]
            keep_source = (
                notes_source if notes_source is not None
                else existing["notes_source"]
            )
            keep_photo = (
                photo_url if photo_url is not None else existing["photo_url"]
            )
            keep_completed = (
                now if status == "done" else existing["completed_at"]
            )
            c.execute(
                """UPDATE hunt_progress
                   SET status = ?, notes = ?, notes_source = ?,
                       photo_url = ?, completed_at = ?
                   WHERE home_id = ? AND item_id = ?""",
                (
                    status, keep_notes, keep_source, keep_photo,
                    keep_completed, home_id, item_id,
                ),
            )
        else:
            c.execute(
                """INSERT INTO hunt_progress
                     (home_id, item_id, status, notes, notes_source,
                      photo_url, completed_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    home_id, item_id, status, notes, notes_source,
                    photo_url, now,
                ),
            )


# ---------- events (telemetry) ----------

def log_event(
    event_type: str,
    *,
    home_id: int | None = None,
    payload: dict | None = None,
    user_id: int = DEFAULT_USER_ID,
) -> int:
    """Append one telemetry row. Cheap, fire-and-forget — callers should
    not let event-log failures break the user-facing path, so internal
    errors are swallowed and printed.

    `event_type` is a stable string (e.g. 'app_open', 'chat_turn',
    'hunt_item_done'); `payload` is freeform JSON-encodable dict. Used
    to measure PRD §13 success criteria."""
    try:
        with connect() as c:
            cur = c.execute(
                """INSERT INTO events
                     (user_id, home_id, event_type, payload_json, created_at)
                   VALUES (?, ?, ?, ?, ?)""",
                (
                    user_id, home_id, event_type,
                    json.dumps(payload) if payload else None,
                    time.time(),
                ),
            )
            return cur.lastrowid
    except Exception as e:  # noqa: BLE001
        print(f"[events] log_event({event_type!r}) failed: {e}")
        return -1


def get_events(
    *, event_type: str | None = None, limit: int = 200,
    user_id: int = DEFAULT_USER_ID,
) -> list[dict]:
    """Recent events, newest-first. Used by /debug/events for inspection."""
    with connect() as c:
        if event_type:
            rows = c.execute(
                """SELECT id, event_type, home_id, payload_json, created_at
                   FROM events
                   WHERE user_id = ? AND event_type = ?
                   ORDER BY id DESC LIMIT ?""",
                (user_id, event_type, limit),
            ).fetchall()
        else:
            rows = c.execute(
                """SELECT id, event_type, home_id, payload_json, created_at
                   FROM events WHERE user_id = ?
                   ORDER BY id DESC LIMIT ?""",
                (user_id, limit),
            ).fetchall()
    out = []
    for r in rows:
        d = dict(r)
        raw = d.pop("payload_json", None)
        if raw:
            try:
                d["payload"] = json.loads(raw)
            except json.JSONDecodeError:
                d["payload"] = None
        else:
            d["payload"] = None
        out.append(d)
    return out


def event_counts(
    *, since: float | None = None, user_id: int = DEFAULT_USER_ID,
) -> dict[str, int]:
    """Aggregate counts by event_type, optionally bounded by `since`
    (unix epoch). Used by /debug/events/summary for quick monitoring."""
    with connect() as c:
        if since is None:
            rows = c.execute(
                """SELECT event_type, COUNT(*) AS n
                   FROM events WHERE user_id = ?
                   GROUP BY event_type""",
                (user_id,),
            ).fetchall()
        else:
            rows = c.execute(
                """SELECT event_type, COUNT(*) AS n
                   FROM events
                   WHERE user_id = ? AND created_at >= ?
                   GROUP BY event_type""",
                (user_id, since),
            ).fetchall()
    return {r["event_type"]: r["n"] for r in rows}


def delete_calendar_entry(home_id: int, entry_id: int) -> bool:
    """Remove one calendar entry by id. Used when the user dismisses an
    auto-captured item from the profile drawer's calendar tab. Returns
    True if a row was deleted (False if it didn't exist or belonged to
    another home)."""
    with connect() as c:
        cur = c.execute(
            "DELETE FROM calendar_entries WHERE id = ? AND home_id = ?",
            (entry_id, home_id),
        )
        return cur.rowcount > 0
