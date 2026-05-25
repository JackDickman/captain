# Captain backend (dev)

Local dev backend for the Captain iOS app. Wraps the first-session pipeline
(`../first_session.py`) behind a FastAPI HTTP service so the iOS simulator
can call it.

## Run

From the project root:

```sh
.venv/bin/uvicorn backend.app:app --reload --port 8000
```

The server reads `OPENAI_API_KEY` and `FIRECRAWL_API_KEY` from the project
root `.env` automatically.

## Test from the command line

```sh
# Liveness
curl http://localhost:8000/health

# Full first-session run against the saved test inputs
curl -F "address=4221 Silsby Rd, University Heights, OH 44118" \
     -F "photo=@first-session-input/IMG_0754.jpg" \
     http://localhost:8000/first-session | jq
```

A successful response includes a `current_rendering_url` like
`/rendered/<job_id>/summer.png` — you can open
`http://localhost:8000<that url>` directly to see the rendered home.

## Dev fixture mode

While iterating on iOS UI, set `CAPTAIN_DEV_FIXTURE=1` before starting the
server:

```sh
CAPTAIN_DEV_FIXTURE=1 .venv/bin/uvicorn backend.app:app --reload --port 8000
```

Every `POST /first-session` will short-circuit and return canned data
(renderings + features from the validated Silsby run) in milliseconds, with
zero API spend. The response includes `"fixture": true` so you can tell.

Turn the env var off (or unset it) to hit the real pipeline.

## Notes

- Synchronous for now: the first-session POST blocks for ~30-60 seconds while
  the model generates renderings. The iOS app shows a loading state. Async
  job + polling will come later when latency matters.
- CORS is wide open for dev. Lock down before any non-localhost deploy.
- Rendered images are written to `backend/rendered/<job_id>/` and served
  statically from `/rendered/`. Each job has its own directory so concurrent
  runs don't collide.
