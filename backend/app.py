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

from datetime import datetime, timezone
from dotenv import load_dotenv
from fastapi import (
    BackgroundTasks, FastAPI, File, Form, Header, HTTPException, UploadFile,
)
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


def _parse_local_time(header_value: str | None) -> datetime:
    """Parse the X-Captain-Local-Time header into a tz-aware datetime.

    iOS sends this on every request as ISO 8601 with offset (e.g.
    "2026-05-26T14:15:00-04:00") so any LLM prompt that talks about
    "today" or "local time" can ground against the USER's clock — not
    the server's. Falls back to server local time when the header is
    absent or malformed; ensures the return value is always tz-aware
    so callers can `strftime` without surprises.
    """
    if header_value:
        try:
            # Python 3.11+ accepts trailing 'Z' natively; older versions
            # need it translated to '+00:00'. Cheap to handle either.
            value = header_value.strip()
            if value.endswith("Z"):
                value = value[:-1] + "+00:00"
            dt = datetime.fromisoformat(value)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except (ValueError, TypeError):
            print(f"[time] bad X-Captain-Local-Time: {header_value!r}")
    return datetime.now(timezone.utc).astimezone()


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


# ---------- Speculative prerender ----------

# In-memory registry of in-flight prerenders. Keyed by prefetch_id.
# Each entry: {photo_path, season, done_event, render_path, error,
# started_at}. The done_event is set when the background render finishes
# (success or failure) so /first-session can wait on it deterministically.
_prerenders: dict[str, dict] = {}
_prerenders_lock = threading.Lock()


def _run_prerender(
    prefetch_id: str, photo_path: Path, season: str,
    out_dir: Path, done_event: threading.Event,
) -> None:
    """Background render of the current-season variant for a prefetch.
    Failures are recorded on the registry entry; /first-session falls back
    to a fresh render if the prefetch's render didn't land."""
    try:
        client = OpenAI()
        prompt = VARIANTS[season]
        _, path, err = render_variant(
            client, photo_path, season, prompt, out_dir,
        )
        with _prerenders_lock:
            pr = _prerenders.get(prefetch_id)
            if pr is not None:
                pr["render_path"] = str(path) if path else None
                pr["error"] = err
        elapsed = time.time() - _prerenders[prefetch_id]["started_at"]
        if path:
            print(f"[prerender] {prefetch_id} rendered {season} in "
                  f"{elapsed:.1f}s")
        else:
            print(f"[prerender] {prefetch_id} render failed in "
                  f"{elapsed:.1f}s: {err}")
    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        with _prerenders_lock:
            pr = _prerenders.get(prefetch_id)
            if pr is not None:
                pr["error"] = str(e)
    finally:
        done_event.set()


@app.post("/prerender")
async def prerender(
    photo: Annotated[UploadFile, File()],
) -> dict:
    """Speculative render: kick off the current-season render as soon as
    the user picks a photo, so by the time they type their address and
    submit, the slowest stage is already done or close to done.

    Returns prefetch_id immediately. The actual render runs in a daemon
    thread. If the user abandons (closes the app, picks a different
    photo), the render still completes and is discarded — accepted spend
    in exchange for ~30s shaved off the perceived loading time.
    """
    if os.getenv("CAPTAIN_DEV_FIXTURE") == "1":
        return {"prefetch_id": None, "skipped": True}
    if not os.getenv("OPENAI_API_KEY"):
        raise HTTPException(500, "OPENAI_API_KEY missing on backend")

    prefetch_id = uuid.uuid4().hex[:12]
    pr_dir = RENDERED_DIR / prefetch_id
    pr_dir.mkdir()

    suffix = Path(photo.filename or "upload.jpg").suffix.lower() or ".jpg"
    if suffix not in {".jpg", ".jpeg", ".png", ".webp"}:
        raise HTTPException(400, f"unsupported photo format: {suffix}")
    photo_path = pr_dir / f"original{suffix}"
    with open(photo_path, "wb") as f:
        shutil.copyfileobj(photo.file, f)

    season = pick_current_season()
    done_event = threading.Event()
    with _prerenders_lock:
        _prerenders[prefetch_id] = {
            "photo_path": str(photo_path),
            "season": season,
            "done_event": done_event,
            "render_path": None,
            "error": None,
            "started_at": time.time(),
        }

    threading.Thread(
        target=_run_prerender,
        args=(prefetch_id, photo_path, season, pr_dir, done_event),
        daemon=True,
    ).start()

    return {"prefetch_id": prefetch_id}


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
    *, prefetch_id: str | None = None,
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

        # If this job came in with a prefetch_id, a prerender thread is
        # already producing rendered/<id>/<current_season>.png. Wait on
        # its done_event so render_variant's "skip if exists" check finds
        # the completed file (or falls back to a fresh render if the
        # prerender failed). Timeout is generous — prerender usually
        # started 10-30s before the user typed their address, so most of
        # the wait is already absorbed.
        if prefetch_id:
            with _prerenders_lock:
                pr = _prerenders.get(prefetch_id)
            if pr is not None:
                waited_start = time.time()
                pr["done_event"].wait(timeout=120)
                print(f"[first-session] {job_id} waited "
                      f"{time.time() - waited_start:.1f}s on prerender")

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
    photo: Annotated[Optional[UploadFile], File()] = None,
    prefetch_id: Annotated[Optional[str], Form()] = None,
) -> dict:
    """Kicks off the first-session pipeline asynchronously.

    Returns immediately with {job_id, status="running"}. iOS then polls
    GET /first-session/{job_id} every second to read stage / message
    updates and eventually pick up the full `result`.

    If `prefetch_id` is given (from a prior /prerender call), the photo
    upload is optional — the backend reuses the already-saved photo and
    the in-flight render. Otherwise a fresh photo upload is required.

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

    if prefetch_id:
        # Reuse the prerender directory + photo. The job_id IS the
        # prefetch_id so rendered/<id>/<season>.png written by the
        # prerender thread is in the right place for render_variant to
        # find via its "skip if exists" short-circuit.
        with _prerenders_lock:
            pr = _prerenders.get(prefetch_id)
        if pr is None:
            raise HTTPException(
                400, "Photo expired — please reselect and try again."
            )
        job_id = prefetch_id
        job_dir = RENDERED_DIR / job_id
        photo_path = Path(pr["photo_path"])
        if not photo_path.exists():
            raise HTTPException(
                400, "Photo missing — please reselect and try again."
            )
    else:
        if photo is None or not getattr(photo, "filename", ""):
            raise HTTPException(
                400, "photo required when no prefetch_id is provided"
            )
        job_id = uuid.uuid4().hex[:12]
        job_dir = RENDERED_DIR / job_id
        job_dir.mkdir()
        suffix = (
            Path(photo.filename or "upload.jpg").suffix.lower() or ".jpg"
        )
        if suffix not in {".jpg", ".jpeg", ".png", ".webp"}:
            raise HTTPException(400, f"unsupported photo format: {suffix}")
        photo_path = job_dir / f"original{suffix}"
        with open(photo_path, "wb") as f:
            shutil.copyfileobj(photo.file, f)

    _create_job(job_id)
    threading.Thread(
        target=_run_first_session_job,
        args=(job_id, address, photo_path, job_dir),
        kwargs={"prefetch_id": prefetch_id},
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

# In-memory chat-job registry. Each entry tracks the live state of an
# in-flight chat turn so iOS can poll for stage updates:
#   status: "running" | "done" | "error"
#   stage:  "thinking" | "searching" | "writing"
#   search_query: the most recent web-search query (when stage == "searching")
#   result: the final ChatResponse payload (when status == "done")
#   error:  user-facing error string (when status == "error")
_chat_jobs: dict[str, dict] = {}
_chat_jobs_lock = threading.Lock()

# iOS-facing stage labels. Kept here so the prose lives in one place.
_CHAT_STAGE_LABELS = {
    "thinking": "Captain is thinking…",
    "searching": "Captain is checking the web…",
    "writing": "Captain is writing a response…",
}


def _create_chat_job(chat_id: str) -> None:
    with _chat_jobs_lock:
        _chat_jobs[chat_id] = {
            "status": "running",
            "stage": "thinking",
            "stage_label": _CHAT_STAGE_LABELS["thinking"],
            "search_query": None,
            "result": None,
            "error": None,
            "started_at": time.time(),
        }


def _set_chat_stage(chat_id: str, stage: str, query: str | None = None) -> None:
    with _chat_jobs_lock:
        job = _chat_jobs.get(chat_id)
        if job is None:
            return
        job["stage"] = stage
        job["stage_label"] = _CHAT_STAGE_LABELS.get(stage, stage)
        job["search_query"] = query


def _finish_chat_job(chat_id: str, result: dict) -> None:
    with _chat_jobs_lock:
        job = _chat_jobs.get(chat_id)
        if job is None:
            return
        job["status"] = "done"
        job["stage"] = "done"
        job["stage_label"] = "Ready"
        job["result"] = result
        job["finished_at"] = time.time()


def _fail_chat_job(chat_id: str, error: str) -> None:
    with _chat_jobs_lock:
        job = _chat_jobs.get(chat_id)
        if job is None:
            return
        job["status"] = "error"
        job["error"] = error
        job["finished_at"] = time.time()


def _get_chat_job(chat_id: str) -> dict | None:
    with _chat_jobs_lock:
        job = _chat_jobs.get(chat_id)
        return dict(job) if job else None


def _run_chat_job(
    chat_id: str, home_id: int, user_message: str,
    saved_photo_paths: list[Path], photo_urls: list[str],
    user_now: datetime,
) -> None:
    """Worker thread for a single chat turn. Wraps respond_to_message
    with the stage callback so the iOS UI can show what Captain is
    doing as it works.

    `user_now` carries the iOS device's local time + tz at the moment
    the request was made, so the LLM's "today" / "local time" prompt
    grounding tracks the user's clock instead of the server's."""
    def on_stage(stage: str, query: str | None = None) -> None:
        _set_chat_stage(chat_id, stage, query)

    try:
        outcome = chat_mod.respond_to_message(
            home_id, user_message,
            image_paths=saved_photo_paths,
            image_urls=photo_urls,
            on_stage=on_stage,
            now=user_now,
        )
        # The latest message id is the assistant message we just persisted.
        conv_id = store.get_or_create_conversation(home_id)
        latest = store.get_recent_messages(conv_id, limit=1)
        msg_id = latest[0]["id"] if latest else -1

        result = {
            "message_id": msg_id,
            "response": outcome["text"],
            "image_urls": photo_urls,
            "searches": outcome.get("searches") or [],
            "product_picks": outcome.get("product_picks") or [],
        }
        _finish_chat_job(chat_id, result)

        # Background: rewrite markdown profiles + extract calendar entries.
        # Same as before — runs after we've already returned the result.
        try:
            chat_mod.update_memory_from_exchange(
                home_id, user_message, outcome["text"],
                saved_photo_paths,
                now=user_now,
            )
        except Exception as e:  # noqa: BLE001
            print(f"[chat-job] memory update failed: {e}")

    except Exception as e:  # noqa: BLE001
        traceback.print_exc()
        _fail_chat_job(chat_id, f"chat failed: {e}")


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
    x_captain_local_time: Annotated[Optional[str], Header()] = None,
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
            "status": "done",
            "result": {
                "message_id": msg_id,
                "response": assistant_text,
                "image_urls": photo_urls,
                "fixture": True,
            },
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
        inline = _send_canned_chat_reply(
            home_id, user_message, photo_urls,
            chat_mod.OFF_TOPIC_REPLY,
        )
        # Wrap in the async envelope so iOS can use one polling client
        # for both inline and async cases.
        return {"status": "done", "result": inline}
    if scope == "out_of_capability":
        inline = _send_canned_chat_reply(
            home_id, user_message, photo_urls,
            chat_mod.OUT_OF_CAPABILITY_REPLY,
        )
        return {"status": "done", "result": inline}

    # Real LLM path: kick off async job, return chat_id immediately.
    # iOS polls /chat/{chat_id} to see stage updates (thinking / searching
    # / writing) and to pick up the final result.
    user_now = _parse_local_time(x_captain_local_time)
    chat_id = uuid.uuid4().hex[:12]
    _create_chat_job(chat_id)
    threading.Thread(
        target=_run_chat_job,
        args=(
            chat_id, home_id, user_message,
            saved_photo_paths, photo_urls, user_now,
        ),
        daemon=True,
    ).start()

    return {
        "chat_id": chat_id,
        "status": "running",
        "stage": "thinking",
        "stage_label": _CHAT_STAGE_LABELS["thinking"],
    }


@app.get("/chat/{chat_id}")
def chat_status(chat_id: str) -> dict:
    """Poll endpoint for an in-flight chat turn. iOS hits this every
    ~500ms after the kickoff POST until status is 'done' (with a
    populated `result`) or 'error'.

    The interesting payload during the running phase is `stage` +
    `search_query` — when stage is "searching", search_query holds the
    query the model just invoked, so the iOS bubble can render a clear
    "searching the web for X" indicator."""
    job = _get_chat_job(chat_id)
    if job is None:
        raise HTTPException(404, f"chat {chat_id} not found")
    return {
        "chat_id": chat_id,
        "status": job["status"],
        "stage": job.get("stage", ""),
        "stage_label": job.get("stage_label", ""),
        "search_query": job.get("search_query"),
        "result": job.get("result"),
        "error": job.get("error"),
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
def get_radar(
    x_captain_local_time: Annotated[Optional[str], Header()] = None,
) -> dict:
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
    user_now = _parse_local_time(x_captain_local_time)
    return radar.build_radar_response(home["id"], now=user_now)


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


@app.delete("/messages")
def clear_messages() -> dict:
    """Wipe the chat history for the current home. Profile + calendar +
    rendering are untouched — just the chat scroll-back resets. Used by
    the profile drawer's "clear chat history" affordance (also handy
    after toggling fixture mode off, since fixture chats persist)."""
    home = store.get_home()
    if not home:
        return {"deleted": 0}
    conv_id = store.get_or_create_conversation(home["id"])
    n = store.clear_messages(conv_id)
    print(f"[messages] cleared {n} message(s) for home {home['id']}")
    return {"deleted": n}


@app.delete("/calendar/{entry_id}")
def delete_calendar_entry(entry_id: int) -> dict:
    """Remove one calendar entry. Used when the user dismisses an
    auto-captured item from the profile drawer."""
    home = store.get_home()
    if not home:
        raise HTTPException(404, "no home yet")
    ok = store.delete_calendar_entry(home["id"], entry_id)
    if not ok:
        raise HTTPException(404, f"calendar entry {entry_id} not found")
    # Calendar changed → invalidate the radar cache so the next /radar
    # call regenerates against the updated set.
    try:
        from . import radar
        radar.invalidate_cache()
    except Exception as e:  # noqa: BLE001
        print(f"[calendar] radar cache invalidation failed: {e}")
    return {"deleted": entry_id}


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
