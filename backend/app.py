"""
Captain dev backend.

Thin FastAPI wrapper around the first-session pipeline (currently in
../first_session.py). Runs locally on the user's Mac and is called from the
iOS app (simulator) during development.

Endpoints:
  GET  /health
        Liveness check.

  POST /first-session  (multipart)
        Form fields:
          address: string
          photo:   image file (jpg/png/webp)
        Runs property search + LLM extraction + rendering + palette, returns
        a JSON object that's enough for the iOS app to draw the home screen.

  GET  /rendered/<job_id>/<file>
        Statically serves rendered images for the iOS app to display.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import traceback
import uuid
from pathlib import Path
from typing import Annotated, List, Optional

from dotenv import load_dotenv
from fastapi import BackgroundTasks, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from openai import OpenAI

# Make the project root importable so we reuse the pipeline code we already
# built. Single source of truth for rendering prompts + extraction logic.
PROJECT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(PROJECT_ROOT))
load_dotenv(PROJECT_ROOT / ".env")

from render_prototype import (  # noqa: E402
    VARIANTS,
    extract_palette,
    render_variant,
)
from first_session import (  # noqa: E402
    extract_home_features,
    firecrawl_search,
    pick_current_season,
)
from backend import store, profiles, chat as chat_mod, geocode  # noqa: E402

RENDERED_DIR = Path(__file__).parent / "rendered"
RENDERED_DIR.mkdir(exist_ok=True)
CHAT_PHOTOS_DIR = Path(__file__).parent / "chat-photos"
CHAT_PHOTOS_DIR.mkdir(exist_ok=True)

# Initialise SQLite schema + markdown profile files on import so the very
# first request can hit them without a migration step.
store.init_db()
profiles.ensure_initialized()

app = FastAPI(title="Captain backend (dev)")

# Permissive CORS for local dev only. Lock down before any non-localhost use.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount(
    "/rendered",
    StaticFiles(directory=str(RENDERED_DIR)),
    name="rendered",
)
app.mount(
    "/chat-photos",
    StaticFiles(directory=str(CHAT_PHOTOS_DIR)),
    name="chat-photos",
)


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "has_openai_key": bool(os.getenv("OPENAI_API_KEY")),
        "has_firecrawl_key": bool(os.getenv("FIRECRAWL_API_KEY")),
    }


def _fixture_response() -> dict | None:
    """Return canned first-session data if CAPTAIN_DEV_FIXTURE=1.

    Lets the iOS app exercise the full flow during UI iteration without
    burning ~$0.55 + 60 seconds of latency per tap. Returns None when the
    env flag is off, in which case the real pipeline runs.

    Uses the existing prototype-output/IMG_0754 renderings and the saved
    features.json from the validated Silsby run.
    """
    if os.getenv("CAPTAIN_DEV_FIXTURE") != "1":
        return None

    fixture_render_src = PROJECT_ROOT / "prototype-output" / "IMG_0754"
    fixture_features = PROJECT_ROOT / "first-session-output" / "features.json"
    if not fixture_render_src.exists() or not fixture_features.exists():
        return None

    # Copy renderings into a stable job dir so the static mount serves them.
    job_id = "fixture-silsby"
    job_dir = RENDERED_DIR / job_id
    if not job_dir.exists():
        shutil.copytree(fixture_render_src, job_dir)

    renderings = {
        v: f"/rendered/{job_id}/{v}.png"
        for v in VARIANTS
        if (job_dir / f"{v}.png").exists()
    }
    extraction = json.loads(fixture_features.read_text())
    current_season = pick_current_season()
    return {
        "job_id": job_id,
        "address": "4221 Silsby Rd, University Heights, OH 44118",
        "current_season": current_season,
        "current_rendering_url": (
            renderings.get(current_season) or renderings.get("base")
        ),
        "renderings": renderings,
        "render_errors": {},
        "palette": ["#b22222", "#ffffff", "#a9a9a9",
                    "#d2b48c", "#000000", "#ffd700"],
        "features": extraction.get("features", []),
        "source_urls": extraction.get("source_urls", []),
        "fixture": True,
    }


def _render_remaining_seasons(
    photo_path: Path, job_dir: Path, already_done: set[str]
) -> None:
    """Background task: render the seasonal variants that weren't rendered
    synchronously. Errors are logged but don't crash anything — the user's
    first-session response has already been sent. By the time a season
    changes, these should be cached on disk."""
    client = OpenAI()
    for variant_name, prompt in VARIANTS.items():
        if variant_name in already_done:
            continue
        _, path, err = render_variant(
            client, photo_path, variant_name, prompt, job_dir
        )
        if err:
            print(f"[first-session bg] render error {variant_name}: {err}")
        elif path:
            print(f"[first-session bg] rendered {variant_name}")


@app.post("/first-session")
async def first_session(
    address: Annotated[str, Form()],
    photo: Annotated[UploadFile, File()],
    background_tasks: BackgroundTasks,
) -> dict:
    fixture = _fixture_response()
    if fixture is not None:
        print("[first-session] returning dev fixture (CAPTAIN_DEV_FIXTURE=1)")
        return fixture

    if not os.getenv("OPENAI_API_KEY"):
        raise HTTPException(500, "OPENAI_API_KEY missing on backend")
    if not os.getenv("FIRECRAWL_API_KEY"):
        raise HTTPException(500, "FIRECRAWL_API_KEY missing on backend")

    job_id = uuid.uuid4().hex[:12]
    job_dir = RENDERED_DIR / job_id
    job_dir.mkdir()

    suffix = Path(photo.filename or "upload.jpg").suffix.lower() or ".jpg"
    if suffix not in {".jpg", ".jpeg", ".png", ".webp"}:
        raise HTTPException(400, f"unsupported photo format: {suffix}")
    photo_path = job_dir / f"original{suffix}"
    with open(photo_path, "wb") as f:
        shutil.copyfileobj(photo.file, f)

    client = OpenAI()
    current_season = pick_current_season()

    # 1. Web search for property context (best-effort; failures are non-fatal)
    try:
        search_results = firecrawl_search(
            os.environ["FIRECRAWL_API_KEY"],
            f"{address} property details year built square feet",
        )
    except Exception as e:  # noqa: BLE001
        print(f"[first-session] firecrawl error (continuing without): {e}")
        search_results = []

    # 2. Open-ended feature extraction (photo + web)
    try:
        extraction = extract_home_features(
            client, address, photo_path, search_results
        )
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        raise HTTPException(500, f"extraction failed: {e}") from e
    (job_dir / "features.json").write_text(json.dumps(extraction, indent=2))

    # 3. Render synchronously: just current_season + base. The other three
    #    seasonal variants are scheduled as a background task so the
    #    foreground response returns in ~2 min instead of ~5 min. The
    #    background renders are cached on disk before the season changes
    #    (months away).
    sync_variants = {current_season, "base"}
    renderings: dict[str, str] = {}
    render_errors: dict[str, str] = {}
    for variant_name in sync_variants:
        prompt = VARIANTS[variant_name]
        _, path, err = render_variant(
            client, photo_path, variant_name, prompt, job_dir
        )
        if err:
            render_errors[variant_name] = err
            print(f"[first-session] render error {variant_name}: {err}")
        elif path:
            renderings[variant_name] = f"/rendered/{job_id}/{variant_name}.png"
    if not renderings:
        raise HTTPException(500, f"no renderings produced: {render_errors}")

    # Background-render the remaining seasons after the response is sent.
    background_tasks.add_task(
        _render_remaining_seasons,
        photo_path, job_dir, set(renderings.keys()),
    )

    # 4. Palette (vision-based, focused on the home)
    try:
        palette = extract_palette(client, photo_path)
    except Exception as e:  # noqa: BLE001
        print(f"[first-session] palette error (continuing with empty): {e}")
        palette = []

    current_rendering_url = (
        renderings.get(current_season) or renderings.get("base")
    )

    # Geocode the address so weather + future location-aware features work
    # for THIS home, not a hardcoded fallback. Best-effort: if Nominatim
    # can't resolve it, lat/lng stay None and the home falls back to the
    # backend's DEFAULT coords (Cleveland-ish) for weather.
    coords = geocode.geocode_address(address)
    lat, lng = coords if coords else (None, None)

    # Persist to DB so chat has the home record. The features table is kept
    # as an audit trail of what first-session captured, but chat reads from
    # the markdown profile (which we seed from these features below).
    home_id = store.upsert_home(
        address=address,
        palette=palette,
        current_rendering_url=current_rendering_url,
        renderings=renderings,
        current_season=current_season,
        job_id=job_id,
        lat=lat,
        lng=lng,
    )
    extracted_features = extraction.get("features", [])
    store.replace_first_session_features(home_id, extracted_features)

    # Seed the markdown home profile from the captured features. Only
    # writes if the profile is still the initial placeholder — never
    # overwrites narrative the owner has built up via chat.
    profiles.seed_home_md_from_features(address, extracted_features)

    return {
        "job_id": job_id,
        "address": address,
        "current_season": current_season,
        "current_rendering_url": current_rendering_url,
        "renderings": renderings,
        "render_errors": render_errors,
        "palette": palette,
        "features": extraction.get("features", []),
        "source_urls": extraction.get("source_urls", []),
    }


# ---------- Chat ----------

def _ensure_home_for_chat() -> int:
    """Chat needs a home to be persisted (via first-session). If none yet,
    seed from the dev fixture so iOS can exercise chat without first running
    a real first-session."""
    home = store.get_home()
    if home:
        return home["id"]
    # Seed from fixture data so dev flow works without first-session.
    fixture = chat_mod  # just for module ref; data below is canonical fixture
    return store.upsert_home(
        address="4221 Silsby Rd, University Heights, OH 44118",
        palette=["#b22222", "#ffffff", "#a9a9a9",
                 "#d2b48c", "#000000", "#ffd700"],
        current_rendering_url="/rendered/fixture-silsby/spring.png",
        renderings={},
        current_season="spring",
        job_id="seed",
        lat=41.500,
        lng=-81.555,
    )


@app.post("/chat")
async def chat(
    background_tasks: BackgroundTasks,
    message: Annotated[str, Form()] = "",
    photos: Annotated[Optional[List[UploadFile]], File()] = None,
) -> dict:
    """Multipart form:
        message: text (may be empty when only photos are sent)
        photos:  zero or more image files (jpg/png/webp). Repeat the field
                 name to upload multiple in one request.

    Returns: {"response": str, "message_id": int,
              "image_urls": [str, ...], "fixture": bool?}.

    Background: rewrite markdown profiles + extract calendar entries from
    the exchange. The photos (if any) are included in both LLM calls so
    visible-only facts (a dog's breed, an appliance brand, a plant
    species) can land in the profile.
    """
    user_message = (message or "").strip()
    # FastAPI passes an empty file as a single UploadFile with empty
    # filename. Filter those out so they don't count as real attachments.
    real_photos = [
        p for p in (photos or [])
        if p is not None and getattr(p, "filename", "")
    ]
    if not user_message and not real_photos:
        raise HTTPException(400, "message or at least one photo required")

    home_id = _ensure_home_for_chat()

    # Persist each photo so the iOS app can render bubbles via the static
    # mount. We keep the originals around for the lifetime of the
    # conversation; per PRD §9.3 long-term we should purge, but for v1 demo
    # the better UX is to keep them.
    saved_photo_paths: list[Path] = []
    photo_urls: list[str] = []
    for p in real_photos:
        suffix = Path(p.filename or "upload.jpg").suffix.lower()
        if suffix not in {".jpg", ".jpeg", ".png", ".webp"}:
            raise HTTPException(400, f"unsupported photo format: {suffix}")
        fname = f"{uuid.uuid4().hex}{suffix}"
        path = CHAT_PHOTOS_DIR / fname
        with open(path, "wb") as f:
            shutil.copyfileobj(p.file, f)
        saved_photo_paths.append(path)
        photo_urls.append(f"/chat-photos/{fname}")

    # Dev fixture: skip LLM, return canned response. Still persists messages
    # so we can exercise the iOS chat UI fully (including image bubbles).
    if os.getenv("CAPTAIN_DEV_FIXTURE") == "1":
        n = len(photo_urls)
        if n > 0:
            assistant_text = (
                f"(dev fixture) I see your {n} "
                f"photo{'s' if n > 1 else ''}. "
                "In real mode I'd analyze and respond."
            )
        else:
            assistant_text = chat_mod.fixture_chat_response(user_message)
        conv_id = store.get_or_create_conversation(home_id)
        store.add_message(
            conv_id, "user", user_message,
            image_urls=photo_urls if photo_urls else None,
        )
        msg_id = store.add_message(conv_id, "assistant", assistant_text)
        return {
            "message_id": msg_id,
            "response": assistant_text,
            "image_urls": photo_urls,
            "fixture": True,
        }

    if not os.getenv("OPENAI_API_KEY"):
        raise HTTPException(500, "OPENAI_API_KEY missing on backend")

    try:
        assistant_text = chat_mod.respond_to_message(
            home_id, user_message,
            image_paths=saved_photo_paths,
            image_urls=photo_urls,
        )
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        raise HTTPException(500, f"chat failed: {e}") from e

    # The user + assistant messages are already persisted inside
    # respond_to_message. We just need the latest message id.
    conv_id = store.get_or_create_conversation(home_id)
    latest = store.get_recent_messages(conv_id, limit=1)
    msg_id = latest[0]["id"] if latest else -1

    # Background: rewrite markdown profiles + extract calendar entries.
    # Failures here don't affect the foreground response.
    background_tasks.add_task(
        chat_mod.update_memory_from_exchange,
        home_id, user_message, assistant_text,
        saved_photo_paths,
    )

    return {
        "message_id": msg_id,
        "response": assistant_text,
        "image_urls": photo_urls,
    }


@app.get("/weather")
def weather() -> dict:
    """Structured forecast for the home's location. Used by the iOS home
    screen widget. Cached for an hour at the weather module. Returns enough
    periods to safely cover 3 daytime days regardless of current local time
    (NWS alternates day/night periods, so 14 periods = ~7 days)."""
    from backend.weather import get_forecast_structured
    home = store.get_home() or {}
    lat = home.get("lat") or chat_mod.DEFAULT_LAT
    lng = home.get("lng") or chat_mod.DEFAULT_LNG
    return {"periods": get_forecast_structured(lat, lng, max_periods=14)}


@app.get("/profile")
def get_profile() -> dict:
    """Everything the iOS profile drawer surfaces: address, home + owner
    markdown profiles, full calendar. PRD §7.7: this surface is rarely
    visited and never primary — it just lets the owner see what Captain
    has gathered."""
    home = store.get_home()
    home_id = home["id"] if home else None
    return {
        "address": (home or {}).get("address"),
        "home_md": profiles.read_home_md(),
        "user_md": profiles.read_user_md(),
        "calendar": store.get_calendar(home_id) if home_id else [],
    }


@app.get("/messages")
def get_messages() -> dict:
    """Hydrate the chat view on iOS launch / refresh."""
    home = store.get_home()
    if not home:
        return {"messages": []}
    conv_id = store.get_or_create_conversation(home["id"])
    return {"messages": store.get_all_messages(conv_id)}


@app.get("/debug/state")
def debug_state() -> dict:
    """Inspect what the backend has learned so far. Dev convenience."""
    home = store.get_home()
    if not home:
        return {"home": None, "home_md": profiles.read_home_md(),
                "user_md": profiles.read_user_md()}
    home_id = home["id"]
    return {
        "home": {"id": home_id, "address": home["address"]},
        "home_md": profiles.read_home_md(),
        "user_md": profiles.read_user_md(),
        "calendar": store.get_calendar(home_id),
        "message_count": len(store.get_all_messages(
            store.get_or_create_conversation(home_id)
        )),
    }
