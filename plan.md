# Productionization Plan — LangGraph CRAG Multi-Agent App

## Context

The current app is a pure-CLI Corrective RAG (CRAG) multi-agent pipeline built with LangGraph. It has:
- **No HTTP API** — entry point is `main.py` (CLI only)
- **In-memory checkpointer** (`MemorySaver`) — all state lost on restart
- **No users, no auth, no sessions**
- **No persistence** (Chroma vector store is persisted; conversation state is not)

This plan transforms it into a production REST API with:
- JWT authentication
- Per-user conversation sessions
- PostgreSQL for durable conversation history + LangGraph checkpoints
- Redis for fast last-5-session listing per user
- Langfuse for agent observability (request tracing) + RAGAS-based evaluation testing
- OpenTelemetry + Grafana Cloud for general app-level tracing, structured logging, and auth/audit trail (separate from Langfuse's LLM-specific tracing)
- A Next.js frontend (chat UI, auth, session management) to make this an actual fullstack app rather than an API with no client

---

## New Project Structure

```
Multi-Agent/
├── .github/
│   └── workflows/
│       ├── ci.yml                 # NEW (Phase 17): lint + fast test suite on push/PR
│       ├── cd.yml                 # NEW (Phase 18): dispatcher — workflow_dispatch only for now (dev-phase decision, see plan.md's design note), a target choice (lambda/fargate/both, +eks once Phase 21 is built) fans out to the reusable workflows below; automatic workflow_run-after-ci.yml trigger deferred, see cd-dispatcher-steps.md
│       ├── cd-lambda.yml           # NEW (Phase 18): workflow_call — own OIDC deploy role, own Terraform state, builds/pushes/deploys the Lambda image
│       ├── cd-ecs.yml              # NEW (Phase 19): workflow_call — own (separate) OIDC deploy role, own Terraform state, builds/pushes/deploys the Fargate image
│       └── cd-eks.yml              # NEW (Phase 21, not yet built): commits an updated image tag to gitops/multi-agent/values.yaml — ArgoCD in-cluster does the actual deploy, so this needs no deploy-scoped IAM role at all
├── config.py                       # NEW (Phase 6): pydantic-settings Settings class, get_settings() — single source of truth for all env vars
├── api/
│   ├── __init__.py
│   ├── main.py                    # FastAPI app factory + lifespan context manager
│   ├── error_handlers.py          # NEW (Phase 6): global exception handlers — consistent JSON error envelope, logs traceback with trace_id
│   ├── dependencies.py            # Shared deps: db session, redis, graph, current user
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── auth.py                # POST /auth/register, /auth/login, /auth/refresh, /auth/logout; GET /auth/me
│   │   ├── sessions.py            # GET/POST/PATCH/DELETE /sessions and /sessions/{id}
│   │   └── chat.py                # POST /sessions/{id}/messages; GET /sessions/{id}/stream (SSE)
│   └── schemas/
│       ├── __init__.py
│       ├── auth.py                # RegisterRequest, LoginRequest, TokenResponse, UserResponse, AuthResponse
│       ├── session.py             # SessionCreate, SessionPatch, SessionResponse
│       └── chat.py                # ChatRequest, MessageResponse, ChatResponse, MessagesListResponse
│
├── db/
│   ├── __init__.py
│   ├── base.py                    # async engine, async_sessionmaker, declarative Base
│   ├── models/
│   │   ├── __init__.py
│   │   ├── user.py                # User ORM model
│   │   ├── session.py             # ChatSession ORM model
│   │   ├── message.py             # Message ORM model
│   │   └── refresh_token.py       # RefreshToken ORM model
│   ├── crud/                      # NEW: thin query functions shared by routers (added Phase 6, not Phase 2)
│   │   ├── __init__.py
│   │   ├── users.py                # get_user_by_email, get_user_by_id, create_user
│   │   ├── sessions.py              # get_session (ownership-checked), list_sessions, create_session, delete_session
│   │   └── messages.py              # create_message, list_messages_for_session
│   └── migrations/
│       ├── env.py                 # Alembic env (async-aware)
│       ├── script.py.mako
│       └── versions/
│           └── 0001_initial_schema.py
│
├── cache/
│   ├── __init__.py
│   ├── client.py                  # Redis async client dependency
│   └── sessions.py                # get/set/invalidate for session ZSET, HASH, LIST, revocation STRING
│
├── auth/
│   ├── __init__.py
│   ├── password.py                # bcrypt hash/verify
│   ├── jwt.py                     # create_access_token, create_refresh_token, decode_token
│   └── dependencies.py            # get_current_user FastAPI dependency
│
├── eval/
│   ├── __init__.py
│   ├── dataset.py                 # 25 static QA pairs + push-to-Langfuse function
│   ├── metrics.py                 # RAGAS metric objects + threshold dict
│   ├── langfuse_eval.py           # create_or_get_dataset, run_target, score_with_ragas
│   └── run_eval.py                # CLI: python -m eval.run_eval [--experiment-name foo]
│
├── observability/
│   ├── __init__.py
│   ├── langfuse_client.py         # get_langfuse_handler() factory — shared by main.py, api/routers/chat.py, eval/
│   ├── otel_client.py             # NEW (Phase 14): setup_otel(app, db_engine) — TracerProvider/LoggerProvider + OTLP exporters, auto-instruments FastAPI/SQLAlchemy/Redis
│   └── logging_config.py          # NEW (Phase 14): structlog config; injects trace_id/span_id from the active OTel span into every log line
│
├── chains/                        # UNCHANGED
├── nodes/                         # UNCHANGED
├── consts.py                      # UNCHANGED
├── state.py                       # UNCHANGED
├── ingestion.py                   # UNCHANGED
├── graph.py                       # MODIFIED: add create_app(checkpointer) factory
├── main.py                        # MODIFIED: use create_app(MemorySaver()) for CLI
├── alembic.ini
├── pyproject.toml
├── requirements.txt               # EXTENDED
├── .env                           # EXTENDED
├── .env.example                   # UPDATED
├── Dockerfile                      # NEW (Phase 10): python:3.12-slim, uvicorn CMD — backend image, build context is this directory (backend/) itself, not the repo root; gains the Lambda Web Adapter layer in Phase 15
├── .dockerignore                    # NEW (Phase 10): .venv, .chroma, __pycache__, .env (paths relative to backend/, matching the Dockerfile's context)
│
│   (everything below this line is at the true repo root, one level up from this backend/ tree — see CLAUDE.md's note that this whole tree predates the backend/ restructure)
├── docker-compose.yml               # NEW (Phase 10): backend + frontend + redis services (Postgres stays Supabase, not containerized)
├── frontend/                       # NEW (Phases 7–8): separate Next.js app (own package.json) — see Phase 7 (auth) and Phase 8 (chat UI) for full tree; gets its own Dockerfile in Phase 10, static-exported to S3 in Phase 15
├── infra/                           # NEW (Phase 15–16): infra/bootstrap/ (shared S3+DynamoDB remote state, both roots below point at it); infra/lambda-gate/ (Phase 15 — providers, Lambda/API Gateway/CloudFront, own ECR/SSM); infra/fargate/ (Phase 16 — ECS/ALB/CloudFront, deliberately independent of infra/lambda-gate/ at every layer, own ECR/SSM/S3/scripts too — see completed.md's Phase 16 entry for why this isn't the shared-resource design originally sketched below); EKS cluster/node-group/IRSA resources added in Phase 20, likely infra/eks/ following the same per-target-root pattern
└── gitops/                          # NEW (Phase 20–21): gitops/multi-agent/ Helm chart (backend+frontend Deployments/Services, Ingress, HPA) for the EKS target; Phase 21's ArgoCD Application syncs this same path
```

---

## PostgreSQL Schema

### Application Tables

> Run these in **Supabase Dashboard → SQL Editor** following `setup/db_setup.md`. Do not use Alembic for the initial schema — run it manually so triggers and indexes are applied exactly as written.

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- USERS
CREATE TABLE users (
    id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(255) UNIQUE NOT NULL,
    username        VARCHAR(100) UNIQUE NOT NULL,
    hashed_password VARCHAR(255) NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_users_email ON users(email);

-- Auto-update updated_at on any UPDATE
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- CHAT SESSIONS
-- id is used directly as LangGraph thread_id (cast to text)
CREATE TABLE chat_sessions (
    id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title           VARCHAR(500),
    is_archived     BOOLEAN      NOT NULL DEFAULT FALSE,
    last_message_at TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_chat_sessions_user_id       ON chat_sessions(user_id);
CREATE INDEX idx_chat_sessions_user_last_msg ON chat_sessions(user_id, last_message_at DESC NULLS LAST);
CREATE INDEX idx_chat_sessions_active        ON chat_sessions(user_id, is_archived, last_message_at DESC NULLS LAST);

CREATE TRIGGER chat_sessions_set_updated_at
    BEFORE UPDATE ON chat_sessions FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- MESSAGES
CREATE TABLE messages (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID         NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
    role        VARCHAR(20)  NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content     TEXT         NOT NULL,
    metadata    JSONB,          -- stores: web_search flag, routing decision, node path
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_messages_session_id      ON messages(session_id);
CREATE INDEX idx_messages_session_created ON messages(session_id, created_at ASC);

-- REFRESH TOKENS (for revocation)
CREATE TABLE refresh_tokens (
    id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash  VARCHAR(64)  NOT NULL,   -- SHA-256 hex of the raw JWT string
    issued_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ  NOT NULL,
    revoked     BOOLEAN      NOT NULL DEFAULT FALSE,
    revoked_at  TIMESTAMPTZ
);
CREATE INDEX idx_refresh_tokens_user_id    ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);
CREATE INDEX idx_refresh_tokens_active     ON refresh_tokens(user_id, revoked, expires_at);
```

### LangGraph Checkpoint Tables
Created automatically by `AsyncPostgresSaver.setup()` — **do not create manually**.

```sql
-- For reference only (managed by langgraph-checkpoint-postgres):
checkpoints          (thread_id, checkpoint_ns, checkpoint_id, ...)
checkpoint_blobs     (thread_id, checkpoint_ns, channel, version, blob, ...)
checkpoint_writes    (thread_id, checkpoint_ns, checkpoint_id, task_id, idx, ...)
```

**Alignment rule**: `chat_sessions.id::TEXT` = LangGraph `thread_id`. Ownership is enforced at the session layer before any graph call.

---

## Redis Data Model

> For provisioning steps, key schema verification, and Python client setup, see `setup/redis_setup.md`.

### A — User Session Listing (Sorted Set)
```
Key:     user:{user_id}:sessions
Type:    ZSET
Score:   UNIX timestamp of last_message_at
Member:  session_id (UUID string)
Max:     5 members (enforced after every ZADD with ZREMRANGEBYRANK 0 -6)
TTL:     86400 s (refreshed on read/write)

Write:
  ZADD user:{user_id}:sessions {now_ts} {session_id}
  ZREMRANGEBYRANK user:{user_id}:sessions 0 -6
  EXPIRE user:{user_id}:sessions 86400

Read (GET /sessions):
  ZREVRANGE user:{user_id}:sessions 0 4 WITHSCORES
  → on cache miss, query DB LIMIT 5 ORDER BY last_message_at DESC and repopulate
```

### B — Session Metadata Cache (Hash)
```
Key:     session:{session_id}:meta
Type:    HASH
Fields:  title, user_id, created_at, last_message_at, is_archived ("0"/"1")
TTL:     3600 s (refreshed on read)

Write:   HSET session:{session_id}:meta field value ...
         EXPIRE session:{session_id}:meta 3600
Read:    HGETALL session:{session_id}:meta
```

### C — Recent Messages per Session (List)
```
Key:     session:{session_id}:messages
Type:    LIST (append with RPUSH; newest at tail)
Value:   JSON: {"id":"...", "role":"user|assistant", "content":"...", "created_at":"..."}
Max:     20 entries (LTRIM -20 -1 after each RPUSH)
TTL:     1800 s (refreshed on access)

Write:
  RPUSH session:{session_id}:messages {json_message}
  LTRIM session:{session_id}:messages -20 -1
  EXPIRE session:{session_id}:messages 1800

Read:    LRANGE session:{session_id}:messages 0 -1
         → on cache miss, load from DB LIMIT 20 ORDER BY created_at DESC
```

### D — JWT Revocation (String)
```
Key:     revoked_token:{jti}
Type:    STRING
Value:   "1"
TTL:     Remaining lifetime of the token at logout time

On logout:
  SET revoked_token:{access_jti} 1 EX {exp - now}  NX

On every authenticated request:
  EXISTS revoked_token:{jti}  → 401 if found
```

### Redis Config
- `maxmemory-policy allkeys-lru`
- Recommended cap: 512 MB
- All keys have explicit TTLs; LRU eviction naturally expires stale session caches first.

### Fallback on Redis unavailability
`cache/sessions.py` (Phase 4) does **not** decide fallback behavior itself — it's a thin, raw-Redis-ops layer with no knowledge of whether a DB fallback exists for a given call. **Retrofit applied (2026-07-03)**: every function now catches `redis.exceptions.RedisError` and re-raises `cache.exceptions.CacheUnavailableError` — a normalized, library-agnostic exception, not a raw redis-py error escaping the module. The fallback *decision* still belongs one layer up, in the **Phase 6 routers** (`api/routers/sessions.py`, `api/routers/chat.py`) that call it: catch `CacheUnavailableError`, log a warning (trace-correlated, via Phase 14's logger), and fall through to the same DB query already used for a cache *miss*. This means a Redis outage degrades to DB-only reads instead of 500s.

---

## API Endpoints

All routers are mounted under an `/v1` prefix (`app.include_router(auth_router, prefix="/v1")`, etc.) — cheap to do now, painful to retrofit once clients exist. `/health` stays unversioned since infra/load-balancer checks shouldn't need to track API versions.

```
POST   /v1/auth/register
POST   /v1/auth/login
POST   /v1/auth/refresh
POST   /v1/auth/logout                    (auth required)
GET    /v1/auth/me                        (auth required)

GET    /v1/sessions                       → last 5 sessions (Redis → DB fallback)
POST   /v1/sessions                       → create new session
GET    /v1/sessions/{session_id}
PATCH  /v1/sessions/{session_id}          → rename title
DELETE /v1/sessions/{session_id}          → soft-delete (is_archived=True)

GET    /v1/sessions/{session_id}/messages → paginated history (DB)
POST   /v1/sessions/{session_id}/messages → synchronous invoke
GET    /v1/sessions/{session_id}/stream   → SSE token stream

GET    /health                            → liveness/readiness (public, unversioned)
```

### Key Schema Types
```python
# Auth
RegisterRequest: email, username, password
LoginRequest:    email, password
TokenResponse:   access_token, refresh_token, token_type, expires_in
AuthResponse:    tokens: TokenResponse, user: UserResponse

# Sessions
SessionCreate:   title (optional)
SessionPatch:    title
SessionResponse: id, user_id, title, is_archived, last_message_at, created_at, updated_at

# Chat
ChatRequest:     question (1–4000 chars)
MessageResponse: id, session_id, role, content, metadata, created_at
ChatResponse:    question_message, answer_message

# SSE events (application/json per event):
{"type": "token",  "token": "..."}
{"type": "done",   "message_id": "..."}
{"type": "error",  "detail": "..."}
```

---

## Auth Flow

### JWT Structure
- **Access token**: HS256, 15-minute TTL. Claims: `sub` (user_id), `email`, `username`, `jti`, `type="access"`, `iat`, `exp`
- **Refresh token**: HS256, 7-day TTL. Claims: `sub`, `jti`, `type="refresh"`, `iat`, `exp`

### Request Validation (every protected endpoint)
1. Extract `Bearer` token from `Authorization` header
2. Decode + verify signature and expiry
3. Confirm `type == "access"`
4. Check `EXISTS revoked_token:{jti}` in Redis → 401 if found
5. Load user from DB → 401 if missing or `is_active=False`

### Refresh
- Decode refresh token → verify `type == "refresh"` + not expired
- SHA-256 hash it → look up in `refresh_tokens` table (must be non-revoked, non-expired)
- Mark old row revoked; add `jti` to Redis revocation
- Issue new access + refresh token pair
- Return `TokenResponse`

### Logout
- Add access token `jti` to Redis revocation (`EX = remaining lifetime`)
- If refresh token provided: mark DB row revoked + add `jti` to Redis

---

## Configuration, Error Handling & Auth Rate Limiting

### `config.py` — centralized settings
**Decision (2026-07-03):** every module currently reads env vars directly via `os.getenv` (`auth/jwt.py`, `db/base.py`, `cache/client.py`, etc. — Phases 1–4, already built). That's fine standalone, but `plan.md`'s own `api/main.py` lifespan snippet (below) already assumes a `settings` object exists, and scattering `os.getenv` calls means a missing/malformed env var fails deep inside a request instead of at startup. Fixed going forward, not retrofitted onto already-completed Phase 1–4 modules (not worth the churn):
```python
# config.py
from pydantic_settings import BaseSettings
from functools import lru_cache

class Settings(BaseSettings):
    database_url: str
    database_url_psycopg: str
    redis_url: str
    jwt_secret_key: str
    # ... all other env vars from "New Environment Variables" below
    model_config = {"env_file": ".env"}

@lru_cache
def get_settings() -> Settings:
    return Settings()  # raises at import/startup if anything required is missing
```
All **new** code from Phase 6 onward (`api/`, and anywhere those routers touch config) uses `get_settings()` instead of `os.getenv`. Existing Phase 1–4 modules are left as-is.

### `api/error_handlers.py` — global exception handler
Without this, an uncaught exception in a router leaks a raw traceback to the client. Register two handlers in `api/main.py`:
```python
@app.exception_handler(HTTPException)
async def http_exception_handler(request, exc):
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})

@app.exception_handler(Exception)
async def unhandled_exception_handler(request, exc):
    logger.exception("unhandled_exception", request_id=request.state.request_id)  # full traceback, trace-correlated via Phase 14
    return JSONResponse(status_code=500, content={"detail": "internal server error"})
```
Every error response — expected (`HTTPException`) or not — returns the same `{"detail": ...}` shape; only the unhandled case gets a full server-side traceback log.

### Auth endpoint rate limiting (separate from Phase 12's per-user limiter)
Phase 12's rate limiter is keyed by authenticated user ID — useless for `/v1/auth/login` and `/v1/auth/register`, which run *before* any identity exists and are the actual brute-force/credential-stuffing target. Same Redis `INCR`-bucket pattern, different key: `ratelimit:auth:{client_ip}`, stricter window (e.g. 10 req/min vs. the general 60 req/min), applied only to those two routes.

---

## Resilience & Crash Prevention (Backend + Frontend)

**Principle (2026-07-03):** the app must never crash outright, on either side — it should degrade gracefully (a clear error, a retry, a fallback answer) instead. This is stronger than the Phase 6 global exception handler alone. That handler already stops one bad *request* from crashing the FastAPI *process* (Starlette's exception middleware catches per-request errors regardless of whether this plan does anything extra — confirmed, not assumed). What it does **not** cover, and what nothing in this plan covered until now:

1. **LangGraph node-level failures.** A code audit of the already-built app found **zero exception handling anywhere** in `nodes/*.py`, `chains/*.py`, `graph.py`, or `main.py` — an OpenAI timeout, a Tavily outage, or a Chroma retrieval error currently crashes the whole CLI run today, and would crash the whole `app.stream()` call inside a future request (the Phase 6 handler would catch it and return a 500, but the user gets no useful answer, and the specific cause is buried in an unstructured traceback). **Addressed in Phase 5**, since that's where `graph.py` is already being touched: wrap each node's external call (LLM invoke, Tavily invoke, Chroma retrieve) in try/except with a bounded retry (`tenacity`, 2 attempts, exponential backoff) for transient errors, and a graceful degrade when retries are exhausted (e.g. `web_search` returns an empty result set so `generate` still runs on whatever documents exist, rather than raising) — no external-dependency exception should ever reach `main.py` or the API layer unhandled.
2. **`auth/dependencies.py`'s revocation check is unguarded** (Phase 3, already shipped and tested) — `is_token_revoked`'s Redis call has no try/except, so a Redis outage during authentication currently raises a raw, uncaught exception instead of a clean response. **Decision: fail open, not closed** — if Redis is unreachable, log a warning (trace-correlated, Phase 14) and allow the request through rather than rejecting it. Rationale: the JWT signature + expiry check is the primary security control; the revocation check is defense-in-depth for the narrower case of an explicitly logged-out-but-not-yet-expired token. Rejecting every authenticated request in the app because of a transient Redis blip is a worse outcome than a brief window where revocation enforcement is best-effort. This is a small, contained fix to already-completed code — see `completed.md` for whether/when it's applied.
3. **Frontend crash containment is incomplete by construction.** Next.js `error.tsx` boundaries only catch errors thrown during React's **render phase** — they do *not* catch errors in event handlers (`onClick`) or async code (`fetch().then()`), which is most of what a chat app actually does. Without explicit handling, a malformed API response or a dropped SSE connection produces a silent failure or an unhandled promise rejection, not a graceful stop. **Addressed in Phase 7/8**: a root `app/error.tsx` boundary so a render-phase crash never blanks the *whole* app (only the affected subtree), plus explicit try/catch in `lib/api.ts` and `lib/sse.ts` around every network/parse operation, surfaced as UI state — never an unhandled rejection.

### Backend pattern
```python
# nodes/web_search.py (illustrative)
from tenacity import retry, stop_after_attempt, wait_exponential

@retry(stop=stop_after_attempt(2), wait=wait_exponential(min=1, max=4), reraise=False)
def _call_tavily(question: str):
    return web_search_tool.invoke({"query": question})

def web_search(state: GraphState) -> GraphState:
    try:
        results = _call_tavily(state["question"])
    except Exception:
        logger.warning("web_search_failed", question=state["question"])  # trace-correlated, Phase 14
        results = []  # graceful degrade — generate() still runs on whatever documents already exist
    ...
```
Same pattern for `retrieve.py` (Chroma) and the LLM calls in `generate.py`/`chains/*.py`. `main.py`'s `app.stream(...)` call is additionally wrapped in a top-level try/except as defense-in-depth, printing a clear message instead of a raw traceback if something still gets through.

`api/dependencies.py` (Phase 6) also translates known dependency failures into a specific response instead of the generic 500: a DB connection error or Redis timeout from `get_db`/`get_redis` becomes a `503 Service Unavailable` with a clear `detail`, not an opaque `HTTPException` from deep inside SQLAlchemy/redis-py. Startup itself is **fail-fast, not suppressed** — if Postgres/Redis is unreachable when `api/main.py`'s lifespan runs, uvicorn should fail to boot with a clear error rather than starting in a half-working state (this is FastAPI/Starlette's existing lifespan behavior — nothing to build, just don't swallow it with a broad except).

### Frontend pattern
```tsx
// app/error.tsx — root boundary, Next.js App Router convention
'use client';
export default function GlobalError({ error, reset }: { error: Error; reset: () => void }) {
  return <ErrorFallback message="Something went wrong." onRetry={reset} />;
}
```
```ts
// lib/api.ts — every call site, not just the 401-refresh path
try {
  const res = await fetch(url, opts);
  if (!res.ok) throw new ApiError(res.status, await res.text());
  return await res.json();
} catch (err) {
  // network failure, timeout, or non-2xx — surfaced as UI state, never an unhandled rejection
  throw toUserFacingError(err);
}
```
`lib/sse.ts` applies the same rule to a dropped mid-stream connection or a malformed frame: caught, surfaced to the chat UI as a visible `{"type": "error"}` state (already part of the SSE event contract in [API Endpoints](#api-endpoints)), never left as an unhandled rejection.

### Testing convention (extends the per-phase testing convention above)
Every phase's testing step must include at least one **failure-path** test, not just happy-path — simulate the dependency that phase introduces being unavailable or erroring, and assert the app degrades gracefully instead of crashing or hanging. This is folded into the relevant phases' testing steps below (Phase 3's retrofit test, Phase 5's node-failure/retry tests, Phase 6's dependency-down → 503 test, Phase 7/8's network-failure and dropped-SSE-connection tests).

---

## LangGraph Integration

### Refactor `graph.py`
Remove module-level `app = workflow.compile(checkpointer=memory)` and replace with:
```python
def create_app(checkpointer):
    """Compile and return the CRAG graph with the given checkpointer."""
    return workflow.compile(checkpointer=checkpointer)
```
Also remove `app.get_graph().draw_mermaid_png(...)` — crashes in headless API environments.

### Update `main.py` (CLI stays working)
```python
from langgraph.checkpoint.memory import MemorySaver
from graph import create_app
app = create_app(MemorySaver())
```

### `AsyncPostgresSaver` lifecycle in `api/main.py`
**Corrected during Phase 6 build** (verified against the installed `langgraph-checkpoint-postgres`, not assumed): `AsyncPostgresSaver` is **not** an async context manager when constructed directly - `async with AsyncPostgresSaver(pool) as saver:` raises `TypeError`. That pattern belongs to `AsyncPostgresSaver.from_conn_string()`'s `@asynccontextmanager` factory, not the plain constructor. Also, the pool needs `kwargs={"autocommit": True}` - `saver.setup()`'s migrations use `CREATE INDEX CONCURRENTLY`, which Postgres refuses to run inside a transaction block. And `app.state.db_engine` reuses `db/base.py`'s existing engine rather than opening a second pool against the same database (the snippet below originally created its own via `create_async_engine(...)`, which would sit unused - everything already queries through `db/base.py`'s `async_session_factory`).
```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pg_pool = AsyncConnectionPool(
        conninfo=settings.DATABASE_URL_PSYCOPG, min_size=2, max_size=10, open=False,
        kwargs={"autocommit": True},
    )
    await app.state.pg_pool.open()
    saver = AsyncPostgresSaver(app.state.pg_pool)
    await saver.setup()   # creates checkpoint tables if not exist (idempotent)
    app.state.db_engine = db_engine  # from db.base import engine as db_engine
    app.state.redis = aioredis.from_url(settings.REDIS_URL, decode_responses=True)
    yield
    await app.state.pg_pool.close()
    await app.state.redis.aclose()
```

`get_graph` dependency creates `AsyncPostgresSaver(request.app.state.pg_pool)` per request (cheap — pool is the singleton, plain construction not `async with`).

---

## Observability (Langfuse)

**Decision (2026-07-02):** use **Langfuse Cloud** for agent observability, **replacing** the LangSmith tracing this plan originally specified. One dashboard, one set of API keys, no double-instrumentation. Langfuse traces every node/chain/LLM call in the CRAG graph (routing decision, retrieval, grading, generation, hallucination/answer checks) with latency, token cost, and full input/output per step — and doubles as the dataset/scoring backend for Phase 9's RAGAS eval suite, so evals and production traces live in the same place.

Implementation note: this should be wired in as soon as `create_app()` exists (Phase 5) so every subsequent phase's manual testing is already traced — it's numbered Phase 13 below purely for doc/folder consistency with `completed.md`/`tests/phaseN_*/`/`test_reports/phaseN_*/`, not because the wiring waits that long.

### `observability/langfuse_client.py`
```python
from langfuse.langchain import CallbackHandler

def get_langfuse_handler() -> CallbackHandler:
    return CallbackHandler()  # reads LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY / LANGFUSE_HOST from env
```

### Wiring into the graph
Every place that calls `.invoke()` / `.stream()` on the compiled graph passes the handler via `config`:
```python
from observability.langfuse_client import get_langfuse_handler

langfuse_handler = get_langfuse_handler()
app.stream(inputs, config={"configurable": {"thread_id": thread_id}, "callbacks": [langfuse_handler]})
```
- `main.py` (CLI) — pass it in the existing `app.stream(...)` call.
- `api/routers/chat.py` (Phase 6) — pass it in both the sync-invoke and SSE-stream paths; also set `trace_name`, `user_id`, `session_id` via `langfuse.propagate_attributes(...)` so traces are filterable by user/session in the dashboard.
- `eval/langfuse_eval.py` (Phase 9) — use the per-dataset-item handler from `item.get_langchain_handler(run_name=...)` instead (auto-links the trace to the dataset item for scoring).

### Inline the LangChain Hub prompt (`chains/generation.py`)
`hub.pull("rlm/rag-prompt")` makes a live network call at import time. Replace with:
```python
from langchain_core.prompts import ChatPromptTemplate
prompt = ChatPromptTemplate.from_messages([
    ("human", """You are an assistant for question-answering tasks.
Use the following pieces of retrieved context to answer the question.
If you don't know the answer, say that you don't know. Use three sentences maximum.

Question: {question}
Context: {context}
Answer:""")
])
```

---

## Observability (OpenTelemetry + Grafana Cloud)

**Decision (2026-07-03):** add a second, deliberately separate observability path for everything Langfuse doesn't cover — HTTP request traces, DB query spans, Redis command spans, and an auth/audit log trail. Langfuse stays scoped to LLM/chain-level detail (routing decisions, retrieval, grading, generation, hallucination/answer checks, RAGAS scoring); it is **not** replaced or double-instrumented. The two are stitched together with one correlation ID rather than merged into one system, so each tool is used for what it's actually good at.

**Backend:** Grafana Cloud **free tier** (hosted — Tempo for traces, Loki for logs). 50GB/month each for traces and logs, 14-day retention, no credit card — far more than a single-developer learning workload will use, and it avoids running a local Grafana/Tempo/Loki/Collector stack (4+ containers) just to view data. Ships directly via OTLP; no self-hosted collector needed for this scope.

**Correlation with Langfuse:** the `X-Request-ID` generated by the Phase 6 request-ID middleware is attached both as an OTel span attribute and as Langfuse trace metadata (`trace_name`/`metadata`), so a single request can be looked up in either dashboard.

**Scope (deliberately not heavier than this):**
- FastAPI HTTP layer — auto-instrumented request/response spans (latency, status code)
- SQLAlchemy/Postgres — query-level spans nested under the request span
- Redis — span per command (cache hit/miss timing visible inside a request trace)
- Auth/audit events (login, logout, refresh, revoked-token-rejected) — structured logs, not spans; this is the audit trail half of the goal
- LangGraph node execution is explicitly **out of scope** here — that's Langfuse's job (see above)

### `observability/otel_client.py`
```python
def setup_otel(app: FastAPI, db_engine) -> None:
    """Call once at API startup (api/main.py lifespan), after the DB engine exists."""
    # TracerProvider + BatchSpanProcessor(OTLPSpanExporter) — reads OTEL_EXPORTER_OTLP_* from env
    # LoggerProvider + BatchLogRecordProcessor(OTLPLogExporter) — attaches a LoggingHandler to the root logger
    # FastAPIInstrumentor.instrument_app(app)
    # SQLAlchemyInstrumentor().instrument(engine=db_engine)
    # RedisInstrumentor().instrument()
```

### `observability/logging_config.py`
structlog pipeline ending in the stdlib logging bridge (so `otel_client`'s `LoggingHandler` picks it up), with a processor that reads `opentelemetry.trace.get_current_span().get_span_context()` and injects `trace_id`/`span_id` into every log line — this is what makes a Loki log line clickable straight to its Tempo trace in Grafana's Explore view.

### Auth/audit logging
`auth/dependencies.py` and `api/routers/auth.py` emit structured log events (`logger.info("auth.login", user_id=..., email=...)`, and similarly for logout/refresh/revoked-token-rejected) using the same structlog logger — trace-correlated and shipped to Loki alongside everything else, queryable as an audit trail.

---

## Evaluation Testing

> **Provider note:** this section uses **Langfuse**, not LangSmith — see [Observability](#observability-langfuse) below for why. `LANGCHAIN_TRACING_V2`/`LANGCHAIN_API_KEY`/`LANGSMITH_*` are not used anywhere in this plan.

### Dataset (`eval/dataset.py`)
25 static QA pairs drawn from the three ingested Lilian Weng blog posts:
- 20 questions routed to `vectorstore` (agents, prompt engineering, adversarial attacks) — with `ground_truth`
- 5 questions that must route to `websearch` (topics not in corpus) — `ground_truth=None`

### RAGAS Metrics (`eval/metrics.py`)
| Metric | Measures | Needs ground_truth |
|---|---|---|
| `faithfulness` | Answer grounded in retrieved contexts (hallucination detection) | No |
| `answer_relevancy` | Answer addresses the question | No |
| `context_recall` | Retrieved contexts contain the info needed | Yes |
| `context_precision` | Relevant contexts ranked first | Yes |

Default thresholds:
```python
THRESHOLDS = {
    "faithfulness": 0.75,
    "answer_relevancy": 0.75,
    "context_recall": 0.65,
    "context_precision": 0.65,
}
```

### Langfuse Wiring (`eval/langfuse_eval.py`)
- `create_or_get_dataset(name)` — `langfuse.create_dataset(name=...)` + `create_dataset_item(...)` per sample (idempotent; Langfuse no-ops on duplicate item content)
- `run_target(item)` — for each `dataset.items`, gets a trace-linking callback via `item.get_langchain_handler(run_name=...)`, invokes `create_app(MemorySaver())` with a fresh `thread_id` and `config={"callbacks": [handler]}`; returns `{answer, contexts, trace_id}`
- `score_and_push(trace_id, scores: dict[str, float])` — computes the 4 RAGAS metrics locally (same `ragas` calls as before, no LangSmith-specific `ragas.integrations` needed) then attaches each as a score on the linked trace via `generation.score(name=..., value=...)` (or `langfuse.create_score(name=..., value=..., trace_id=...)`)

### Eval Runner (`eval/run_eval.py`)
```bash
python -m eval.run_eval
python -m eval.run_eval --experiment-name prod-baseline-v1
```
- Runs all 25 samples through `eval/langfuse_eval.py`, scoring each via RAGAS and pushing scores back to the linked Langfuse trace
- Prints per-metric markdown table with Pass/Fail vs thresholds
- Exits with code `1` if any metric falls below threshold (enables CI gating)
- Prints the Langfuse dataset run URL (`https://cloud.langfuse.com/project/<id>/datasets/<dataset_id>`)

---

## New Environment Variables

```bash
# PostgreSQL — Supabase (two formats required by different libraries)
# Get these from: Supabase Dashboard → Settings → Database → Connection string
DATABASE_URL=postgresql+psycopg://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres
DATABASE_URL_PSYCOPG=host=aws-0-<region>.pooler.supabase.com dbname=postgres user=postgres.<project-ref> password=<password> port=5432
DATABASE_POOL_MIN_SIZE=2
DATABASE_POOL_MAX_SIZE=10

# Redis
REDIS_URL=redis://localhost:6379/0

# JWT — generate with: python -c "import secrets; print(secrets.token_hex(32))"
JWT_SECRET_KEY=<64-char hex>
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=15
REFRESH_TOKEN_EXPIRE_DAYS=7

# App
APP_ENV=production
APP_HOST=0.0.0.0
APP_PORT=8000
CORS_ORIGINS=http://localhost:3000

# Rate limiting — auth endpoints (separate, stricter bucket from Phase 12's general per-user limiter)
RATE_LIMIT_AUTH_PER_MINUTE=10

# Rate limiting — general, per authenticated user (Phase 12), applied to sessions/chat routes
RATE_LIMIT_GENERAL_PER_MINUTE=60

# Frontend (frontend/.env.local, not the backend .env)
NEXT_PUBLIC_API_BASE_URL=http://localhost:8000/v1

# Existing (unchanged)
OPENAI_API_KEY=sk-...
TAVILY_API_KEY=tvly-...

# Langfuse — Cloud (get keys from: https://cloud.langfuse.com → project settings)
# Other regions: US https://us.cloud.langfuse.com, Japan https://jp.cloud.langfuse.com, HIPAA https://hipaa.cloud.langfuse.com
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
LANGFUSE_HOST=https://cloud.langfuse.com

# Evaluation
LANGFUSE_EVAL_DATASET_NAME=crag-eval-v1
EVAL_FAITHFULNESS_THRESHOLD=0.75
EVAL_ANSWER_RELEVANCY_THRESHOLD=0.75
EVAL_CONTEXT_RECALL_THRESHOLD=0.65
EVAL_CONTEXT_PRECISION_THRESHOLD=0.65

# OpenTelemetry — Grafana Cloud (get from: Grafana Cloud → My Account → <stack> → Details → OTLP endpoint)
OTEL_SERVICE_NAME=crag-api
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp-gateway-prod-<region>.grafana.net/otlp
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(instance_id:api_token)>
OTEL_TRACES_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_METRICS_EXPORTER=none
```

---

## New Packages to Install

```
fastapi==0.115.*
uvicorn[standard]==0.32.*
psycopg[binary]==3.2.*
psycopg-pool==3.2.*
langgraph-checkpoint-postgres==2.0.*
redis==5.2.*
python-jose[cryptography]==3.3.*
bcrypt>=4.0  # NOT passlib[bcrypt] — see Phase 3 note below
alembic==1.14.*
ragas==0.4.*  # corrected 2026-07-05 from an assumed 0.2.* — see Phase 9 note
pytest-asyncio==0.24.*
httpx==0.27.*
fakeredis==2.26.*
langfuse==4.*  # corrected 2026-07-05 from an assumed 3.* — see Phase 9 note
structlog==24.*
opentelemetry-sdk==1.29.*
opentelemetry-exporter-otlp==1.29.*
opentelemetry-instrumentation-fastapi==0.50b*
opentelemetry-instrumentation-sqlalchemy==0.50b*
opentelemetry-instrumentation-redis==0.50b*
pydantic-settings==2.*
ruff==0.8.*
tenacity==9.*
```

---

## Step-by-Step Migration Order

**Convention:** every phase below ends with a testing step for that phase's own functionality, not just a final "Test Hardening" phase at the end. Automated (pytest/Vitest/Playwright) where practical; a manual verification step where it genuinely isn't (e.g., confirming a dashboard actually shows data). Phase 10 ("Test Hardening") doesn't invent tests from scratch — it consolidates fixtures and splits fast/slow tiers for tests that already exist from each phase's own testing step. Every phase's testing step also includes at least one **failure-path** test — simulating the dependency that phase introduces being down or erroring — not just the happy path; see [Resilience & Crash Prevention](#resilience--crash-prevention-backend--frontend) for why.

### Phase 1 — Infrastructure (Day 1)
1. Install new packages; extend `requirements.txt`
2. Provision PostgreSQL via **Supabase**: follow `setup/db_setup.md` step-by-step (create project → run SQL blocks in SQL Editor → copy connection strings to `.env`)
3. Provision Redis (local or managed): follow `setup/redis_setup.md` step-by-step (choose Docker or WSL2 → verify connection → add `REDIS_URL` to `.env`)
4. Extend `.env` with all new variables (Section above)
5. Create `pyproject.toml` with pytest config:
   ```toml
   [tool.pytest.ini_options]
   asyncio_mode = "auto"
   markers = ["integration: marks tests that call real LLMs"]
   ```
6. Testing: `tests/phase1_infrastructure/test_external_services_health.py` — verify Postgres connectivity, Redis `PING`/`CONFIG GET maxmemory*`, and that all required `.env` vars are present. This is the functional check that infrastructure is actually usable, not just provisioned.

### Phase 2 — Database Layer (Day 1–2)
1. Create `db/base.py` — async engine, `async_sessionmaker`, declarative `Base`
2. Create ORM models: `User`, `ChatSession`, `Message`, `RefreshToken` using SQLAlchemy 2.x `mapped_column` syntax
3. `alembic init db/migrations` → configure `alembic.ini` and `db/migrations/env.py` with async engine
4. `alembic revision --autogenerate -m "initial_schema"` → manually add triggers and indexes not captured by autogenerate
5. Skip `alembic upgrade head` for initial setup — tables were already created in Supabase via `setup/db_setup.md`. Use Alembic only for **future schema changes** going forward.
6. Testing: `tests/phase2_database/` — `test_models.py` (metadata/relationship assertions, no DB needed), `test_migrations.py` (live-schema-vs-model diff, single-head check, stamped-version check), `test_crud.py` (real INSERT/DELETE against Supabase inside a per-test SAVEPOINT that's always rolled back) — covers unique constraints, defaults, the `role` CHECK constraint, JSONB round-trip, and FK cascade delete.

### Phase 3 — Auth Layer (Day 2)
> **Retrofit applied (2026-07-03)**: an exception-handling audit found `get_current_user`'s revocation check (step 3) had no guard around its Redis call — a Redis outage raised a raw, uncaught exception instead of degrading gracefully. Fixed directly in `auth/dependencies.py` plus a new failure-path test in `tests/phase3_auth/test_dependencies.py`; see [Resilience & Crash Prevention](#resilience--crash-prevention-backend--frontend) for the fail-open rationale. Steps 3–4 below reflect the code as it now stands.
1. `auth/password.py`: hash with `bcrypt` directly (**not** `passlib.context.CryptContext`) — `passlib` 1.7.4 is unmaintained and incompatible with `bcrypt>=4.0`, which `chromadb` already requires. See `completed.md` Phase 3 notes.
2. `auth/jwt.py`: `python-jose` encode/decode; `create_access_token`, `create_refresh_token`, `decode_token`
3. `auth/dependencies.py`: `get_current_user` async dep (validates Bearer → revocation check → DB user load). Revocation check wraps the Redis call in try/except — on `ConnectionError`/`TimeoutError`, log a warning and treat the token as not-revoked (fail open) rather than raising.
4. Testing: unit tests for `auth/password.py` (hash round-trip, wrong password, salting, >72-byte truncation), `auth/jwt.py` (claims shape, tampered signature, expired token, wrong secret), `auth/dependencies.py` (valid token, revoked jti, refresh-token-used-as-access rejected, unknown/inactive user) — mocked DB + Redis (`fakeredis`), no LLM calls. **Failure-path**: mock the Redis client to raise `ConnectionError` on the revocation check and assert the request still succeeds (fail-open) with a warning logged, instead of an uncaught exception.

### Phase 4 — Cache Layer (Day 2)
> **Retrofit applied (2026-07-03)**: the same exception-handling audit found every function in `cache/sessions.py` let raw `redis.exceptions.*` escape on a Redis outage. Fixed directly: new `cache/exceptions.py` (`CacheUnavailableError`), every function in `cache/sessions.py` now catches `RedisError` and re-raises it — still doesn't decide fallback behavior (that stays a Phase 6 router concern, see [Fallback on Redis unavailability](#fallback-on-redis-unavailability)), just stops raw library exceptions from leaking out. 8 new failure-path tests in `tests/phase4_cache/test_sessions.py`. Steps 2–3 below reflect the code as it now stands.
1. `cache/client.py`: `get_redis(request)` dependency from `request.app.state.redis`
2. `cache/sessions.py`: implement all cache helper functions for ZSET/HASH/LIST/STRING patterns; every function catches `RedisError` and raises `CacheUnavailableError` instead
3. Testing: unit tests for every cache helper using `fakeredis.aioredis.FakeRedis` — ZSET 5-member eviction, HASH TTL refresh on read, LIST `LTRIM` to last 20, revocation STRING `NX` behavior; a second pass of the same tests against the real Docker `crag-redis` container to catch anything `fakeredis` hides. **Failure-path**: a Redis outage simulated for every function, asserting each raises `CacheUnavailableError`, never a raw `redis.exceptions.*` type

### Phase 5 — Graph Refactoring (Day 3) — Complete
> An exception-handling audit found **zero try/except anywhere** in `nodes/*.py`, `chains/*.py`, `graph.py`, or `main.py` — an OpenAI timeout, Tavily outage, or Chroma error crashes the whole CLI run today. Steps 5–6 below close this; see [Resilience & Crash Prevention](#resilience--crash-prevention-backend--frontend). **Retrofit note:** step 4's `get_langfuse_handler()` was built defensively (catches construction errors, returns `None`, caller skips adding it to `callbacks`) since `.env` had no Langfuse keys yet at the time. Real keys were added the same day and the trace was confirmed via the Langfuse public API (`GET /api/public/traces`) — see `completed.md`.
1. Modify `graph.py`: extract `create_app(checkpointer)` factory; remove module-level compile and `draw_mermaid_png`
2. Modify `main.py`: instantiate `MemorySaver()` locally; call `create_app()`; wrap the `app.stream(...)` call in a top-level try/except as defense-in-depth, printing a clear message instead of a raw traceback
3. Inline LangChain Hub prompt in `chains/generation.py`
4. `observability/langfuse_client.py`: `get_langfuse_handler()` factory; wire it into `main.py`'s `app.stream(...)` call — see [Observability](#observability-langfuse). Doing this now (not deferred to Phase 13) means every phase after this one is already traced.
5. `nodes/retrieve.py`, `nodes/web_search.py`, `nodes/generate.py`, `nodes/grade_documents.py`, `graph.py`'s `route_question`/`grade_generation_grounded_in_documents_and_question`: wrap each external call (Chroma retrieve, Tavily invoke, LLM invoke — including the retrieval/hallucination/answer graders and the router, not just generation) with a bounded `tenacity` retry (2 attempts, exponential backoff) for transient errors, and a graceful degrade on exhaustion — see the Backend pattern in [Resilience & Crash Prevention](#resilience--crash-prevention-backend--frontend). `generate()` is the one exception: it has no lower-fidelity fallback to degrade to, so it re-raises after retries are exhausted and lets `main.py`'s top-level handler report it, rather than returning a canned answer that would likely fail hallucination grading and loop.
6. Testing: `pytest chains/tests/` still passes (7/7) against the refactored `create_app()` factory and inlined prompt — regression check that extracting the factory and adding retry/degrade logic didn't change happy-path chain/node behavior. **Failure-path** (`tests/phase5_graph/test_resilience.py`, 8 tests): patches each `_call_*`/`_grade_*`/`_route_question` tenacity-wrapped helper to always raise (retries exhausted) and asserts the documented degrade — `retrieve`/`web_search` degrade to empty documents/results, `grade_documents` degrades to `web_search=True`, `route_question` defaults to `websearch`, both graders in `grade_generation_grounded_in_documents_and_question` default to `"useful"` — except `generate()`, which is asserted to propagate the exception.
7. Verify: `python main.py` runs end-to-end — both the direct-to-websearch path and the RAG path (including the RAG→partial-relevance→websearch fallback mid-graph) were run manually and produced correct answers. Langfuse trace confirmed live via the public API once real keys were added (see retrofit note above).

### Phase 6 — FastAPI Application (Day 3–5) — Complete
> Built against the **live Supabase DB** (no separate `crag_test` database exists yet - that's Phase 10's job; these tests use the same rolled-back-SAVEPOINT pattern as `tests/phase2_database/conftest.py` instead). Four real bugs were found and fixed only by actually running the app, not just importing it - see `completed.md` for full detail: (1) `uvicorn api.main:app` doesn't work on Windows at all with this app - modern uvicorn hardcodes `ProactorEventLoop` for its "asyncio"/"auto" loop regardless of `asyncio.set_event_loop_policy()`, so a dedicated `run_api.py` supplies a custom loop factory instead; (2) `AsyncPostgresSaver` isn't an async context manager in the installed `langgraph-checkpoint-postgres` version - this plan's original `async with AsyncPostgresSaver(...) as saver:` snippets (here and in [LangGraph Integration](#langgraph-integration)) were wrong, fixed to plain construction; (3) `AsyncConnectionPool` needs `kwargs={"autocommit": True}` - `AsyncPostgresSaver.setup()`'s migrations use `CREATE INDEX CONCURRENTLY`, which Postgres refuses inside a transaction block; (4) a Redis session-cache consistency bug where a message-less session was DB-fallback-visible but invisible on a cache hit (fixed by always scoring the ZSET write with `last_message_at or created_at`, and by having `chat.py` refresh the session cache after every message instead of relying on the next listing call to repopulate it).
1. `config.py` — `Settings`/`get_settings()` (pydantic-settings); everything below reads config through it, not `os.getenv`
2. `api/schemas/` — all Pydantic models
3. `db/crud/{users,sessions,messages}.py` — plain functions wrapping the SQLAlchemy queries routers need (e.g. `get_session(db, session_id, user_id)` doing the ownership check once instead of duplicating it in `sessions.py` and `chat.py`); routers call these instead of building queries inline. Also added `db/crud/refresh_tokens.py` (not in this plan's original file tree) - the Auth Flow section's refresh/logout semantics need DB-backed refresh-token lookup/revocation, which has to live somewhere
4. `api/dependencies.py` — `get_db`, `get_redis`, `get_graph`, re-export `get_current_user`, plus `enforce_auth_rate_limit` (not originally listed here, but it's a shared dependency like the others). `get_db` catches `OperationalError` and raises a `503`. `get_redis` deliberately does **not** catch connection errors - see the amended "Fallback on Redis unavailability" note; every real caller already has a fallback (sessions/chat catch `CacheUnavailableError`) or fails open (auth rate limiter, Phase 3 revocation check), so a blanket 503 here would defeat both. `api/main.py` also wires `app.dependency_overrides[get_db_session] = get_db` / `[get_redis_client] = get_redis`, completing the Phase 3 design note that `get_current_user`'s own providers were built to be overridden here, not rebuilt - this was missed initially and caught only once tests started asserting on shared-session behavior
5. `api/routers/auth.py` — register, login, refresh, logout, me (uses `db/crud/users.py`); login and register are wrapped with the IP-based auth rate limiter (see [Configuration, Error Handling & Auth Rate Limiting](#configuration-error-handling--auth-rate-limiting))
6. `api/routers/sessions.py` — CRUD with Redis-first read, DB fallback on both cache-miss and Redis connection error (uses `db/crud/sessions.py`)
7. `api/routers/chat.py` — sync invoke + SSE stream; persist messages; update Redis caches (uses `db/crud/{sessions,messages}.py`). The SSE stream is contract-complete (`token`/`done`/`error` events) but **not token-by-token** - `nodes/generate.py`'s LLM call is a synchronous, tenacity-wrapped `.invoke()` inside a plain node function, so there's no per-token event source to relay yet; the endpoint runs the graph to completion, then emits the full answer as one `token` event. Real incremental streaming needs `generate()` reworked to stream, tracked as follow-up, not required for this phase's router-only scope
8. `api/error_handlers.py` — global `HTTPException`/`Exception` handlers, consistent JSON error envelope
9. `api/main.py` — lifespan, mount routers under `/v1`, register error handlers, CORS, request-ID middleware
10. Manual API smoke test (via `run_api.py`, not `uvicorn api.main:app` directly - see the Windows note above):
    ```bash
    python run_api.py
    curl -X POST http://localhost:8000/v1/auth/register -H "Content-Type: application/json" \
         -d '{"email":"a@b.com","username":"alice","password":"test1234"}'
    ```
    Actually run end-to-end against the live Supabase DB and real Redis container: register → login → `/me` → create session → send a chat message (full CRAG graph through a real `AsyncPostgresSaver`) → list/rename/archive sessions (including the Redis cache-hit path) → SSE stream → refresh-token rotation + old-token rejection → logout + post-logout revocation → cross-user ownership 404s → duplicate-register 409 → bad-login 401 → validation 422. No errors in the server log across the whole run.
11. Testing (`tests/phase6_api/`, 24 tests): `httpx.AsyncClient` + `ASGITransport` (with `raise_app_exceptions=False` - see the note in `tests/phase6_api/conftest.py` about why the default `True` hides the exact 500-envelope behavior these tests need to assert on) against the live DB via the same SAVEPOINT-rollback pattern as Phase 2, plus `fakeredis` and a `FakeGraph`/`FailingGraph` test double for the graph dependency. Covers register/login/refresh/logout/me, session CRUD with cross-user ownership enforcement, chat sync-invoke and SSE-stream happy paths (fast, no real LLM calls) plus one `@pytest.mark.integration` test with the real graph, and the IP-based auth rate limiter returning `429` past the threshold. **Failure-path**: `get_db()` unit-tested directly against an unreachable-host engine, injecting the resulting `OperationalError` via `gen.athrow(...)` (mirroring how FastAPI actually tears down a yield-dependency on an endpoint exception) and asserting `503`; a non-`OperationalError`, non-`HTTPException` failure in a dependency asserted to produce the generic handler's `{"detail": "internal server error"}` envelope, not a leaked traceback; the CRAG-graph-fails path asserted to return `502` (sync) / an `{"type": "error"}` SSE frame (stream) rather than crashing the request.

### Phase 7 — Next.js Frontend: Auth (Day 5–6)
Split from the chat UI (Phase 8) because they're genuinely different problems: this phase is entirely about getting the token lifecycle right (login, register, silent refresh, logout, route protection) with nothing to visually show for it beyond forms — worth its own phase and its own manual test pass before any chat UI complexity gets layered on top. Both together were "Phase 7 — Next.js Frontend" before this split. Separate Next.js project (own `package.json`), App Router + TypeScript + Tailwind — a `frontend/` subdirectory of this repo, not part of the Python project. Built right after the API exists and is smoke-tested — nothing in Phases 9–15 changes the API contract, so building the UI here (instead of last) surfaces real contract problems while they're still cheap to fix.

**Auth token handling:** access token in memory only (React context, never `localStorage`), attached as an `Authorization: Bearer` header on every request directly to FastAPI (no BFF/proxy layer — see [Key Design Decisions](#key-design-decisions) for why the refresh token needs different treatment than the access token).

```
frontend/
├── app/
│   ├── layout.tsx
│   ├── page.tsx                   # redirects to /login or /chat based on auth state
│   ├── error.tsx                  # NEW: root error boundary — catches render-phase crashes app-wide
│   ├── login/page.tsx
│   └── register/page.tsx
├── components/
│   └── AuthProvider.tsx           # React context: access token in memory, silent refresh
├── lib/
│   └── api.ts                     # fetch wrapper: base URL, Authorization header, 401 → refresh → retry once, all network/parse errors caught and surfaced as UI state
├── .env.local.example             # NEXT_PUBLIC_API_BASE_URL=http://localhost:8000/v1
├── package.json
└── tsconfig.json
```

1. `npx create-next-app@latest frontend --typescript --tailwind --app`
2. `app/error.tsx` — root error boundary (see [Resilience & Crash Prevention](#resilience--crash-prevention-backend--frontend)); catches render-phase crashes so the whole app never blanks, only shows a retry screen
3. `lib/api.ts` — fetch wrapper with base URL, `Authorization` header injection, single silent-refresh-then-retry on 401; every network failure, timeout, and non-2xx response is caught and converted to a typed error the UI can render, never an unhandled rejection (error boundaries don't catch these — this has to be explicit)
4. `components/AuthProvider.tsx` — access token in a React context; refresh token in `localStorage` (accepted tradeoff, not a BFF pattern — see Key Design Decisions); proactive refresh timer at ~80% of the 15-minute access-token TTL
5. `app/login`, `app/register` — forms calling `/v1/auth/login`, `/v1/auth/register`; a route guard (middleware or layout-level check) redirects unauthenticated users to `/login`
6. Backend: confirm `CORS_ORIGINS` (Phase 1 env var) includes `http://localhost:3000`
7. Testing: component tests (Vitest + React Testing Library) for `AuthProvider`/`api.ts` — access token held in memory, single silent-refresh-then-retry on a mocked 401, logout clears both tokens; a Playwright e2e test driving the real dev server: register → login → reload → still logged in → logout → redirected to `/login`. **Failure-path**: mock `fetch` to reject (network down) on login and assert the form shows an error state, not an unhandled rejection or a blank screen; mock a component to throw during render and assert `app/error.tsx`'s fallback renders instead of a crash
8. Manual smoke test: register → login → confirm `GET /v1/auth/me` works with the stored access token → hard-reload the page and confirm login survives (refresh token from `localStorage`) → wait past silent-refresh threshold and confirm exactly one refresh happens (check network tab), not a loop → logout clears both tokens and redirects to `/login`

### Phase 8 — Next.js Frontend: Chat UI (Day 6–7)
Builds on Phase 7's `AuthProvider`/`api.ts` — every request here already carries the Bearer token and survives a silent refresh, so this phase is purely session management + the chat experience. Full UX (session rename/delete/archive, streaming render, loading/error states), not a bare-bones MVP.

**Streaming:** native `EventSource` cannot send custom headers, so it can't carry the `Authorization` Bearer token Phase 7 established. Use `fetch` with a `ReadableStream` reader to consume `GET /v1/sessions/{id}/stream` and parse SSE frames manually instead.

```
frontend/
├── app/
│   └── chat/[sessionId]/
│       ├── page.tsx               # message list + input, SSE streaming render
│       └── error.tsx              # NEW: route-level boundary — a crash here doesn't take out the sidebar/nav
├── components/
│   ├── SessionSidebar.tsx         # last-5 sessions (GET /v1/sessions), create/rename/delete/archive
│   └── ChatMessage.tsx
└── lib/
    └── sse.ts                     # fetch + ReadableStream SSE parser (see streaming note above); catches drops/malformed frames
```

1. `components/SessionSidebar.tsx` — list/create/rename/delete/archive via `/v1/sessions`
2. `lib/sse.ts` — SSE frame parser on top of `fetch` + `ReadableStream` (see streaming note above); a dropped mid-stream connection or a malformed frame is caught and surfaced as a visible `{"type": "error"}` chat-UI state (already part of the SSE event contract — see [API Endpoints](#api-endpoints)), never an unhandled rejection
3. `app/chat/[sessionId]/page.tsx` + `error.tsx` — history via `GET /v1/sessions/{id}/messages`; send via sync `POST` or `lib/sse.ts`'s streaming `GET`; the route-level boundary means a crash rendering one chat page doesn't take out the session sidebar or the rest of the app
4. Testing: component tests for `SessionSidebar` (renders the 5 most recent, create/rename/delete/archive call the right endpoints and update local state) and `lib/sse.ts` (parses a mocked multi-chunk `ReadableStream` into the correct `token`/`done`/`error` events); a Playwright e2e test: create a session → send a message → assert the rendered answer text appears → rename → archive. **Failure-path**: simulate the `ReadableStream` throwing/closing mid-response and assert the chat UI shows a visible error state (not a silent hang or a stuck spinner); simulate a component in the chat page throwing and assert `error.tsx` catches it without taking down `SessionSidebar`
5. Manual smoke test: create a session → send a message → watch it stream token-by-token → rename the session → archive/delete it → confirm the sidebar's last-5 list updates correctly after each action

### Phase 9 — Evaluation Suite (Day 7–8)
1. Build 25-sample dataset in `eval/dataset.py` (derive ground_truth from Chroma or blog posts)
2. `eval/metrics.py`: instantiate RAGAS metrics + thresholds dict
3. `eval/langfuse_eval.py`: `create_or_get_dataset`, `run_target`, `score_and_push` (see [Observability](#observability-langfuse))
4. `eval/run_eval.py`: argparse CLI with threshold gate + markdown output
5. Testing: fast unit test (no LLM calls) that `eval/dataset.py` loads exactly 25 items with the correct routing split (20 `vectorstore` with `ground_truth`, 5 `websearch` with `ground_truth=None`) and that `eval/metrics.py`'s threshold dict has all 4 required keys — catches dataset/config typos before burning API calls on the real run below
6. Run baseline: `python -m eval.run_eval --experiment-name baseline-v1`
7. Record baseline scores and Langfuse dataset-run URL — these become regression thresholds for CI

**Version-drift correction (2026-07-05):** the environment already had `ragas==0.4.3` and `langfuse==4.13.0` installed — newer than this plan's original `ragas==0.2.*`/`langfuse==3.*` assumptions, and both introduced real breaking changes. Verified directly against the installed packages before writing `eval/`:
- **ragas 0.4.x**: `SingleTurnSample`/`single_turn_ascore` (the API this plan originally sketched) still exist but the metric classes now require an `InstructorBaseRagasLLM`/`BaseRagasEmbedding` (via `ragas.llms.llm_factory("gpt-4o-mini", client=AsyncOpenAI())` and `ragas.embeddings.OpenAIEmbeddings(client=...)`) — the old `LangchainLLMWrapper`/`LangchainEmbeddingsWrapper` are deprecated and fail an `isinstance` check against the new base classes, so they're silently rejected. `eval/metrics.py` uses `ragas.metrics.collections.{Faithfulness,AnswerRelevancy,ContextRecall,ContextPrecision}` with the modern `.ascore(user_input=, response=, retrieved_contexts=, reference=)` (returns a `MetricResult`, read via `.value`), not `.single_turn_ascore(sample)`.
- **langfuse 4.x**: no `item.get_langchain_handler(run_name=...)` linking or manual `create_score`/`score_and_push` needed — `langfuse.get_dataset(name)` returns a `DatasetClient` with a `.run_experiment(name=, task=, evaluators=)` convenience method that runs the task per item, invokes evaluators (returning `Evaluation`/`list[Evaluation]`), and auto-creates+links the dataset run. The returned `ExperimentResult` carries `.item_results` (per-item `.output`/`.evaluations`) and `.dataset_run_url` directly — no manual project-ID/URL construction needed. `eval/langfuse_eval.py` and `eval/run_eval.py` are written against this.

Pins corrected above (`ragas==0.4.*`, `langfuse==4.*`) and in `backend/pyproject.toml`'s `eval`/core dependency groups.

**Deferred for Next (2026-07-05):** per-agent/per-node scoring — pushing a Langfuse score for the router's routing-accuracy (vectorstore vs. websearch, checked against the dataset's known routing label) and for the retrieval/hallucination/answer graders' own binary decisions. Today these graders run on every request and are visible as individual traced LLM calls inside each trace, but nothing scores whether their yes/no calls were *correct* — only the end-to-end RAGAS metrics against the final answer are scored. The 25-item dataset already carries the routing label this would need; revisit once the end-to-end suite above is running and baselined.

### Phase 10 — Dockerization (Local Docker Desktop) (Day 8–9)
**Decision (2026-07-03):** containerize the whole stack — backend, frontend, and Redis — so the app runs with one command on local Docker Desktop, as a deliberate checkpoint before any future enterprise-grade deployment pass (see [Deferred to a Future Enterprise-Grade Pass](#deferred-to-a-future-enterprise-grade-pass)). Postgres stays on Supabase, not containerized — it's already a managed connection string, and running a second local Postgres would just create a schema-drift risk against the real `setup/db_setup.md`-provisioned tables. This absorbs and extends what used to be Phase 11 steps 2–3 (backend `Dockerfile` + `docker-compose.yml`), now split out into its own phase and given a matching frontend image so both halves of the app are containerized together, not just the API.
1. `backend/Dockerfile` — `python:3.12-slim`, installs via `uv`, `CMD ["python", "run_api.py"]` (not `uvicorn api.main:app` directly — same Windows-loop-factory reasoning doesn't apply inside the Linux container, but keeping the entrypoint identical to local dev avoids a second code path to maintain). Build context is `backend/` itself, not the repo root — this image never needs anything from outside `backend/`, so there's no reason for it to build from further up the tree (corrected from an earlier draft that put it at the repo root for no functional reason)
2. `frontend/Dockerfile` — multi-stage Next.js build: `node:20-slim` builder stage (`npm ci && npm run build`) → slim runtime stage copying `.next/standalone` output (`next.config.js` needs `output: "standalone"`) → `CMD ["node", "server.js"]`
3. `backend/.dockerignore` and `frontend/.dockerignore` — exclude `.venv`/`node_modules`, `.chroma`, `.env`/`.env.local`, `__pycache__`, `.next`
4. `docker-compose.yml` (root) — three services:
   ```yaml
   services:
     redis:
       image: redis:7
       ports: ["6379:6379"]
       healthcheck: {test: ["CMD", "redis-cli", "ping"], interval: 5s, retries: 5}
     backend:
       build: ./backend            # build context is backend/, not the repo root
       env_file: backend/.env      # not root .env — backend/ is its own project root
       environment:
         REDIS_URL: redis://redis:6379/0   # overrides backend/.env's localhost value
       ports: ["8000:8000"]
       depends_on: {redis: {condition: service_healthy}}
       healthcheck: {test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=3)"], interval: 5s, retries: 5}
     frontend:
       build:
         context: ./frontend
         args: {NEXT_PUBLIC_API_BASE_URL: http://localhost:8000/v1}
       ports: ["3000:3000"]
       depends_on: {backend: {condition: service_healthy}}
       healthcheck: {test: ["CMD", "node", "-e", "require('http').get('http://localhost:3000', r => process.exit(r.statusCode < 500 ? 0 : 1)).on('error', () => process.exit(1))"], interval: 5s, retries: 5}
   ```
   Easy-to-get-wrong details, corrected here from an earlier draft of this plan:
   - `env_file` must point at `backend/.env`, not a root `.env` — `docker-compose.yml` lives at the repo root but the actual file (and everything reading it) is under `backend/`.
   - `backend`'s build context is `./backend`, not `.` — an earlier draft put `backend/Dockerfile` at the repo root purely so it would sit next to `docker-compose.yml`, which forced every `COPY` in it to carry a `backend/` prefix for no functional reason (the image copies nothing from outside `backend/`). Moving the `Dockerfile` into `backend/` itself lets those `COPY` paths drop the prefix, matching how `frontend/Dockerfile` already builds from `./frontend`.
   - Only `backend`'s `REDIS_URL` should use the compose DNS name (`redis`) — that traffic is container-to-container. `NEXT_PUBLIC_API_BASE_URL` must stay a **host**-reachable URL (`http://localhost:8000/v1`), not `http://backend:8000/v1`: Next.js inlines `NEXT_PUBLIC_*` values into the client JS bundle at *build* time, and that bundle runs in the user's browser on the host machine, not inside the compose network — the browser can never resolve the `backend` DNS name. This also means it must be passed as a Docker build `arg`, not a service `environment`/`env_file` entry, since those only affect the already-built server process. Postgres (Supabase) needs no DNS-name juggling either way, since it's already a remote host from both sides.
   - `depends_on: condition: service_healthy` (not bare `depends_on: [service]`) plus explicit `healthcheck:` blocks on all three services — bare `depends_on` only waits for the container to *start*, not for Redis/the backend to actually be ready, which would make "confirm all three containers report healthy" in the testing step below unverifiable.
5. Verify Chroma persistence survives a container restart: the backend image bind-mounts `multi_agent/.chroma/` (`volumes: ["./backend/multi_agent/.chroma:/app/multi_agent/.chroma"]`, host path relative to `docker-compose.yml` at the repo root, container path relative to the image's `WORKDIR /app`) rather than baking it into the image, so re-ingesting on every rebuild isn't required
6. Testing: `docker compose up --build` from a clean state (no local `.venv`/`node_modules` needed on the host at all) — confirm all three containers report healthy, then run the same manual smoke test as Phase 8's (register → login → create session → chat → SSE stream, from the browser at `localhost:3000`) entirely through the containerized stack. **Failure-path**: stop the `redis` container mid-session and confirm the app degrades per the existing Redis-fallback behavior (Phase 4/6), not a crash — same assertion as those phases' tests, just re-run against real containers instead of `fakeredis`, to catch anything container networking hides that a mock wouldn't
7. Document the one-command flow in a root `README.md` section: `docker compose up --build`, plus which two `.env` files (`./.env`, `frontend/.env.local`) must exist first since compose doesn't create them

### Phase 11 — Test Hardening (Day 9)
Consolidates fixtures and tiering for tests that already exist from each phase's own testing step above — doesn't invent test coverage from scratch.
1. Add fixtures for DB, Redis, HTTP client, authenticated user to `tests/conftest.py` (corrected from an earlier draft's `chains/tests/conftest.py` — that directory only holds LLM chain tests with no DB/Redis/HTTP-client fixtures to share; the shared fixtures actually needed by phase2_database/phase6_api/phase12_production live at the top-level `tests/` package instead, where pytest's conftest auto-discovery makes them visible to every phase subdirectory without an import)
2. Mark existing LLM-calling tests with `@pytest.mark.integration`
3. Add any remaining fast unit tests (no LLM) not already covered per-phase: auth logic, cache logic, ownership validation
4. `frontend/`: Vitest config for the component tests from Phases 7–8, Playwright config for the e2e tests — `npm run test` (fast) vs `npm run test:e2e` (spins up the dev server + backend)
5. Testing: verify the two-tier backend split and the frontend test split both run cleanly:
   ```bash
   pytest -m "not integration"   # fast, no LLM
   pytest -m integration         # slow, requires API keys
   npm run test                  # frontend unit/component
   npm run test:e2e              # frontend e2e
   ```

### Phase 12 — Production Hardening (Day 9–10, optional)
1. Structured logging (`structlog`): include `request_id`, `user_id`, `session_id` in every log line (baseline stdout output only — trace-correlated OTLP export to Grafana Cloud is added in Phase 14, not redone here)
2. Rate limiting middleware (Redis INCR per user per minute bucket; reject at 60 req/min) — general-purpose, for authenticated endpoints. Auth endpoints already have their own stricter IP-based limiter from Phase 6.
3. `/health` endpoint with real `SELECT 1` DB check and Redis `PING`
4. Testing: hit `/health` with both dependencies up (expect 200) and again with the Redis container stopped (expect the documented degraded response, not a 500); a test that exceeds the general rate limit bucket and confirms 429

### Phase 13 — Observability (Langfuse) — Complete
> Numbered here for doc/folder consistency only — the actual wiring happens in **Phase 5, step 4** above, as soon as `create_app()` exists. This phase entry exists so `completed.md`/`tests/`/`test_reports/` have a phase slot to track it against, matching every other phase in this plan.
1. `observability/langfuse_client.py`: `get_langfuse_handler()` (done in Phase 5)
2. Wire the handler into `api/routers/chat.py`'s sync-invoke and SSE-stream paths (Phase 6), tagged with `user_id`/`session_id`/`trace_name` via LangChain's `config={"metadata": {"langfuse_user_id": ..., "langfuse_session_id": ..., "langfuse_trace_name": ...}}` — **not** `langfuse.propagate_attributes()` as originally written here. `propagate_attributes` relies on OTel context (contextvars), which does not survive LangGraph's thread-pool execution of this graph's plain-sync nodes under `.ainvoke()` (proven by a repro: a span opened inside `loop.run_in_executor` gets an unrelated `trace_id`); the `metadata` dict is passed by value through LangChain's config plumbing instead, so it survives. See `completed.md`'s Phase 13 entry for the full repro and the real-trace-data verification.
3. Wire the handler into `eval/langfuse_eval.py` via `item.get_langchain_handler(...)` (Phase 9)
4. Testing: unit test that `get_langfuse_handler()` returns a `CallbackHandler` without raising when the required env vars are set — so a missing/misconfigured Langfuse key fails a fast test in CI instead of silently disabling tracing in production
5. Verify: run a few chat requests through the API, confirm traces appear in the Langfuse Cloud dashboard with correct user/session tags and per-node latency/cost breakdown

### Phase 14 — Observability (OpenTelemetry + Grafana Cloud) (Day 10) — Complete except real OTLP export (pending `GRAFANA_OTLP_INSTANCE_ID`, see `completed.md`)
1. Create a free Grafana Cloud stack; retrieve the OTLP gateway endpoint, instance ID, and API token; add the new env vars
2. `observability/logging_config.py`: structlog config with the trace_id/span_id injection processor, JSON renderer, bridged into stdlib `logging`
3. `observability/otel_client.py`: `setup_otel(app, db_engine)` — TracerProvider/LoggerProvider + OTLP exporters; instrument FastAPI, SQLAlchemy, Redis
4. Wire into `api/main.py` lifespan: call `setup_otel(app, app.state.db_engine)` once at startup, after the DB engine is created
5. Add structured audit log calls in `auth/dependencies.py` / `api/routers/auth.py` for login, logout, refresh, and revoked-token-rejected events
6. Correlate with Langfuse: pass the existing `X-Request-ID` (Phase 6 middleware) into both the OTel span attributes and Langfuse trace metadata
7. Testing: unit test `setup_otel()` against an in-memory `InMemorySpanExporter` (not the real OTLP endpoint) — confirms FastAPI/SQLAlchemy/Redis spans are actually created for a sample request, runs offline in CI, independent of whether Grafana Cloud is reachable
8. Verify: hit a few API endpoints, confirm nested FastAPI → SQLAlchemy → Redis spans appear in Grafana Cloud's Tempo explorer, and structured logs appear in Loki with matching `trace_id` fields (clickable through to the trace via Loki's derived fields)

### Phase 15 — AWS Serverless Deployment (Lambda + API Gateway + CloudFront), Terraform via LocalStack first (Day 11–12) — Stage A complete (steps 1–5: Terraform scaffolding, Lambda Web Adapter, `boto3`, SSM-aware `config.py`, frontend static export); **Stage B complete and verified end-to-end against LocalStack (2026-07-08) — both backend compute (Lambda ×2/API Gateway/IAM/SSM) and frontend (S3/CloudFront/OAC)**; Stage C (real AWS) not yet started — see `completed.md` and `enterprize-deploy-steps.md`'s Stage B entries for the real gaps found: a CloudFront-Functions-not-executed LocalStack limitation, a CloudFront `origin_read_timeout` fix (needed for real AWS), and a second LocalStack-only gap where LocalStack's own origin-forwarding proxy hardcodes a 30s timeout regardless of that setting — both timeout-related gaps need re-confirming on real AWS in Stage C
**Decision (2026-07-03):** every service below is picked specifically to keep this at or near $0/month at learning-project traffic — see the Key Design Decisions rows for the reasoning behind each swap from the "obvious" choice.

**Services:** AWS Lambda (container image) for compute; **AWS Lambda Web Adapter** (not Mangum — Mangum buffers the entire ASGI response and cannot relay a `StreamingResponse`/SSE; the adapter runs the real `uvicorn` process and proxies to it, so `run_api.py` doesn't change) as the runtime shim; a **Lambda Function URL** (`invoke_mode = RESPONSE_STREAM`) for the chat/stream routes specifically, bypassing API Gateway's 29s integration timeout and response buffering; **API Gateway HTTP API** (v2, not REST API — roughly a third of the per-request cost) for everything else (`/v1/auth/*`, `/v1/sessions` CRUD, `/health`); **S3 + CloudFront** for the frontend, built as a Next.js **static export** rather than an SSR Lambda (no OpenNext needed, since `AuthProvider`'s route guard is already client-side/in-memory — confirm nothing relies on Next.js middleware before exporting); **Upstash Redis** (external, HTTP-based, real free tier) in place of ElastiCache — this also removes any reason for Lambda to sit in a VPC, since Upstash and the existing Supabase pooler are both public HTTPS endpoints, which avoids a NAT Gateway (~$32/month), the single biggest avoidable cost here; Supabase Postgres unchanged; **SSM Parameter Store** (Standard tier, free) instead of Secrets Manager ($0.40/secret/month) for the JWT key, OpenAI/Tavily keys, Upstash URL, DB URL; Terraform state in an S3 backend + DynamoDB lock table (pay-per-request billing — effectively free at this scale).

1. `infra/` — new Terraform root: `aws` provider pinned to a region, S3 + DynamoDB remote state, variables for account/region/secret names
2. Add the AWS Lambda Web Adapter layer to the backend `Dockerfile` (`AWS_LWA_INVOKE_MODE=RESPONSE_STREAM`, `PORT=8000`) — verify the image still runs unchanged via plain `docker run` before touching Terraform at all
3. Terraform: ECR repo + pushed image; `aws_lambda_function` (image-based); `aws_lambda_function_url` (`RESPONSE_STREAM`) for the chat routes; `aws_apigatewayv2_api` + Lambda proxy integration + routes for everything else; an IAM execution role scoped to just `ssm:GetParameter` + CloudWatch Logs
4. Terraform: SSM `SecureString` parameters for every secret currently in `.env`; `config.py`'s `Settings` reads them via `boto3` at cold start when `APP_ENV=production`, falls back to `.env` locally — one class, two sources
5. Frontend: switch to `output: "export"`, audit for server-only Next.js features that would break under a static export, build, upload to a private S3 bucket — **done, with two corrections found by actually building it (see `completed.md`)**: `output` is now conditional on a `NEXT_OUTPUT_MODE` build-time env var (unconditionally overwriting it would have broken Phase 10's Docker Compose deployment, which needs `"standalone"`); and `app/chat/[sessionId]/page.tsx`'s dynamic route was converted to `app/chat/page.tsx` reading `?sessionId=` via `useSearchParams()`, since static export cannot pre-render a path segment for arbitrary runtime session IDs (`generateStaticParams()` would have to enumerate every session UUID, which is impossible)
6. Terraform: S3 bucket (private, Origin Access Control) + one CloudFront distribution with three path-based behaviors — default → S3, `/v1/sessions/*/stream` (and the sync message-send route) → the Function URL with caching disabled, everything else under `/v1/*` → the HTTP API. Skip a custom domain/ACM cert for now (use the CloudFront default domain) to stay fully in the free tier — **done** (`infra/s3.tf` + `infra/cloudfront.tf`), with a fourth thing this step's description didn't anticipate: CloudFront's own default `origin_read_timeout` (30s) needed raising to 60s on the streaming behavior's origin, since it sat right at the CRAG pipeline's measured 31.4s latency and would have silently reintroduced the exact timeout class the Function URL split exists to avoid — see `completed.md`'s Phase 15 entry. **This setting itself can't be fully proven on LocalStack**: a second, distinct LocalStack-only gap was found re-testing later the same day — LocalStack's own CloudFront-to-origin forwarding proxy hardcodes a 30s read timeout regardless of the distribution's configured `origin_read_timeout` (confirmed via LocalStack's own container log, and via `terraform plan` showing zero drift on the 60s setting) — so the fix is correct and needed for real AWS, but only calls under 30s can actually be shown succeeding on LocalStack; calls in the 31–60s range need their first real proof in Stage C.
7. **Validate on LocalStack, using its 45-day free Ultimate-tier trial (no credit card required)** — corrected 2026-07-03 from an earlier, now-stale assumption: LocalStack replaced its old Community/Pro split with Hobby (free)/Base ($39–45/mo)/Ultimate ($89/mo) tiers, and the free **Hobby** tier only covers Lambda/S3/IAM/SSM plus the **REST** API Gateway — not the **HTTP** API Gateway or CloudFront this phase actually uses, both of which need Base or higher. The 45-day Ultimate trial covers everything in this phase (and Phase 16's ECS/ALB) for free, so activate it only once actually ready to build — don't start the clock early — and do all local Terraform validation for both phases inside that one window before it reverts to Hobby. **Done** — activated 2026-07-08, both backend and frontend fully validated end-to-end against it (register → login → create session → real chat message → message history → real SSE stream, all through the CloudFront distribution's own domain), including confirming for real that LocalStack's CloudFront OAC can sign requests to a Lambda Function URL origin (previously an open question). Two confirmed LocalStack-only gaps, both needing their first real-AWS check in step 8: CloudFront Function `viewer-request` associations are accepted by `terraform apply` but never actually execute at request time (plain-URL browsing, `/login` vs `/login.html`, is untested); and LocalStack's own origin-forwarding proxy hardcodes a 30s timeout independent of the distribution's configured `origin_read_timeout` (calls over 30s are untested end-to-end).
8. Point Terraform at real AWS, `terraform apply`, run the same manual smoke test as Phase 10 (register → login → create session → chat → SSE stream) against the live CloudFront URL — **also include a plain-browser check of `/login`/`/register`/`/chat` with no `.html` suffix, and a chat message that takes 30–60s end-to-end**, per step 7's two flagged LocalStack-only gaps (CloudFront Function execution, origin read timeout)
9. Testing: `curl -N` (or equivalent) directly against the Function URL confirming chunks arrive incrementally, not buffered; a cold-start-latency spot check; confirm the auth rate limiter and Redis-down fail-open behavior still hold with Upstash instead of `fakeredis`/local Redis. **Failure-path**: temporarily break the Upstash URL and confirm the same graceful-degrade behavior from Phase 4/6, this time against a real HTTP-based client
10. Document `terraform destroy` as the default between demos — nothing here should be left running 24/7 by accident

### Phase 16 — AWS Container Deployment: ECS Fargate (Day 12–13)
**Status (2026-07-10): Stage A/B built and verified end-to-end on LocalStack, including a real browser test — see `completed.md`'s Phase 16 entry.** Stage C (real AWS) not started. One design point below was decided differently once actually built, worth flagging here since it's a repo-structure decision, not just an execution detail: `infra/fargate/` was built **fully independent** of Phase 15's `infra/lambda-gate/` — its own ECR repository, own SSM `SecureString` parameters (at `/crag/prod-ecs/*`, not `/crag/prod/*`), own S3 frontend bucket, own scripts — rather than reusing Phase 15's ECR image/SSM parameters as step 6 below still describes. Reason: `infra/` was split into per-target Terraform roots (`infra/lambda-gate/`, `infra/fargate/`) specifically so each deploy target can be applied/destroyed/reasoned-about independently; a shared ECR repo or a cross-stack SSM read would have reintroduced exactly the coupling that split was meant to remove. Step 6 below is left as-is (it was the original design intent) rather than rewritten, since `completed.md`'s Phase 16 entry is the authoritative record of what was actually built and why it changed.

**Decision (2026-07-03):** originally scoped as EKS; swapped to **ECS Fargate** for this pass specifically because affordability was the stated priority — EKS's control plane is a flat ~$0.10/hr (~$73/month) regardless of usage, on top of whatever compute runs the pods, while ECS has no control-plane fee at all. ECS Fargate also removes the entire SSE/Lambda-timeout workaround from Phase 15: a long-lived container behind a load balancer streams `StreamingResponse` natively, no Function URL/adapter needed. If the goal shifts from "cheapest second deployment target" to "learn real Kubernetes regardless of cost," EKS is a straightforward substitution at this same phase slot — noted explicitly rather than silently decided.

1. Reuse Phase 15's VPC (or a minimally-sized new one) — Fargate tasks always require a VPC, unlike the Lambda in Phase 15 which deliberately avoided one — but give each task a **public IP directly** (public subnet + Internet Gateway route) instead of a private subnet + NAT Gateway, keeping this phase's mandatory networking cost at the Internet Gateway (free) rather than NAT (~$32/month)
2. Terraform: `aws_ecs_cluster` (no charge for the cluster itself, only running tasks are billed); `aws_ecs_task_definition` referencing the **same ECR image built for Lambda, minus the Lambda Web Adapter layer** (plain `CMD ["python", "run_api.py"]` — real `uvicorn` behind a real load balancer, no adapter needed); `aws_ecs_service` at the cheapest Fargate size (0.25 vCPU / 0.5 GB), desired count 1 (single instance — no HA yet, a deliberate cost/availability tradeoff for a learning deployment, not an oversight)
3. Terraform: `aws_lb` (Application Load Balancer) + target group (health check on `/health`) + HTTPS listener; security groups (ALB open on 443, the ECS task only reachable from the ALB's security group)
4. Terraform: `aws_appautoscaling_target`/`policy` on the ECS service (target-tracking on CPU, e.g. scale out above 70%) — a native AWS resource, no cluster-autoscaler/metrics-server equivalent to install, unlike the EKS alternative
5. CloudFront: same distribution shape as Phase 15 but simplified — the ALB origin handles both streaming and non-streaming routes natively, so the Function-URL-vs-HTTP-API path split collapses into one `/v1/*` → ALB behavior; the S3 frontend origin is reused unchanged
6. Same secrets/cache/DB choices as Phase 15 (SSM Parameter Store, Upstash Redis, Supabase Postgres) — reused, not rebuilt, since none of those choices were Lambda-specific
7. Validate on the same LocalStack Ultimate trial from Phase 15, step 7 — ECS and ALB both require Base or higher (neither is in the free Hobby tier at all, not just "more limited"), so this phase specifically depends on that trial window rather than having its own free fallback. If the trial has already lapsed by the time this phase is built, real ECS Fargate + ALB only costs ~$1/day (see Cost Profile Summary), which is cheaper than a Base subscription just to validate Terraform locally — skip LocalStack and iterate directly against real AWS in a tight `apply` → smoke-test → `destroy` loop instead
8. `terraform apply` against real AWS; run the same smoke test as Phase 15, this time confirming the SSE stream is genuinely token-by-token-shaped end-to-end with no adapter layer involved
9. Testing: same Redis/DB failure-path checks as Phase 15; a load-balancer health-check failure test (stop the task, confirm the ALB marks the target unhealthy and stops routing to it); confirm auto-scaling actually adds a second task under a synthetic CPU-heavy load test
10. Cost note: this phase's baseline (ALB ~$16–20/month **while it exists** + a small Fargate task) doesn't go to zero on `terraform destroy` the same way Phase 15 does, since the ALB has an hourly charge from the moment it's created — tear down between demos the same way, but budget for a different "leave it running" cost profile than Phase 15

### Phase 17 — CI Pipeline (Day 10, light) — Complete
**Status (2026-07-10): built** — `.github/workflows/ci.yml` with two independent jobs, `backend` and `frontend`; see `ci-pipeline-steps.md` for the full execution record, including two real gaps found building it (not anticipated by this section as originally written): `ruff` wasn't in `backend/pyproject.toml`'s `dev` extra yet, and `pytest -m "not integration"` alone still needs a real Postgres/Redis (10 failures with none running) — the actual dependency-free fast tier is `-m "not integration and not requires_db and not requires_redis"` (65/65 pass, ~5s, no services).
Deliberately minimal — lint + fast tests/build on push, nothing more. Build/push/deploy automation still lives in **Phase 18 (CD: Lambda)** and **Phase 19 (CD: ECS Fargate)** rather than here.
1. `.github/workflows/ci.yml`: triggers on push/PR to `main`; two jobs, `backend` and `frontend`, running in parallel as independent required status checks
2. `backend` job: checkout → set up Python (via `uv`) → `uv sync --extra dev --frozen` → `ruff check .` → `python -m pytest -m "not integration and not requires_db and not requires_redis"` (the dependency-free fast tier — `requires_db`/`requires_redis`-marked tests need real services this job doesn't run, so `not integration` alone isn't sufficient; see `ci-pipeline-steps.md` Gotchas)
3. `frontend` job (**added — not in this section's original scope**, which described backend-only lint+test; added since the frontend has had its own Vitest unit-test suite since Phase 7/8 and nothing was exercising it in CI): checkout → set up Node 20 → `npm ci` → `npm run lint` (eslint) → `npm test` (`vitest run`, unit tests only — `vitest.config.mts` already excludes `e2e/**`) → `npm run build` (`next build`, catches type errors and compile failures). Playwright e2e is deliberately excluded — it needs a live backend with real `OPENAI_API_KEY`/`TAVILY_API_KEY` and reachable Postgres/Redis, a materially bigger workflow than this phase's no-secrets scope
4. Verify: push a branch with a deliberate lint error and a deliberate failing test in each job, confirm both independently fail the workflow; fix both, confirm it goes green
5. Add both `backend` and `frontend` as required status checks under `main`'s branch protection rule — the workflow existing doesn't enforce anything by itself

**Design update (2026-07-11): dispatcher pattern shared by Phases 18–19 (and, later, Phase 21).** Rather than each of `cd-lambda.yml`/`cd-ecs.yml` triggering independently off `push` (deploying every target on every merge, with no way to redeploy just one), they become `workflow_call` reusable workflows invoked as separate jobs from one dispatcher, `.github/workflows/cd.yml`:
- **Dev-phase decision, same day: `cd.yml` is `workflow_dispatch`-only for now, no automatic trigger.** The original design also included a `workflow_run` trigger firing automatically once `ci.yml` succeeds on `main` (matching Phase 18/19's original always-deploy-on-merge behavior) — deferred, not dropped, since deploying on every merge removes exactly the manual control wanted during active development. `ci.yml` itself is unaffected either way — it stays `push`/`pull_request`-triggered regardless of what `cd.yml` does. Full before/after and what re-adding `workflow_run` later requires (a `guard` job, `head_sha` propagation to avoid deploying a commit CI never validated, `ci.yml`'s eventual `paths-ignore` need once Phase 21's bot commits exist) lives in `cd-dispatcher-steps.md`'s "Deferred" section — not repeated here.
- `cd.yml` triggers via `workflow_dispatch` with a required `choice` input `target: [lambda, fargate, both]`, default `both`, for on-demand redeploys (e.g. a Lambda-only hotfix that shouldn't also touch ECS). The choice list extends to `eks` (and `all`) once Phase 21's `cd-eks.yml` exists
- Each target job is gated by `if: inputs.target == 'lambda' || inputs.target == 'both'` (and the `fargate`/`eks` equivalents) — selecting `both` runs the Lambda and ECS jobs **in parallel**, not sequentially, since neither depends on the other's output or state
- **Bootstrap independence, resolving Phase 19 step 1's original open question ("revisit this if scoping later pushes toward splitting them"):** each reusable workflow provisions and assumes its **own** OIDC deploy role against its **own** Terraform state key — `cd-lambda-deploy-role`/Phase 15's state key for `cd-lambda.yml`, a separate `cd-ecs-deploy-role`/Phase 16's state key for `cd-ecs.yml` — rather than sharing one role across both targets. This extends the "deliberately independent at every layer" pattern Phase 16 already established for `infra/fargate/` vs `infra/lambda-gate/` (own ECR repo, own SSM parameters, own S3 bucket) to the one piece it hadn't reached yet: the deploy role itself. A `target: both` run therefore bootstraps/updates two fully separate sets of common resources with two independent `terraform apply`s — no shared state, so no lock contention between them

### Phase 18 — CD: Lambda (GitHub Actions) (Day 13, light)
**Decision (2026-07-07):** GitHub-Actions-driven deploys, not ArgoCD — ArgoCD is a GitOps agent that runs *inside* a Kubernetes cluster and syncs K8s manifests to it, and Phase 16 deliberately chose ECS Fargate over EKS specifically to avoid standing up a cluster at all. Bolting one on just to run ArgoCD would reopen that already-closed cost decision. A plain workflow that builds, pushes, and applies fits the same cost-driven pattern as everything else in this plan (SSM over Secrets Manager, HTTP API over REST, ECS over EKS) with zero new infrastructure.
1. New IAM: a GitHub Actions deploy role dedicated to this target (`cd-lambda-deploy-role`), trust policy restricted to this repo + branch via the GitHub OIDC provider's condition keys (`token.actions.githubusercontent.com`) — **not** long-lived AWS access-key secrets stored in GitHub, matching how every other role in Phases 15/16 is narrowly scoped rather than broadly trusted. Bootstrapped independently of Phase 19's role — see the dispatcher design note above. **Scope of "independent" here is the role only, not the provider:** the OIDC identity provider itself (`token.actions.githubusercontent.com`) is a single account-level resource, registered once and reused by every workflow in this repo — Phase 19's role trusts the same provider under its own trust-policy condition keys, it doesn't register a second one (see `cd-lambda-deploy-steps.md`'s Prerequisites)
2. Workflow (`.github/workflows/cd-lambda.yml`), a `workflow_call` reusable workflow invoked as a job from `cd.yml` when `target` is `lambda` or `both`: checkout → assume the deploy role via OIDC → build the Lambda-Web-Adapter image → push to ECR under a commit-sha tag
3. Deploy: default path is `aws lambda update-function-code` (fast, image-only changes — the common case); fall back to a full `terraform apply` when the change touches infra, not just the image. Decide the trigger for which path runs (e.g. path-filter on `infra/**`) when actually building this
4. Smoke check: `curl` `/health` through the live CloudFront URL post-deploy; fail the workflow (and leave the previous image live) if it doesn't return healthy
5. IAM scope for the deploy role: ECR push actions + `lambda:UpdateFunctionCode` (+ Terraform's usual state/resource permissions if that path is taken) — no broader than Phase 15's own operator-permissions list
6. Verify the dispatcher's target selection actually isolates targets: run `cd.yml` manually with `target: lambda` and confirm the ECS job is skipped (not just fast-failed) in the Actions UI; then run with `target: both` and confirm both jobs execute in parallel

### Phase 19 — CD: ECS Fargate (GitHub Actions) (Day 13, light)
Same shape as Phase 18, targeting Phase 16's non-adapter image and task definition instead, invoked as the other half of the same `cd.yml` dispatcher.
1. A **separate** GitHub Actions deploy role (`cd-ecs-deploy-role`), independently bootstrapped from Phase 18's rather than reused — per the dispatcher design note above, this is the resolution of this step's original open question — with ECS-specific permissions (`ecs:UpdateService`, `ecs:DescribeServices`) instead of Lambda's
2. Workflow (`.github/workflows/cd-ecs.yml`), a `workflow_call` reusable workflow invoked as a job from `cd.yml` when `target` is `fargate` or `both`, running in parallel with the Lambda job when both are selected: build the non-adapter image, push to ECR under a commit-sha tag
3. Deploy: default path is `aws ecs update-service --force-new-deployment` (fast, image-only changes); fall back to `terraform apply` bumping the task definition's image tag when infra itself changes
4. Wait for service stability (`aws ecs wait services-stable`) before running the same `/health` smoke check as Phase 18 through the live CloudFront URL — don't declare success just because the deploy command returned

### Phase 20 — AWS Container Deployment: EKS (Kubernetes), Terraform via LocalStack first (Day 14–15)
**Decision (2026-07-09):** additive, not a replacement for Phase 16 — Phase 16's cost-driven ECS-Fargate choice stands untouched; this phase exists specifically to get real Kubernetes/Helm/ArgoCD experience, now that LocalStack Ultimate (already active for Phases 15–16) also emulates EKS. The Key Design Decisions row for Phase 16 explicitly flagged "revisit as EKS specifically if the goal becomes learn Kubernetes rather than cheapest second deployment target" as the condition under which this would happen — that's the condition now met.

1. Terraform: `aws_eks_cluster` + its IAM role, plus an OIDC provider (`aws_iam_openid_connect_provider`) for IRSA (IAM Roles for Service Accounts) — pods get scoped IAM permissions (e.g. `ssm:GetParameter`) per-`ServiceAccount`, not inherited from every pod on the node, matching this plan's existing narrow-IAM-scoping pattern (see Key Design Decisions: OIDC deploy role, not access keys)
2. Terraform: one `aws_eks_node_group` (managed, on-demand, smallest general-purpose instance type, desired size 1–2) in the same VPC as Phases 15–16, reusing the public-subnet/no-NAT pattern — EKS worker nodes only need outbound access to Supabase/Upstash/OpenAI/Tavily/ECR, same as Phase 16's Fargate tasks. One EKS-specific networking wrinkle Phase 16 didn't have: subnets must be tagged (`kubernetes.io/cluster/<name> = shared`, plus `kubernetes.io/role/elb = 1` on whichever subnet should host load balancers) for the control plane and the AWS Load Balancer Controller to discover them — easy to miss since neither Lambda nor plain ECS/ALB Terraform needed it
3. Helm chart at `gitops/multi-agent/` (repo root, see New Project Structure) — one chart, `values.yaml`-driven, templating a backend `Deployment`+`Service`, readiness/liveness probes on `/health`, resource requests/limits sized for the node group's small instance type. Default to still serving the frontend from Phase 15/16's existing S3+CloudFront rather than also containerizing it — moving the frontend into-cluster isn't itself a Kubernetes-learning goal, just extra surface; revisit only if the frontend specifically needs to live in-cluster later
4. Helm chart dependency: the **AWS Load Balancer Controller** (installed via its own Helm chart, not this app's) — watches `Ingress` resources and provisions a real ALB, the Kubernetes-native equivalent of Phase 16's Terraform-managed `aws_lb`. An `Ingress` resource under `gitops/multi-agent/templates/` replaces Phase 16's hand-written ALB target group
5. Same secrets/cache/DB choices as Phases 15–16 (SSM Parameter Store via an IRSA-scoped `ServiceAccount`, Upstash Redis, Supabase Postgres) — reused, not rebuilt
6. Autoscaling: a `HorizontalPodAutoscaler` on CPU (the Kubernetes-native equivalent of Phase 16's `aws_appautoscaling_target`) for pod count — the thing Phase 16's own note explicitly said ECS doesn't need an equivalent of, since there's no cluster-autoscaler-shaped gap in ECS
7. Validate on the same LocalStack Ultimate trial as Phases 15–16, **flagged as the least-mature emulation of the three** — LocalStack's EKS support stands up a real local cluster and represents it through the mocked EKS API, rather than emulating a real AWS control plane the way Lambda/API Gateway do. Expect to hit undocumented gaps hands-on, the same way Phase 15 found CloudFront Functions silently not executing and a hardcoded 30s origin timeout — budget time for this rather than assuming `terraform apply` + `helm install` behaves identically to real EKS. If the trial has lapsed, real EKS costs the same flat ~$0.10/hr control-plane fee whether idle or not (see Cost Profile Summary), so validate directly against real AWS in a tight loop instead of paying for Base just to test Terraform locally
8. `terraform apply` (cluster + node group + IRSA) against real AWS, then `helm install` the chart; run the same manual smoke test as Phases 15–16 against the ALB/CloudFront URL
9. Testing: `kubectl get pods` shows both the backend `Deployment` and its pods `Ready`; a synthetic load test confirms the HPA actually adds a pod; same Redis/DB failure-path checks as Phases 15–16. **Failure-path**: `kubectl delete pod` on a running backend pod and confirm the `Deployment` replaces it and the `Service` stops routing to it mid-replacement — the same reliability guarantee Phase 16's ALB-health-check test proved for ECS, now proved for Kubernetes's own reconciliation loop instead
10. Cost note: EKS's control plane is a flat ~$0.10/hr (~$73/month) **whether or not anything is running** — unlike every other phase in this plan, `terraform destroy` between demos isn't just "recommended" here, it's the only way this phase doesn't quietly cost more than Phases 15+16 combined over a month. Node-group EC2 cost is additional on top and destroys the same way as Phase 16's Fargate task

### Phase 21 — CD: EKS via ArgoCD (GitOps) (Day 15, light)
**Decision (2026-07-09):** the one place in this plan where the Phase 18/19 "GitHub-Actions-driven, not ArgoCD" decision is deliberately revisited, not overridden — that decision's own stated reason was "ArgoCD needs a cluster, and Phase 16 chose ECS specifically to avoid needing one." Phase 20 already stood up a cluster for its own (learn-Kubernetes) reasons, so the blocking condition no longer holds for *this* deploy target specifically. Phases 18–19 (Lambda/ECS) are untouched and still deploy via direct GitHub-Actions `update-function-code`/`update-service` calls — this phase only adds a third, GitOps-style path for the EKS target.

1. Install ArgoCD into the Phase 20 cluster via its own Helm chart; access the UI via `kubectl port-forward` for demo purposes — no public Ingress for ArgoCD itself, matching this plan's existing pattern of skipping anything not needed to prove the concept (e.g. no custom domain in Phases 15–16)
2. One ArgoCD `Application` resource, pointing at `gitops/multi-agent/` in **this same repo** (not a separate GitOps repo — kept in-repo since this is a single-developer project with one deploy target per environment, the same reasoning that already keeps Phase 17's CI workflow in this repo rather than a separate one), `targetRevision: main`, automated sync policy (`prune: true`, `selfHeal: true`)
3. **The actual GitOps distinction from Phases 18–19, and the reason this phase exists:** `.github/workflows/cd-eks.yml` never touches the cluster directly. It builds and pushes the image to ECR under a commit-sha tag, then commits an updated image tag into `gitops/multi-agent/values.yaml` on `main` (a bot commit using the default `GITHUB_TOKEN` with `contents: write`, scoped to this repo only — no new PAT needed). ArgoCD's own reconciliation loop, already running in-cluster and watching that path, detects the Git diff and applies it; the GitHub Actions job ends at the commit, not at the deploy
4. IAM: node-group/IRSA permissions unchanged from Phase 20; the GitHub Actions role for this workflow needs only ECR push + this-repo content-write — notably **not** any `eks:*` or `kubectl`-equivalent AWS permission at all, which is the clearest evidence the deploy step itself has moved out of CI and into the cluster
5. **Slots into the Phase 18/19 dispatcher** (see the design note before Phase 18): `cd-eks.yml` becomes a third `workflow_call` reusable workflow invoked from `cd.yml` when `target` is `eks` or `both`/`all`, gated the same way as the Lambda/ECS jobs. It needs no separate bootstrap step to match Phase 18/19's "own OIDC role" pattern — it was already using its own minimal, non-deploy-scoped credentials (ECR push + repo content-write) before the dispatcher existed, so independence here was already the default rather than something to add
6. Testing: push a commit, confirm the workflow updates `values.yaml`, confirm ArgoCD's UI (or `argocd app get`) shows `OutOfSync` → `Syncing` → `Synced`/`Healthy` with no manual `kubectl apply`, then run the same smoke test as Phase 20 against the now-updated pods. **Failure-path**: commit a deliberately broken image tag and confirm ArgoCD reports the `Application` as `Degraded` while the previous, still-healthy pods keep serving traffic (the rollout doesn't complete, so nothing user-facing goes down) — the GitOps-specific version of this plan's "failure-path test required in every phase" convention (see Key Design Decisions)

---

## Cost Profile Summary (Phases 15–16, 20)

| | Phase 15 (Serverless) | Phase 16 (ECS Fargate) | Phase 20 (EKS) |
|---|---|---|---|
| Baseline cost at rest (deployed, no traffic) | ~$0 — everything pay-per-use or within a free tier | ALB hourly charge, roughly $16–20/month even at zero traffic | Control-plane flat fee, ~$73/month, **plus** node-group EC2 cost and an ALB — the highest at-rest baseline of the three, by design (Kubernetes control plane isn't pay-per-use like Lambda or per-task like Fargate) |
| Compute cost under light traffic | Pay-per-invocation, likely still $0 within Lambda's perpetual free tier (1M requests + 400,000 GB-s/month) | Pay-per-second for the running Fargate task — small, but non-zero even when idle | Pay for the node group's EC2 instance(s) continuously, independent of pod-level traffic — a node runs whether or not pods on it are busy |
| Biggest avoidable cost in either phase | NAT Gateway — avoided by keeping Lambda out of a VPC entirely (Upstash + Supabase are both public HTTPS endpoints) | NAT Gateway — avoided by using public subnets + an Internet Gateway instead of private subnets + NAT for the Fargate task | Same NAT Gateway avoidance as Phase 16 (public subnets + IGW for node group egress) — the control-plane fee itself has no avoidance, it's the fixed cost of choosing EKS at all |
| Recommended between-demo state | `terraform destroy` — genuinely $0 when torn down | `terraform destroy` — also $0 when torn down, just less "leave it running casually" friendly given the ALB's hourly charge | `terraform destroy` is **not optional** the way it is for Phases 15–16 — the control-plane fee accrues whether or not you're using it, more than either other phase combined |

*Figures are ballpark, current as of this planning pass (2026-07-03, Phase 20 row added 2026-07-09) — check current AWS/Upstash pricing pages before relying on them for a real budget.*

**Funding note (2026-07-11):** Phase 20/21 (EKS) is funded off a paid AWS account with a $200 promotional credit, not the standard AWS Free Tier — the EKS control-plane fee (~$0.10/hr) is billed from cluster creation regardless of tier, it's not part of Free Tier at all. At an all-in rate of roughly $0.15–0.20/hr (control plane + node-group EC2 + ALB), $200 covers on the order of 1,000+ hours if left running continuously — but this plan's own convention (Phase 20 step 10: `terraform destroy` between demos, not optional the way it is for Phases 15–16) keeps actual usage to a handful of hours per apply → test → destroy cycle. The credit comfortably funds the full Phase 20/21 build-and-verify pass many times over under that discipline; it stops being comfortable only if the cluster is left running continuously for days.

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| `chat_sessions.id` = LangGraph `thread_id` | Single UUID serves both layers; no mapping table needed |
| `AsyncPostgresSaver` per request | Thin wrapper; connection pool is the singleton on `app.state` |
| SHA-256 hash refresh tokens in DB | DB row cannot be used to replay the token if DB is leaked |
| SSE over WebSockets | Unidirectional stream, simpler, HTTP/1.1 compatible, auto-reconnects |
| Keep sync nodes (no async conversion) | LangGraph `ainvoke` handles `run_in_executor` automatically; refactor risk not worth it |
| `ZREMRANGEBYRANK 0 -6` for 5-session eviction | Keeps 5 highest-scored (most recent) members atomically |
| Inline LangChain Hub prompt | Eliminates live network call at every import/cold start |
| `bcrypt` directly, not `passlib` | `passlib` unmaintained since 2020, incompatible with `bcrypt>=4.0` which `chromadb` already requires |
| Langfuse Cloud replaces LangSmith | Single observability tool for both request tracing and RAGAS eval scoring; avoids double-instrumentation |
| OTel/Grafana Cloud kept separate from Langfuse, correlated via `X-Request-ID` | Langfuse stays scoped to LLM/chain-level detail; OTel covers general app/DB/cache/audit — each tool used for what it's good at, without double-instrumenting LangChain calls |
| `config.py` (pydantic-settings) for all *new* code; Phase 1–4 `os.getenv` calls left as-is | Fail-fast config validation at startup for everything going forward, without churning already-completed and already-tested modules |
| Redis-down *fallback decision* lives in Phase 6 routers; `cache/sessions.py` only normalizes the error | `cache/sessions.py` catches `RedisError` and raises `CacheUnavailableError` (Phase 4 retrofit) so no raw redis-py exception ever escapes, but still doesn't decide what to do about it — the router already has the "on cache miss, query DB" path, so catching `CacheUnavailableError` there reuses it for free |
| Separate, stricter IP-based rate limit on `/v1/auth/login` + `/v1/auth/register` | Phase 12's general limiter is keyed by authenticated user ID, which doesn't exist yet on these routes — the actual brute-force/credential-stuffing target needs its own bucket |
| Full-stack Dockerization (backend + frontend + Redis) as its own Phase 10, right after the frontend exists (Phase 8) and before Test Hardening | Gives a one-command local run (`docker compose up --build`) as a deliberate checkpoint before any future enterprise-grade deployment pass — validates the app runs outside dev-server-with-hot-reload conditions while the app is still small, rather than discovering containerization issues only once deploying for real |
| Postgres stays on Supabase (not containerized) even in the Phase 10 Docker Compose stack | Already a managed connection string; running a second local Postgres would risk schema drift against the tables `setup/db_setup.md` provisions manually |
| `/v1` prefix on all API routes from the start | Trivial to add now, breaking/painful to retrofit once any client depends on unversioned paths |
| Frontend built in Phases 7–8, right after the API exists, not last | Phases 9–14 (eval, Docker, tests, hardening, observability) plus the later CI/CD phases (17–19) are backend-quality work that don't change the API contract — building the UI early surfaces real contract issues while cheap to fix, and gets the app to a usable end-to-end state sooner |
| Frontend split into Phase 7 (auth) and Phase 8 (chat UI) | Token lifecycle (login/register/silent-refresh/route-guard) and the chat experience (sessions, streaming, message history) are different problems with different failure modes — worth their own build-and-test pass each rather than one large phase |
| Frontend: access token in memory, refresh token in `localStorage` | The chosen pattern (direct Bearer-token fetches to FastAPI, no BFF/httpOnly-cookie proxy) needs the refresh token to survive a page reload, or every reload would force re-login; accepted XSS-exposure tradeoff on the refresh token is mitigated by the existing short access-token TTL + Redis revocation check (Phase 3) |
| Frontend SSE via `fetch` + `ReadableStream`, not `EventSource` | `EventSource` cannot send custom headers, so it can't carry the `Authorization: Bearer` token this app's auth design requires |
| LangGraph node failures: bounded retry then graceful degrade, never crash (Phase 5) | Audit found zero exception handling anywhere in `nodes/*`/`chains/*`/`graph.py` — an OpenAI/Tavily/Chroma hiccup currently crashes the whole run; a transient-error retry plus a degraded-but-complete answer is strictly better than a crash for something this externally-dependent |
| Revocation-check Redis failure: fail open, not closed (Phase 3 retrofit) | JWT signature + expiry is the primary security control; the revocation check is defense-in-depth for the narrower logged-out-but-unexpired case — rejecting every authenticated request during a transient Redis blip is worse than a brief best-effort window on revocation enforcement |
| Root + route-level `error.tsx` boundaries, plus explicit try/catch in `lib/api.ts`/`lib/sse.ts` | Next.js error boundaries only catch render-phase crashes, not event-handler or async errors — which is most of what a chat app's API/SSE code actually does — so boundaries alone are not sufficient and both are needed |
| Failure-path test required in every phase's testing step, not just happy-path | Matches the resilience principle itself — untested error handling isn't trustworthy error handling; audit found the existing suite (Phases 1–4) was happy-path-only for every one of these failure modes |
| API Gateway **HTTP API** (v2), not REST API, for all non-streaming routes (Phase 15) | Roughly a third of the per-request cost, simpler Lambda-proxy wiring; nothing in this app needs REST-API-only features (usage plans, request validation models) |
| **AWS Lambda Web Adapter**, not Mangum, to run the backend on Lambda (Phase 15) | Mangum buffers the full ASGI response before returning it — incompatible with `StreamingResponse`/SSE. The adapter runs the real `uvicorn` process and proxies to it, so `run_api.py` needs zero code changes and streaming works exactly as it does locally |
| **Lambda Function URL** (`RESPONSE_STREAM`) for chat routes, HTTP API for everything else (Phase 15) | Function URLs aren't subject to API Gateway's 29s integration timeout or response buffering — both real risks for a multi-LLM-call CRAG pipeline with retries; the rest of the API is fast enough that the cheaper HTTP API path is fine |
| **Upstash Redis** (external, HTTP-based), not ElastiCache, for Phases 15–16 | Real free tier vs. ElastiCache's no-free-tier hourly node cost; also removes the only reason Lambda would need a VPC at all, since Upstash and the existing Supabase pooler are both public HTTPS endpoints — skipping the VPC skips a NAT Gateway (~$32/month), the single biggest avoidable cost in either deployment phase |
| **SSM Parameter Store**, not Secrets Manager, for deployed secrets (Phases 15–16) | Standard-tier parameters are free; Secrets Manager charges per secret per month — meaningful at 5+ secrets for a project with no revenue to offset it |
| Frontend as a Next.js **static export** to S3, not an SSR Lambda/OpenNext (Phase 15) | `AuthProvider`'s route guard is already client-side (in-memory token, React context) — no server component is actually needed, so a static export avoids a whole extra piece of serverless-Next.js tooling |
| **ECS Fargate**, not EKS, for Phase 16 (cost-driven swap from the original plan) | EKS's control plane costs a flat ~$0.10/hr (~$73/month) regardless of usage, on top of node/pod compute; ECS has no control-plane fee. Also removes Phase 15's entire SSE/timeout workaround, since a long-lived Fargate container streams natively behind a plain ALB. Revisit as EKS specifically if the goal becomes "learn Kubernetes" rather than "cheapest second deployment target" |
| Public subnets + Internet Gateway, not private subnets + NAT Gateway, for Fargate tasks (Phase 16) | A NAT Gateway (~$32/month) is one of the largest fixed AWS costs at this scale; a Fargate task only needs outbound access to Supabase/Upstash/OpenAI/Tavily, which a public IP + IGW route satisfies without one, at the (accepted, security-group-mitigated) cost of the task having a direct public IP |
| GitHub-Actions-driven CD via OIDC role assumption, not ArgoCD, for Phases 18–19 | ArgoCD requires a Kubernetes cluster to sync into; Phase 16 deliberately chose ECS Fargate over EKS to avoid that exact cost, so standing up a cluster just to run ArgoCD would reopen an already-closed decision. A plain build→push→apply workflow needs no new infrastructure and matches every other cost-driven choice in this plan |
| EKS added as Phase 20, **alongside** Phase 16's ECS Fargate rather than replacing it | Phase 16's cost-driven reasoning still holds for "cheapest second deployment target" — Phase 20 exists for a different goal (learn real Kubernetes/Helm/ArgoCD) now that LocalStack Ultimate covers EKS emulation, so it's additive rather than a reversal |
| ArgoCD reintroduced as Phase 21, scoped to the EKS target only — Phases 18–19 keep their direct GitHub-Actions deploys | The condition that ruled out ArgoCD for Phases 18–19 ("no cluster exists") no longer holds once Phase 20 stands up EKS for its own reasons — but that condition never applied to Lambda/ECS themselves, so their deploy paths are left as-is rather than migrated |
| Phase 21's CD workflow commits an image-tag change to `gitops/values.yaml` in-repo, rather than calling `kubectl`/`helm` from CI | This is what makes it GitOps rather than "CD with extra steps" — ArgoCD's in-cluster sync loop is the only thing that ever touches the cluster, so the CI role needs no Kubernetes-facing AWS permissions at all, a stronger isolation boundary than Phases 18–19's OIDC roles (which do call `lambda:UpdateFunctionCode`/`ecs:UpdateService` directly) |
| `gitops/` Helm chart lives in this same repo, not a separate GitOps repo | Single-developer project, one deploy target per environment — a second repo would add real overhead (two remotes, two review flows) with no benefit at this scale; matches how Phase 17's CI already stays in-repo |

---

## Deferred to a Future Enterprise-Grade Pass

**Decision (2026-07-03):** Phases 1–14 above were the full scope as originally planned. **Deployment has since been given concrete shape as Phases 15–16** (AWS serverless via Lambda/API Gateway/CloudFront, then AWS containers via ECS Fargate — see those phases above) rather than staying an open-ended deferred item. The remaining items below are still real gaps for an "industry-standard production-grade" app, and are **still explicitly deferred** — revisit after Phases 1–19 are built and absorbed.

**Update (2026-07-07):** CI/CD deploy automation, previously listed as deferred here, is no longer open-ended — it's now concretely scheduled as Phase 17 (CI), Phase 18 (CD: Lambda), and Phase 19 (CD: ECS Fargate), the last two GitHub-Actions-driven via OIDC role assumption rather than ArgoCD (see the Key Design Decisions row). Still design-only, nothing built yet — but no longer an unscheduled gap, so it's dropped from the list below.

**Update (2026-07-09):** Phase 20 (EKS, additive alongside Phase 16's ECS Fargate) and Phase 21 (CD for EKS via ArgoCD/GitOps, additive alongside Phases 18–19's direct GitHub-Actions deploys) are now also concretely scheduled — see those phases above and their Key Design Decisions rows. Both are design-only, gated on nothing except Phases 15–19 being absorbed first per this doc's original ordering.

- **Password-reset flow.** Register/login/refresh/logout exist; "forgot password" doesn't. Needs a transactional email piece (e.g., Resend/SendGrid free tier) to deliver the reset link — this is why it's grouped here rather than done alongside the rest of Phase 7's auth work.
- **XSS via LLM-rendered markdown in the chat UI (Phase 8).** The CRAG pipeline pulls in web search results — untrusted content — that flows into the generated answer, which the chat UI renders. Needs the markdown renderer configured to strip/never execute raw HTML (e.g. `react-markdown` without `rehype-raw`) before this is safe to expose beyond local dev.
- **Security response headers** (CSP, `X-Content-Type-Options`, `X-Frame-Options`, HSTS) — absent from both the API and the Next.js app.
- **Secrets management beyond SSM Parameter Store.** Phases 15–16 add SSM `SecureString` parameters for deployed secrets (free, sufficient for a learning-scale deployment), but real secret **rotation**, fine-grained per-secret IAM policies, and audit-logged access — the things an actual enterprise secrets manager (Secrets Manager, Vault) adds over plain SSM — are still not in scope.
- **High availability.** Phase 16's ECS service runs at desired count 1 (called out there as a deliberate cost/availability tradeoff, not an oversight) — no multi-AZ redundancy, no auto-recovery beyond ECS restarting a crashed task, no multi-region. Phase 15's Lambda path is HA by nature of the platform, but Upstash/Supabase free tiers underneath it are still single-region.

Also flagged as optional/likely-skip even in a later pass, not just deferred: frontend error tracking (Sentry), account/session-device management UI, load testing, a dedicated staging environment, and a custom domain + ACM certificate for Phases 15–16 (currently using CloudFront's default domain to stay in the free tier).

Separately — not deferred, but **explicitly declined** by the user during the Phase 6 gap review (see `completed.md`'s 2026-07-03 "Production-grade gap review" decision) and not planned to be revisited unless that changes: dependency vulnerability scanning (Dependabot/pip-audit), metrics + alerting beyond Phase 14's traces/logs, email verification, and account lockout on repeated failed logins.
