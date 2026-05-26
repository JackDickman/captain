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
import sqlite3
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

DB_PATH = Path(__file__).parent / "captain.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS home (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT NOT NULL,
    palette_json TEXT,            -- JSON array of hex strings
    current_rendering_url TEXT,
    renderings_json TEXT,         -- JSON dict season -> url
    current_season TEXT,
    job_id TEXT,
    lat REAL,
    lng REAL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
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
    created_at REAL NOT NULL,
    FOREIGN KEY (home_id) REFERENCES home(id)
);

CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL,
    role TEXT NOT NULL,           -- user | assistant
    content TEXT NOT NULL,
    image_url TEXT,               -- legacy single-photo field (kept for old rows)
    image_urls TEXT,              -- JSON array of relative URLs for attached photos
    product_picks TEXT,           -- JSON array of product cards (assistant-side only)
    created_at REAL NOT NULL,
    FOREIGN KEY (conversation_id) REFERENCES conversations(id)
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id);
"""


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
        ]:
            try:
                c.execute(ddl)
            except sqlite3.OperationalError:
                pass  # column already exists


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
) -> int:
    """Replace the single home row. Returns its id."""
    now = time.time()
    with connect() as c:
        row = c.execute("SELECT id, created_at FROM home LIMIT 1").fetchone()
        if row is None:
            cur = c.execute(
                """INSERT INTO home (address, palette_json,
                                     current_rendering_url, renderings_json,
                                     current_season, job_id, lat, lng,
                                     created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (address, json.dumps(palette), current_rendering_url,
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

def get_or_create_conversation(home_id: int) -> int:
    with connect() as c:
        row = c.execute(
            "SELECT id FROM conversations WHERE home_id = ? LIMIT 1",
            (home_id,),
        ).fetchone()
        if row:
            return row["id"]
        cur = c.execute(
            "INSERT INTO conversations (home_id, created_at) VALUES (?, ?)",
            (home_id, time.time()),
        )
        return cur.lastrowid


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
    return d


def add_message(
    conversation_id: int, role: str, content: str,
    image_urls: list[str] | None = None,
    product_picks: list[dict] | None = None,
) -> int:
    urls_json = json.dumps(image_urls) if image_urls else None
    picks_json = json.dumps(product_picks) if product_picks else None
    with connect() as c:
        cur = c.execute(
            """INSERT INTO messages
                 (conversation_id, role, content,
                  image_urls, product_picks, created_at)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (conversation_id, role, content,
             urls_json, picks_json, time.time()),
        )
        return cur.lastrowid


def get_recent_messages(conversation_id: int, limit: int = 20) -> list[dict]:
    """Returns most-recent `limit` messages, oldest-first."""
    with connect() as c:
        rows = c.execute(
            """SELECT id, role, content, image_url, image_urls,
                      product_picks, created_at
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
                      product_picks, created_at
               FROM messages WHERE conversation_id = ?
               ORDER BY id""",
            (conversation_id,),
        ).fetchall()
        return [_hydrate_message_row(r) for r in rows]
