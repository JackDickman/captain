# Captain

An AI-powered iOS app that helps a homeowner take care of their home. The
home — not a task list — is the main character. See `captain-prd-v1.md` for
the full product brief.

This repo is a personal pet project.

## Layout

- `captain-prd-v1.md` — full product requirements document (v1)
- `render_prototype.py` — Peanuts-style home rendering + palette extraction
- `first_session.py` — first-session pipeline (photo + address → features + rendering)
- `backend/` — FastAPI dev backend
  - `app.py` — endpoints: `/first-session`, `/chat`, `/messages`, `/weather`, `/debug/state`
  - `chat.py` — chat handler + background memory-update orchestrator
  - `profiles.py` — markdown-document memory layer (`home.md` + `user.md`)
  - `store.py` — SQLite persistence (calendar, conversations, messages)
  - `weather.py` — NWS forecast fetcher
- `ios/` — SwiftUI app
  - `project.yml` — XcodeGen spec (source of truth; xcodeproj is regenerated)
  - `Captain/` — Swift sources (Models, Views, Networking, Design, etc.)
- `design-references/` — visual inspiration

## Running locally

### Backend

```sh
# One-time setup
python3 -m venv .venv
./.venv/bin/pip install fastapi 'uvicorn[standard]' python-multipart \
    openai pillow colorthief python-dotenv requests

# Copy .env.example to .env and fill in real API keys
cp .env.example .env
$EDITOR .env

# Run (text-only, no real LLM calls — for UI iteration)
CAPTAIN_DEV_FIXTURE=1 ./.venv/bin/uvicorn backend.app:app --port 8000

# Or run for real (incurs API spend)
./.venv/bin/uvicorn backend.app:app --port 8000
```

### iOS

Requires Xcode (free, Mac App Store) and `xcodegen` (install via `swift build` from
https://github.com/yonaskolb/XcodeGen).

```sh
cd ios
xcodegen generate
open Captain.xcodeproj
# Cmd-R in Xcode, or:
xcodebuild -project Captain.xcodeproj -scheme Captain \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## Privacy notes

- `.env` (API keys), `backend/captain.db` (chat + home metadata),
  `backend/profiles/` (home/owner narrative markdown), `backend/rendered/`
  and `backend/chat-photos/` (user photos), and the `prototype-*` /
  `first-session-*` fixture dirs all hold PII and are git-ignored.
- A `.env.example` lives in the repo to show what variables are needed
  without exposing real secrets.
