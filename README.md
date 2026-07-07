# CRAG Multi-Agent — Local Dev Guide

Corrective RAG (CRAG) multi-agent chat app: a LangGraph agent (`backend/multi_agent/`) behind
a FastAPI REST API (`backend/`), with a Next.js frontend (`frontend/`). See `CLAUDE.md` for
architecture, and `plan.md`/`completed.md` for the full productionization history.

This doc covers running both halves locally and manually testing the auth flow end-to-end.

## Prerequisites

- Python 3.11+ and `uv` (backend)
- Node 20.9+ and `npm` (frontend)
- Docker Desktop, for Redis (optional — everything degrades gracefully without it, just slower)
- `backend/.env` populated (copy from `backend/.env.example`) — needs `OPENAI_API_KEY`,
  `TAVILY_API_KEY`, `DATABASE_URL`, `REDIS_URL`, `JWT_SECRET_KEY`, etc.
- `frontend/.env.local` populated (copy from `frontend/.env.local.example`) —
  `NEXT_PUBLIC_API_BASE_URL=http://localhost:8000/v1`

## 1. Start Redis (optional but recommended)

```powershell
docker start crag-redis
```

If Docker Desktop isn't running, start it first. If you skip this entirely, auth still works —
every Redis-touching call (rate limiting, token revocation cache) fails open after a short
timeout instead of crashing — it's just a couple seconds slower per request.

## 2. Start the backend

```powershell
cd backend
.venv\Scripts\Activate.ps1
python run_api.py
```

**Do not run `uvicorn api.main:app` directly** — it silently uses the wrong event loop on
Windows. Always use `python run_api.py` (see that file's docstring for why).

Verify it's up in another terminal:

```powershell
curl http://localhost:8000/health
# {"status":"ok","db":true,"redis":true}
# ({"status":"degraded","db":true,"redis":false} if Redis is down - still 200, not an error;
# Postgres unreachable is the only case that returns a non-200 here, since it's a hard dependency)
```

Leave this terminal running.

## 3. Start the frontend

In a new terminal:

```powershell
cd frontend
npm run dev
```

Wait for `Ready` at `http://localhost:3000`. Leave this terminal running too.

## 4. Manually test the auth flow

Open `http://localhost:3000` in a browser and walk through:

| # | Action | Expected result |
|---|--------|------------------|
| 1 | Visit `/` while logged out | Redirects to `/login` |
| 2 | Click **Create one**, register with a real-looking email, a username (3+ chars), and a password (8+ chars) | Lands on `/chat`, shows your username |
| 3 | Hard-reload the page (`Ctrl+R`) | Still logged in — session recovers from the refresh token in `localStorage`, no re-login needed |
| 4 | Click **Log out** | Redirects to `/login`; `localStorage`'s `crag_refresh_token` is cleared |
| 5 | Log back in with the same email/password | Returns to `/chat` |
| 6 | Log out, then try logging in with the wrong password | Shows a red inline "Invalid email or password" message — not a crash, not a blank page |
| 7 | Try registering with an email/username already used | Shows a red inline "Email or username already registered" message |

If Redis is down, steps 2, 4, 5, 6, 7 each take a few extra seconds (auth calls try Redis
first, then fail open) — that's expected, not a bug.

**Tip**: open the browser's DevTools console while testing — there should be zero JS errors at
any step, and zero unhandled promise rejections even when a request fails.

## 5. Run the automated tests instead of (or in addition to) manual testing

Frontend, from `frontend/`:

```powershell
npm run test        # Vitest component tests — no backend needed, ~3s
npm run test:e2e    # Playwright e2e — auto-starts both the backend (uv run) and the dev
                     # server if they aren't already running; reuses them if they are
```

Backend, from `backend/`:

```powershell
.venv\Scripts\Activate.ps1
python -m pytest tests/ multi_agent/chains/tests/ -m "not integration"
```

Use `python -m pytest`, not the bare `pytest` command — the bare console-script doesn't add
`backend/` to `sys.path` in this setup, so first-party imports (`multi_agent.*`, `api.*`, ...)
fail to resolve during test collection.

## 6. Or: run the whole stack in Docker (one command)

Steps 1–3 above run everything with hot-reload, directly on the host. Alternatively, run the
containerized stack (backend + frontend + Redis; Postgres stays on Supabase either way):

```powershell
docker compose up --build
```

Needs, before the first run:
- `backend/.env` populated (same file as step 2 above)
- `frontend/.env.local` populated (same file as step 3 above) — note this only matters at
  *build* time, not runtime: `NEXT_PUBLIC_API_BASE_URL` gets inlined into the browser bundle by
  `next build`, so changing it after the image is built requires a rebuild, not just a restart
- Port 6379 free on the host — if you already have a standalone `crag-redis` container running
  from steps 1–3, stop it first (`docker stop crag-redis`); compose runs its own `redis` service
  on the same port

Once `docker compose ps` shows all three services `healthy`, open `http://localhost:3000` and
run the same manual test table from step 4. `docker compose down` stops everything; the ingested
Chroma vector store persists across rebuilds (bind-mounted, not baked into the image).

## Troubleshooting

- **Frontend can't reach the backend / CORS errors**: confirm `backend/.env`'s `CORS_ORIGINS`
  includes `http://localhost:3000`, and `frontend/.env.local`'s `NEXT_PUBLIC_API_BASE_URL`
  points at `http://localhost:8000/v1` (with the `/v1`).
- **Backend won't start / hangs on startup**: it fails fast (by design) if Postgres is
  unreachable — check `DATABASE_URL`/`DATABASE_URL_PSYCOPG` in `backend/.env`. Redis being down
  does *not* block startup (it's only used lazily, per-request).
- **`ModuleNotFoundError` running the backend**: the venv isn't activated, or dependencies
  aren't installed — run `uv sync --extra dev --extra prod --extra eval` from `backend/`.
- **`ModuleNotFoundError` running backend tests**: use `python -m pytest`, not bare `pytest` —
  see step 5 above.
- **Playwright e2e tests time out**: `playwright.config.ts` auto-starts both the backend and
  the frontend dev server, so this usually means one of them failed to boot within its 30s
  window (e.g. `backend/.env` missing/invalid) rather than something not being started manually
  — check the Playwright output for which of the two `webServer` entries failed.
