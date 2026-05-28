"""
Markdown-document memory for Captain.

Two living markdown files — one about the HOME, one about the OWNER — are the
durable narrative memory of the app. Each chat reads both as system context.
A background LLM call after each chat rewrites them (or returns them
unchanged) so they accumulate richer specifics over time.

Why markdown instead of structured rows: the only consumer of profile data
is the LLM. Storing facts as denormalized rows just to flatten them back
into text on every read is wasted abstraction — and it forces awkward
dedup/merge logic. Markdown lets the model integrate new specifics into
existing prose naturally ("they have a dog" → "they have Jackie, an 8-year
old yellow lab who sniffs constantly, so they avoid lawn chemicals").

Risks accepted:
  - Drift: a rewrite might drop a fact. Mitigations: explicit "preserve
    everything not contradicted" instruction in the prompt; timestamped
    version snapshots in profiles/history/ so any regression is recoverable.
  - Token cost: full profile sent every chat. With mini and a ~3KB cap,
    this is ~$0.0005/chat. Negligible.
  - Concurrency: single-process, single-user for v1 — GIL serializes
    rewrites. Revisit when we add multi-tenancy.

Calendar stays structured (DB) — dates need to be queryable for the radar
and digest features.
"""

from __future__ import annotations

import base64
import json
import os
import threading
import time
from pathlib import Path

from . import llm

# Per-home rewrite serialization. The rewriter does read-modify-write on
# home.md / user.md, so two concurrent chat turns racing the same files
# would drop one turn's update. v1 has one home → a single Lock is fine;
# when multi-home arrives, swap to a dict[home_id, Lock]. The lock spans
# the whole LLM call so both reads + writes happen atomically per home.
_rewrite_lock = threading.Lock()

PROFILES_DIR = Path(__file__).parent / "profiles"
HISTORY_DIR = PROFILES_DIR / "history"
HOME_MD = PROFILES_DIR / "home.md"
USER_MD = PROFILES_DIR / "user.md"

# Profile rewrite is the OTHER place quality matters — drift here = lost
# trust. Mini for stronger instruction-following / preservation discipline.
UPDATE_MODEL = os.getenv("CAPTAIN_UPDATE_MODEL", "gpt-5.4-mini")

# Hard cap on profile size to bound context cost and force the LLM to
# refactor rather than grow indefinitely. ~3000 tokens at typical ratios.
MAX_PROFILE_CHARS = 12_000

UPDATE_SCHEMA = {
    "type": "object",
    "properties": {
        "home_md": {
            "type": "string",
            "description": (
                "FULL updated content of the home profile, or the exact "
                "current content if no update is needed. Never empty."
            ),
        },
        "user_md": {
            "type": "string",
            "description": (
                "FULL updated content of the owner profile, or the exact "
                "current content if no update is needed. Never empty."
            ),
        },
        "change_summary": {
            "type": "string",
            "description": (
                "One short sentence describing what changed across both "
                "documents (or 'no changes' if neither was updated). For "
                "logging/audit only."
            ),
        },
    },
    "required": ["home_md", "user_md", "change_summary"],
    "additionalProperties": False,
}

INITIAL_HOME_MD = """# Home profile

(empty — Captain will populate this once a first-session photo is captured
and as the owner shares more in chat)
"""

INITIAL_USER_MD = """# Owner profile

(empty — Captain will fill this in over time from what the owner says in
chat; never asks them to fill out a form)
"""


def ensure_initialized() -> None:
    """Create the profiles directory + seed empty documents if missing."""
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    if not HOME_MD.exists():
        HOME_MD.write_text(INITIAL_HOME_MD)
    if not USER_MD.exists():
        USER_MD.write_text(INITIAL_USER_MD)


def read_home_md() -> str:
    ensure_initialized()
    return HOME_MD.read_text()


def read_user_md() -> str:
    ensure_initialized()
    return USER_MD.read_text()


def _snapshot(path: Path) -> None:
    """Copy current contents into history/<name>.<unix_ts>.md before
    overwriting. Cheap insurance against bad rewrites."""
    if not path.exists():
        return
    ts = int(time.time())
    snap = HISTORY_DIR / f"{path.stem}.{ts}.md"
    snap.write_text(path.read_text())


def write_home_md(content: str) -> None:
    ensure_initialized()
    if content == HOME_MD.read_text():
        return  # no-op skip; don't pollute history
    _snapshot(HOME_MD)
    HOME_MD.write_text(content)


def write_user_md(content: str) -> None:
    ensure_initialized()
    if content == USER_MD.read_text():
        return
    _snapshot(USER_MD)
    USER_MD.write_text(content)


def seed_home_md_from_features(address: str, features: list[dict]) -> None:
    """Called after first-session to populate home.md from the captured
    features. Only runs if the home profile is still the initial placeholder
    OR is empty — never overwrites a profile the owner has built up via chat.
    """
    ensure_initialized()
    current = HOME_MD.read_text().strip()
    if current and current != INITIAL_HOME_MD.strip():
        return  # owner has accumulated content; leave it alone

    by_cat: dict[str, list[str]] = {}
    for f in features:
        cat = (f.get("category") or "other").lower()
        by_cat.setdefault(cat, []).append(f["text"])

    parts: list[str] = [
        "# Home profile",
        "",
        f"**Address:** {address}",
        "",
        "_Initial profile seeded from the first-session photo and public "
        "records. Captain refines this in the background as the owner "
        "shares more in chat._",
        "",
    ]
    # Stable category order for readability.
    preferred = [
        "architecture", "exterior", "layout", "history",
        "landscaping", "climate", "neighborhood", "systems",
    ]
    seen = set()
    for cat in preferred + sorted(by_cat.keys()):
        if cat in seen or cat not in by_cat:
            continue
        seen.add(cat)
        parts.append(f"## {cat.title()}")
        parts.append("")
        for line in by_cat[cat]:
            parts.append(f"- {line}")
        parts.append("")

    write_home_md("\n".join(parts).rstrip() + "\n")


def update_profiles_from_exchange(
    user_message: str, assistant_message: str,
    image_paths: list[Path] | None = None,
) -> dict:
    """Background: ask the LLM to integrate anything new from the latest
    exchange into the home + user markdown profiles. Returns the structured
    response from the model (or {} on failure).

    Serialized by `_rewrite_lock` so two background turns landing close
    together can't race the read-modify-write of home.md / user.md."""
    with _rewrite_lock:
        return _update_profiles_locked(
            user_message, assistant_message, image_paths,
        )


def _update_profiles_locked(
    user_message: str, assistant_message: str,
    image_paths: list[Path] | None = None,
) -> dict:
    home_md = read_home_md()
    user_md = read_user_md()

    sys_prompt = (
        "You are the persistent-memory layer of Captain, a homeowner-care "
        "app dedicated to a single home and its owner. You maintain two "
        "living markdown documents:\n\n"
        "1. HOME PROFILE — facts about this specific home: architecture, "
        "systems, materials, landscaping, history, known quirks, recent "
        "work, scheduled work.\n"
        "2. OWNER PROFILE — facts about the person/people who live here: "
        "household composition, pets, kids, preferences, DIY comfort, "
        "communication preferences, anything personal they share.\n\n"
        "Both documents are read by Captain as system context before every "
        "chat response. The richer and more specific they are, the better "
        "Captain's responses get.\n\n"
        "You are given the CURRENT contents of both documents and the "
        "LATEST exchange between the owner and Captain. Your job: return "
        "the FULL updated content of both documents, integrating anything "
        "new and worth remembering from the exchange. If a document "
        "doesn't need updates, return it EXACTLY as-is.\n\n"
        "Hard rules — these are non-negotiable:\n"
        " - PRESERVE every fact in the current documents that was not "
        "explicitly contradicted by the exchange. Do not drop facts. Do "
        "not summarize away specifics.\n"
        " - ADD new specifics — names, ages, breeds, brands, model "
        "numbers, dates, dimensions, REASONS, preferences. \"They have a "
        "dog\" is weak. \"Jackie, an 8-year-old female yellow lab who "
        "sniffs the ground constantly, so the owner avoids lawn "
        "chemicals\" is what we want.\n"
        " - CAPTURE TONE SIGNALS in the OWNER PROFILE under a "
        "\"Communication\" section. Maintain it as plain prose, not a "
        "checklist. Watch for and integrate:\n"
        "     * jargon level — beginner questions (\"what's a P-trap?\") "
        "vs. casual technical talk (re-caulking, soldering, swapping a "
        "GFCI). Note which side they're on and update when evidence "
        "shifts.\n"
        "     * preferred length — terse one-word replies suggest they "
        "want short answers; conversational paragraphs suggest they're "
        "fine with a bit more.\n"
        "     * direct preferences — \"stop explaining the basics\", "
        "\"just give me the steps\", \"I want more context\" should be "
        "recorded verbatim or near-verbatim so future chats honor them.\n"
        "     * sensitivities — chemical, fragrance, dust, noise, "
        "anything they want avoided. Always relevant to recommendations.\n"
        "   When tone evidence contradicts what's already there (e.g. a "
        "newcomer who's now done several DIY projects), UPDATE the "
        "Communication section — don't just append a contradicting line.\n"
        " - REFINE existing facts with new detail. If the document already "
        "mentions a dog and the exchange reveals the dog's name and "
        "breed, INTEGRATE that into the existing mention — don't add a "
        "separate paragraph.\n"
        " - WRITE natural-language prose with markdown headings. Avoid "
        "bullet-point dumps of disconnected facts.\n"
        " - DON'T fabricate. If you're not sure of a fact, leave it out.\n"
        " - DON'T summarize past chat history into the profiles. The "
        "conversation log handles that. Only durable facts about the home "
        "or person belong here.\n"
        " - DON'T grow indefinitely. If a section gets dense, refactor "
        f"into clearer subsections. Hard cap: {MAX_PROFILE_CHARS} chars per "
        "document.\n"
        " - NEVER include sale prices, market values, tax assessments, or "
        "any financial valuation. This app deliberately avoids financial "
        "surfaces.\n"
        " - If you have NO updates for a document, return it exactly as "
        "given. Don't reword or restructure for its own sake — only when "
        "integrating new information.\n\n"
        f"CURRENT HOME PROFILE:\n```markdown\n{home_md}\n```\n\n"
        f"CURRENT OWNER PROFILE:\n```markdown\n{user_md}\n```\n\n"
        "LATEST EXCHANGE:\n"
        f"OWNER: {user_message}\n"
        f"CAPTAIN: {assistant_message}"
    )

    # If photos were attached to the user's message, send them all to the
    # rewriter. Visible-only details (a dog's breed, an appliance brand, a
    # plant species, a specific architectural feature) often only land in
    # the profile if the model can see the photo, not just read the prose.
    valid_paths = [p for p in (image_paths or []) if p.exists()]
    if valid_paths:
        content: list[dict] = [{"type": "text", "text": sys_prompt}]
        for p in valid_paths:
            img_b64 = base64.b64encode(p.read_bytes()).decode()
            suffix = p.suffix.lower().lstrip(".")
            mime = "jpeg" if suffix == "jpg" else suffix
            content.append({
                "type": "image_url",
                "image_url": {"url": f"data:image/{mime};base64,{img_b64}"},
            })
        chat_messages = [{"role": "user", "content": content}]
    else:
        chat_messages = [{"role": "system", "content": sys_prompt}]

    try:
        resp = llm.chat_completion(
            model=UPDATE_MODEL,
            messages=chat_messages,
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "profile_update",
                    "schema": UPDATE_SCHEMA,
                    "strict": True,
                },
            },
        )
    except Exception as e:  # noqa: BLE001
        print(f"[profiles] update call failed: {e}")
        return {}

    try:
        payload = json.loads(resp.text or "{}")
    except (json.JSONDecodeError, AttributeError) as e:
        print(f"[profiles] response parse failed: {e}")
        return {}

    new_home = (payload.get("home_md") or "").strip()
    new_user = (payload.get("user_md") or "").strip()
    summary = payload.get("change_summary", "")

    # Safety: refuse to write a profile that's gone empty or implausibly
    # smaller than current. A drop of more than 30% is a red flag — likely
    # the model decided to "summarize" instead of preserve.
    def _safe(new: str, old: str, name: str) -> str:
        if not new:
            print(f"[profiles] {name}: model returned empty; keeping current")
            return old
        if len(old) > 200 and len(new) < len(old) * 0.7:
            print(f"[profiles] {name}: model shrank profile from "
                  f"{len(old)} to {len(new)} chars; keeping current")
            return old
        return new

    new_home = _safe(new_home, home_md, "home.md")
    new_user = _safe(new_user, user_md, "user.md")

    if new_home != home_md:
        write_home_md(new_home + ("" if new_home.endswith("\n") else "\n"))
    if new_user != user_md:
        write_user_md(new_user + ("" if new_user.endswith("\n") else "\n"))

    print(f"[profiles] update: {summary} | "
          f"home {len(home_md)}→{len(new_home)} chars, "
          f"user {len(user_md)}→{len(new_user)} chars")
    return payload
