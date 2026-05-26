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
import threading
import time
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
    validate_setup_inputs,
)
from backend import store, profiles, chat as chat_mod, geocode, radar  # noqa: E402

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
    burning API spend. Returns None when the env flag is off, in which
    case the real async pipeline runs.

    Wrapped in {status, result, ...} to match the new async response
    shape; iOS treats `result` being present as "no polling needed".
    """
    if os.getenv("CAPTAIN_DEV_FIXTURE") != "1":
        return None

    fixture_render_src = PROJECT_ROOT / "prototype-output" / "IMG_0754"
    fixture_features = PROJECT_ROOT / "first-session-output" / "features.json"
    if not fixture_render_src.exists() or not fixture_features.exists():
        return None

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
    result = {
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
    return {
        "job_id": job_id,
        "status": "done",
        "stage": "finishing",
        "message": "Ready",
        "result": result,
    }


# ---------- Async first-session job tracking ----------

# Per-process in-memory job table. Single-user v1 only; revisit with a
# real queue (Redis/Celery) when we add multi-tenancy.
_jobs: dict[str, dict] = {}
_jobs_lock = threading.Lock()

# User-facing message per stage. Kept short and concrete so the loading
# screen reads as a quiet narration of what Captain is doing.
_STAGE_MESSAGES = {
    "starting": "Captain is getting to know your home",
    "checking": "Making sure that's your home…",
    "searching": "Looking up your home in public records…",
    "studying": "Studying the photo of your home…",
    "painting": "Painting a portrait of your home…",
    "finishing": "Almost there…",
}


def _create_job(job_id: str) -> None:
    with _jobs_lock:
        _jobs[job_id] = {
            "status": "running",
            "stage": "starting",
            "message": _STAGE_MESSAGES["starting"],
            "started_at": time.time(),
            "result": None,
            "error": None,
        }


def _set_stage(job_id: str, stage: str) -> None:
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is not None:
            job["stage"] = stage
            job["message"] = _STAGE_MESSAGES.get(stage, stage)


def _finish_job(job_id: str, result: dict) -> None:
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is not None:
            job["status"] = "done"
            job["stage"] = "finishing"
            job["message"] = "Ready"
            job["result"] = result
            job["finished_at"] = time.time()


def _fail_job(job_id: str, error: str) -> None:
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is not None:
            job["status"] = "error"
            job["message"] = "Something went wrong"
            job["error"] = error
            job["finished_at"] = time.time()


def _get_job(job_id: str) -> dict | None:
    with _jobs_lock:
        job = _jobs.get(job_id)
        return dict(job) if job else None


def _render_remaining_seasons(
    photo_path: Path, job_dir: Path, already_done: set[str]
) -> None:
    """Background task: render the variants that weren't rendered
    synchronously. Now includes `base` + the three off-season variants,
    since current_season is the only sync render. Errors are logged but
    don't crash anything — the user's first-session response has already
    been sent. By the time the user navigates to a different season,
    these should be cached on disk."""
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


def _run_first_session_job(
    job_id: str, address: str, photo_path: Path, job_dir: Path,
) -> None:
    """Worker that runs the actual first-session pipeline. Mutates _jobs
    as it advances through stages. Called from a daemon thread so the
    POST handler can return immediately."""
    try:
        client = OpenAI()
        current_season = pick_current_season()

        # Stage 0: sanity-check the photo + address before burning 30+s
        # of pipeline work. Cheap (geocode + one nano-vision call ≈ 2-3s).
        # A failure here ends the job with a user-facing message that iOS
        # surfaces directly in the form view.
        _set_stage(job_id, "checking")
        ok, validation_error = validate_setup_inputs(
            client, photo_path, address,
        )
        if not ok:
            _fail_job(job_id, validation_error or "Validation failed.")
            return

        # Stage 1: geocode + firecrawl (cheap network + property scrape)
        _set_stage(job_id, "searching")
        coords = geocode.geocode_address(address)
        lat, lng = coords if coords else (None, None)
        try:
            search_results = firecrawl_search(
                os.environ["FIRECRAWL_API_KEY"],
                f"{address} property details year built square feet",
            )
        except Exception as e:  # noqa: BLE001
            print(f"[first-session] firecrawl error (continuing): {e}")
            search_results = []

        # Stage 2: vision + web feature extraction
        _set_stage(job_id, "studying")
        extraction = extract_home_features(
            client, address, photo_path, search_results,
        )
        (job_dir / "features.json").write_text(json.dumps(extraction, indent=2))

        # Stage 3: render the CURRENT SEASON only. `base` and the other
        # three seasonal variants are background-rendered after the
        # response — this drops foreground wait by ~30-45s (Lever 1).
        _set_stage(job_id, "painting")
        sync_variants = [current_season]
        renderings: dict[str, str] = {}
        render_errors: dict[str, str] = {}
        for variant_name in sync_variants:
            prompt = VARIANTS[variant_name]
            # Retry once on safety-classifier false positives — they
            # almost never re-fire on the same prompt.
            for attempt in range(2):
                _, path, err = render_variant(
                    client, photo_path, variant_name, prompt, job_dir,
                )
                if path:
                    renderings[variant_name] = (
                        f"/rendered/{job_id}/{variant_name}.png"
                    )
                    break
                if attempt == 1:
                    render_errors[variant_name] = err
                    print(
                        f"[first-session] render error {variant_name}: {err}"
                    )
        if not renderings:
            raise RuntimeError(
                f"no synchronous renderings produced: {render_errors}"
            )

        # Stage 4: palette + DB writes
        _set_stage(job_id, "finishing")
        try:
            palette = extract_palette(client, photo_path)
        except Exception as e:  # noqa: BLE001
            print(f"[first-session] palette error (empty): {e}")
            palette = []

        current_rendering_url = renderings.get(current_season)

        home_id = store.upsert_home(
            address=address,
            palette=palette,
            current_rendering_url=current_rendering_url,
            renderings=renderings,
            current_season=current_season,
            job_id=job_id,
            lat=lat, lng=lng,
        )
        extracted_features = extraction.get("features", [])
        store.replace_first_session_features(home_id, extracted_features)
        profiles.seed_home_md_from_features(address, extracted_features)

        result = {
            "job_id": job_id,
            "address": address,
            "current_season": current_season,
            "current_rendering_url": current_rendering_url,
            "renderings": renderings,
            "render_errors": render_errors,
            "palette": palette,
            "features": extracted_features,
            "source_urls": extraction.get("source_urls", []),
        }
        _finish_job(job_id, result)

        # Background-render `base` + remaining seasons. Failures here
        # don't matter — the foreground response is already sent.
        threading.Thread(
            target=_render_remaining_seasons,
            args=(photo_path, job_dir, set(renderings.keys())),
            daemon=True,
        ).start()

    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        _fail_job(job_id, str(e))


@app.post("/first-session")
async def first_session(
    address: Annotated[str, Form()],
    photo: Annotated[UploadFile, File()],
) -> dict:
    """Kicks off the first-session pipeline asynchronously.

    Returns immediately with {job_id, status="running"}. iOS then polls
    GET /first-session/{job_id} every second to read stage / message
    updates and eventually pick up the full `result`.

    Fixture mode short-circuits and returns the full result inline
    (no polling needed).
    """
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

    _create_job(job_id)
    threading.Thread(
        target=_run_first_session_job,
        args=(job_id, address, photo_path, job_dir),
        daemon=True,
    ).start()

    return {
        "job_id": job_id,
        "status": "running",
        "stage": "starting",
        "message": _STAGE_MESSAGES["starting"],
    }


@app.get("/first-session/{job_id}")
def first_session_status(job_id: str) -> dict:
    """Poll endpoint. iOS hits this every ~1s after the kickoff POST until
    `status` becomes 'done' (with a populated `result`) or 'error'."""
    job = _get_job(job_id)
    if job is None:
        raise HTTPException(404, f"job {job_id} not found")
    return {
        "job_id": job_id,
        "status": job["status"],
        "stage": job.get("stage", ""),
        "message": job.get("message", ""),
        "result": job.get("result"),
        "error": job.get("error"),
    }


# ---------- Chat ----------

def _send_canned_chat_reply(
    home_id: int, user_message: str, photo_urls: list[str],
    canned_text: str,
) -> dict:
    """Persist the user message + a canned assistant reply, and skip the
    background memory update. Used for messages the scope gate flagged as
    off-topic or out-of-capability — those aren't real home conversations,
    so we don't want them poisoning the home/owner profile rewrite."""
    conv_id = store.get_or_create_conversation(home_id)
    store.add_message(
        conv_id, "user", user_message,
        image_urls=photo_urls if photo_urls else None,
    )
    msg_id = store.add_message(conv_id, "assistant", canned_text)
    return {
        "message_id": msg_id,
        "response": canned_text,
        "image_urls": photo_urls,
    }


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

    # Scope gate. Classify text-bearing messages with ≥2 words; skip the
    # gate for photo-only sends (likely a home photo the user wants
    # Captain to look at) and for very short continuations ("yes",
    # "ok") where the classifier is more noise than signal.
    scope = "in_scope"
    if user_message and len(user_message.split()) >= 2:
        scope, reason = chat_mod.classify_message_scope(user_message)
        if scope != "in_scope":
            print(f"[scope] {scope}: {reason}")

    if scope == "off_topic":
        return _send_canned_chat_reply(
            home_id, user_message, photo_urls,
            chat_mod.OFF_TOPIC_REPLY,
        )
    if scope == "out_of_capability":
        return _send_canned_chat_reply(
            home_id, user_message, photo_urls,
            chat_mod.OUT_OF_CAPABILITY_REPLY,
        )

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


@app.get("/radar")
def get_radar() -> dict:
    """What's on the owner's plate right now: upcoming calendar items +
    LLM-generated suggestions tied to the home's profile, weather, and
    season. Suggestions are cached for 2 hours."""
    if os.getenv("CAPTAIN_DEV_FIXTURE") == "1":
        return radar.fixture_radar_response()
    home = store.get_home()
    if not home:
        import time as _time
        return {
            "calendar_items": [],
            "suggestions": [],
            "generated_at": _time.time(),
        }
    return radar.build_radar_response(home["id"])


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
