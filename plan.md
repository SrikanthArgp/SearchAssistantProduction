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
│       └── ci.yml                 # NEW (Phase 14): lint + fast test suite on push/PR
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
│   ├── otel_client.py             # NEW (Phase 13): setup_otel(app, db_engine) — TracerProvider/LoggerProvider + OTLP exporters, auto-instruments FastAPI/SQLAlchemy/Redis
│   └── logging_config.py          # NEW (Phase 13): structlog config; injects trace_id/span_id from the active OTel span into every log line
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
└── frontend/                       # NEW (Phases 7–8): separate Next.js app (own package.json) — see Phase 7 (auth) and Phase 8 (chat UI) for full tree
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
`cache/sessions.py` (Phase 4) does **not** decide fallback behavior itself — it's a thin, raw-Redis-ops layer with no knowledge of whether a DB fallback exists for a given call. **Retrofit applied (2026-07-03)**: every function now catches `redis.exceptions.RedisError` and re-raises `cache.exceptions.CacheUnavailableError` — a normalized, library-agnostic exception, not a raw redis-py error escaping the module. The fallback *decision* still belongs one layer up, in the **Phase 6 routers** (`api/routers/sessions.py`, `api/routers/chat.py`) that call it: catch `CacheUnavailableError`, log a warning (trace-correlated, via Phase 13's logger), and fall through to the same DB query already used for a cache *miss*. This means a Redis outage degrades to DB-only reads instead of 500s.

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
    logger.exception("unhandled_exception", request_id=request.state.request_id)  # full traceback, trace-correlated via Phase 13
    return JSONResponse(status_code=500, content={"detail": "internal server error"})
```
Every error response — expected (`HTTPException`) or not — returns the same `{"detail": ...}` shape; only the unhandled case gets a full server-side traceback log.

### Auth endpoint rate limiting (separate from Phase 11's per-user limiter)
Phase 11's rate limiter is keyed by authenticated user ID — useless for `/v1/auth/login` and `/v1/auth/register`, which run *before* any identity exists and are the actual brute-force/credential-stuffing target. Same Redis `INCR`-bucket pattern, different key: `ratelimit:auth:{client_ip}`, stricter window (e.g. 10 req/min vs. the general 60 req/min), applied only to those two routes.

---

## Resilience & Crash Prevention (Backend + Frontend)

**Principle (2026-07-03):** the app must never crash outright, on either side — it should degrade gracefully (a clear error, a retry, a fallback answer) instead. This is stronger than the Phase 6 global exception handler alone. That handler already stops one bad *request* from crashing the FastAPI *process* (Starlette's exception middleware catches per-request errors regardless of whether this plan does anything extra — confirmed, not assumed). What it does **not** cover, and what nothing in this plan covered until now:

1. **LangGraph node-level failures.** A code audit of the already-built app found **zero exception handling anywhere** in `nodes/*.py`, `chains/*.py`, `graph.py`, or `main.py` — an OpenAI timeout, a Tavily outage, or a Chroma retrieval error currently crashes the whole CLI run today, and would crash the whole `app.stream()` call inside a future request (the Phase 6 handler would catch it and return a 500, but the user gets no useful answer, and the specific cause is buried in an unstructured traceback). **Addressed in Phase 5**, since that's where `graph.py` is already being touched: wrap each node's external call (LLM invoke, Tavily invoke, Chroma retrieve) in try/except with a bounded retry (`tenacity`, 2 attempts, exponential backoff) for transient errors, and a graceful degrade when retries are exhausted (e.g. `web_search` returns an empty result set so `generate` still runs on whatever documents exist, rather than raising) — no external-dependency exception should ever reach `main.py` or the API layer unhandled.
2. **`auth/dependencies.py`'s revocation check is unguarded** (Phase 3, already shipped and tested) — `is_token_revoked`'s Redis call has no try/except, so a Redis outage during authentication currently raises a raw, uncaught exception instead of a clean response. **Decision: fail open, not closed** — if Redis is unreachable, log a warning (trace-correlated, Phase 13) and allow the request through rather than rejecting it. Rationale: the JWT signature + expiry check is the primary security control; the revocation check is defense-in-depth for the narrower case of an explicitly logged-out-but-not-yet-expired token. Rejecting every authenticated request in the app because of a transient Redis blip is a worse outcome than a brief window where revocation enforcement is best-effort. This is a small, contained fix to already-completed code — see `completed.md` for whether/when it's applied.
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
        logger.warning("web_search_failed", question=state["question"])  # trace-correlated, Phase 13
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
```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pg_pool = AsyncConnectionPool(
        conninfo=settings.DATABASE_URL_PSYCOPG, min_size=2, max_size=10, open=False
    )
    await app.state.pg_pool.open()
    async with AsyncPostgresSaver(app.state.pg_pool) as saver:
        await saver.setup()   # creates checkpoint tables if not exist (idempotent)
    app.state.db_engine = create_async_engine(settings.DATABASE_URL)
    app.state.redis = aioredis.from_url(settings.REDIS_URL, decode_responses=True)
    yield
    await app.state.pg_pool.close()
    await app.state.db_engine.dispose()
    await app.state.redis.aclose()
```

`get_graph` dependency creates `AsyncPostgresSaver(request.app.state.pg_pool)` per request (cheap — pool is the singleton).

---

## Observability (Langfuse)

**Decision (2026-07-02):** use **Langfuse Cloud** for agent observability, **replacing** the LangSmith tracing this plan originally specified. One dashboard, one set of API keys, no double-instrumentation. Langfuse traces every node/chain/LLM call in the CRAG graph (routing decision, retrieval, grading, generation, hallucination/answer checks) with latency, token cost, and full input/output per step — and doubles as the dataset/scoring backend for Phase 9's RAGAS eval suite, so evals and production traces live in the same place.

Implementation note: this should be wired in as soon as `create_app()` exists (Phase 5) so every subsequent phase's manual testing is already traced — it's numbered Phase 12 below only to avoid renumbering the phases this doc (and `completed.md`, `tests/phaseN_*/`, `test_reports/phaseN_*/`) already references elsewhere.

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

# Rate limiting — auth endpoints (separate, stricter bucket from Phase 11's general per-user limiter)
RATE_LIMIT_AUTH_PER_MINUTE=10

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
ragas==0.2.*
pytest-asyncio==0.24.*
httpx==0.27.*
fakeredis==2.26.*
langfuse==3.*
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
4. `observability/langfuse_client.py`: `get_langfuse_handler()` factory; wire it into `main.py`'s `app.stream(...)` call — see [Observability](#observability-langfuse). Doing this now (not deferred to Phase 12) means every phase after this one is already traced.
5. `nodes/retrieve.py`, `nodes/web_search.py`, `nodes/generate.py`, `nodes/grade_documents.py`, `graph.py`'s `route_question`/`grade_generation_grounded_in_documents_and_question`: wrap each external call (Chroma retrieve, Tavily invoke, LLM invoke — including the retrieval/hallucination/answer graders and the router, not just generation) with a bounded `tenacity` retry (2 attempts, exponential backoff) for transient errors, and a graceful degrade on exhaustion — see the Backend pattern in [Resilience & Crash Prevention](#resilience--crash-prevention-backend--frontend). `generate()` is the one exception: it has no lower-fidelity fallback to degrade to, so it re-raises after retries are exhausted and lets `main.py`'s top-level handler report it, rather than returning a canned answer that would likely fail hallucination grading and loop.
6. Testing: `pytest chains/tests/` still passes (7/7) against the refactored `create_app()` factory and inlined prompt — regression check that extracting the factory and adding retry/degrade logic didn't change happy-path chain/node behavior. **Failure-path** (`tests/phase5_graph/test_resilience.py`, 8 tests): patches each `_call_*`/`_grade_*`/`_route_question` tenacity-wrapped helper to always raise (retries exhausted) and asserts the documented degrade — `retrieve`/`web_search` degrade to empty documents/results, `grade_documents` degrades to `web_search=True`, `route_question` defaults to `websearch`, both graders in `grade_generation_grounded_in_documents_and_question` default to `"useful"` — except `generate()`, which is asserted to propagate the exception.
7. Verify: `python main.py` runs end-to-end — both the direct-to-websearch path and the RAG path (including the RAG→partial-relevance→websearch fallback mid-graph) were run manually and produced correct answers. Langfuse trace confirmed live via the public API once real keys were added (see retrofit note above).

### Phase 6 — FastAPI Application (Day 3–5)
1. `config.py` — `Settings`/`get_settings()` (pydantic-settings); everything below reads config through it, not `os.getenv`
2. `api/schemas/` — all Pydantic models
3. `db/crud/{users,sessions,messages}.py` — plain functions wrapping the SQLAlchemy queries routers need (e.g. `get_session(db, session_id, user_id)` doing the ownership check once instead of duplicating it in `sessions.py` and `chat.py`); routers call these instead of building queries inline
4. `api/dependencies.py` — `get_db`, `get_redis`, `get_graph`, re-export `get_current_user`. `get_db`/`get_redis` catch connection errors and raise a `503 Service Unavailable` with a clear `detail` instead of letting a raw `SQLAlchemyError`/`redis.exceptions.*` surface as an opaque 500 (see [Resilience & Crash Prevention](#resilience--crash-prevention-backend--frontend))
5. `api/routers/auth.py` — register, login, refresh, logout, me (uses `db/crud/users.py`); login and register are wrapped with the IP-based auth rate limiter (see [Configuration, Error Handling & Auth Rate Limiting](#configuration-error-handling--auth-rate-limiting))
6. `api/routers/sessions.py` — CRUD with Redis-first read, DB fallback on both cache-miss and Redis connection error (uses `db/crud/sessions.py`)
7. `api/routers/chat.py` — sync invoke + SSE stream; persist messages; update Redis caches (uses `db/crud/{sessions,messages}.py`)
8. `api/error_handlers.py` — global `HTTPException`/`Exception` handlers, consistent JSON error envelope
9. `api/main.py` — lifespan, mount routers under `/v1`, register error handlers, CORS, request-ID middleware
10. Manual API smoke test:
    ```bash
    uvicorn api.main:app --reload
    curl -X POST http://localhost:8000/v1/auth/register -H "Content-Type: application/json" \
         -d '{"email":"a@b.com","username":"alice","password":"test1234"}'
    ```
11. Testing: integration tests using `httpx.AsyncClient` against a `crag_test` database — register/login/refresh/logout/me, session CRUD with ownership enforcement (user A can't read/rename/delete user B's session), chat sync-invoke and SSE-stream happy paths, and the IP-based auth rate limiter actually returning 429 past the threshold. **Failure-path**: point `get_db`/`get_redis` at an unreachable host in a test and assert a clean `503`, not a stack trace; force a node exception through `get_graph` (Phase 5's retry/degrade already handles the external-dependency case, so this specifically covers "something else still raised") and assert the Phase 6 global handler returns the consistent `{"detail": ...}` shape, not a leaked traceback

### Phase 7 — Next.js Frontend: Auth (Day 5–6)
Split from the chat UI (Phase 8) because they're genuinely different problems: this phase is entirely about getting the token lifecycle right (login, register, silent refresh, logout, route protection) with nothing to visually show for it beyond forms — worth its own phase and its own manual test pass before any chat UI complexity gets layered on top. Both together were "Phase 7 — Next.js Frontend" before this split. Separate Next.js project (own `package.json`), App Router + TypeScript + Tailwind — a `frontend/` subdirectory of this repo, not part of the Python project. Built right after the API exists and is smoke-tested — nothing in Phases 9–14 changes the API contract, so building the UI here (instead of last) surfaces real contract problems while they're still cheap to fix.

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

### Phase 10 — Test Hardening (Day 8)
Consolidates fixtures and tiering for tests that already exist from each phase's own testing step above — doesn't invent test coverage from scratch.
1. Add `chains/tests/conftest.py` with fixtures for DB, Redis, HTTP client, authenticated user
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

### Phase 11 — Production Hardening (Day 9, optional)
1. Structured logging (`structlog`): include `request_id`, `user_id`, `session_id` in every log line (baseline stdout output only — trace-correlated OTLP export to Grafana Cloud is added in Phase 13, not redone here)
2. `Dockerfile` (python:3.12-slim, uvicorn CMD)
3. `docker-compose.yml` with `app` and `redis:7` services only — Postgres is provided by Supabase, no local container needed
4. Rate limiting middleware (Redis INCR per user per minute bucket; reject at 60 req/min) — general-purpose, for authenticated endpoints. Auth endpoints already have their own stricter IP-based limiter from Phase 6.
5. `/health` endpoint with real `SELECT 1` DB check and Redis `PING`
6. Testing: hit `/health` with both dependencies up (expect 200) and again with the Redis container stopped (expect the documented degraded response, not a 500); a test that exceeds the general rate limit bucket and confirms 429

### Phase 12 — Observability (Langfuse)
> Numbered last for doc/folder consistency only — the actual wiring happens in **Phase 5, step 4** above, as soon as `create_app()` exists. This phase entry exists so `completed.md`/`tests/`/`test_reports/` have a phase slot to track it against, matching every other phase in this plan.
1. `observability/langfuse_client.py`: `get_langfuse_handler()` (done in Phase 5)
2. Wire the handler into `api/routers/chat.py`'s sync-invoke and SSE-stream paths (Phase 6), with `langfuse.propagate_attributes(trace_name=..., user_id=..., session_id=...)` so traces are filterable per user/session
3. Wire the handler into `eval/langfuse_eval.py` via `item.get_langchain_handler(...)` (Phase 9)
4. Testing: unit test that `get_langfuse_handler()` returns a `CallbackHandler` without raising when the required env vars are set — so a missing/misconfigured Langfuse key fails a fast test in CI instead of silently disabling tracing in production
5. Verify: run a few chat requests through the API, confirm traces appear in the Langfuse Cloud dashboard with correct user/session tags and per-node latency/cost breakdown

### Phase 13 — Observability (OpenTelemetry + Grafana Cloud) (Day 10)
1. Create a free Grafana Cloud stack; retrieve the OTLP gateway endpoint, instance ID, and API token; add the new env vars
2. `observability/logging_config.py`: structlog config with the trace_id/span_id injection processor, JSON renderer, bridged into stdlib `logging`
3. `observability/otel_client.py`: `setup_otel(app, db_engine)` — TracerProvider/LoggerProvider + OTLP exporters; instrument FastAPI, SQLAlchemy, Redis
4. Wire into `api/main.py` lifespan: call `setup_otel(app, app.state.db_engine)` once at startup, after the DB engine is created
5. Add structured audit log calls in `auth/dependencies.py` / `api/routers/auth.py` for login, logout, refresh, and revoked-token-rejected events
6. Correlate with Langfuse: pass the existing `X-Request-ID` (Phase 6 middleware) into both the OTel span attributes and Langfuse trace metadata
7. Testing: unit test `setup_otel()` against an in-memory `InMemorySpanExporter` (not the real OTLP endpoint) — confirms FastAPI/SQLAlchemy/Redis spans are actually created for a sample request, runs offline in CI, independent of whether Grafana Cloud is reachable
8. Verify: hit a few API endpoints, confirm nested FastAPI → SQLAlchemy → Redis spans appear in Grafana Cloud's Tempo explorer, and structured logs appear in Loki with matching `trace_id` fields (clickable through to the trace via Loki's derived fields)

### Phase 14 — CI Pipeline (Day 10, light)
Deliberately minimal — lint + fast tests on push, nothing more (no deploy target chosen, so no build/push/deploy stage).
1. `.github/workflows/ci.yml`: triggers on push/PR to `main`
2. Steps: checkout → set up Python (via `uv`) → `uv sync --extra dev` → `ruff check .` → `pytest -m "not integration"` (the fast unit tier from Phase 10; integration tests need real API keys/DB and are intentionally excluded from CI for this learning-scoped project)
3. Verify: push a branch with a deliberate lint error and a deliberate failing test, confirm both fail the workflow; fix both, confirm it goes green

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
| Separate, stricter IP-based rate limit on `/v1/auth/login` + `/v1/auth/register` | Phase 11's general limiter is keyed by authenticated user ID, which doesn't exist yet on these routes — the actual brute-force/credential-stuffing target needs its own bucket |
| `/v1` prefix on all API routes from the start | Trivial to add now, breaking/painful to retrofit once any client depends on unversioned paths |
| Frontend built in Phases 7–8, right after the API exists, not last | Phases 9–14 are backend-quality work (eval, tests, hardening, observability, CI) that don't change the API contract — building the UI early surfaces real contract issues while cheap to fix, and gets the app to a usable end-to-end state sooner |
| Frontend split into Phase 7 (auth) and Phase 8 (chat UI) | Token lifecycle (login/register/silent-refresh/route-guard) and the chat experience (sessions, streaming, message history) are different problems with different failure modes — worth their own build-and-test pass each rather than one large phase |
| Frontend: access token in memory, refresh token in `localStorage` | The chosen pattern (direct Bearer-token fetches to FastAPI, no BFF/httpOnly-cookie proxy) needs the refresh token to survive a page reload, or every reload would force re-login; accepted XSS-exposure tradeoff on the refresh token is mitigated by the existing short access-token TTL + Redis revocation check (Phase 3) |
| Frontend SSE via `fetch` + `ReadableStream`, not `EventSource` | `EventSource` cannot send custom headers, so it can't carry the `Authorization: Bearer` token this app's auth design requires |
| LangGraph node failures: bounded retry then graceful degrade, never crash (Phase 5) | Audit found zero exception handling anywhere in `nodes/*`/`chains/*`/`graph.py` — an OpenAI/Tavily/Chroma hiccup currently crashes the whole run; a transient-error retry plus a degraded-but-complete answer is strictly better than a crash for something this externally-dependent |
| Revocation-check Redis failure: fail open, not closed (Phase 3 retrofit) | JWT signature + expiry is the primary security control; the revocation check is defense-in-depth for the narrower logged-out-but-unexpired case — rejecting every authenticated request during a transient Redis blip is worse than a brief best-effort window on revocation enforcement |
| Root + route-level `error.tsx` boundaries, plus explicit try/catch in `lib/api.ts`/`lib/sse.ts` | Next.js error boundaries only catch render-phase crashes, not event-handler or async errors — which is most of what a chat app's API/SSE code actually does — so boundaries alone are not sufficient and both are needed |
| Failure-path test required in every phase's testing step, not just happy-path | Matches the resilience principle itself — untested error handling isn't trustworthy error handling; audit found the existing suite (Phases 1–4) was happy-path-only for every one of these failure modes |

---

## Deferred to a Future Enterprise-Grade Pass

**Decision (2026-07-03):** Phases 1–14 above are the full scope for now. The items below were identified during planning as real gaps for an "industry-standard production-grade" app, but are **explicitly deferred** — revisit only after Phases 1–14 are built and absorbed, as a deliberate follow-up pass to take the app "one level higher" toward enterprise-grade. Not scheduled, not numbered as a phase yet.

- **Deployment.** Everything through Phase 14 runs on `localhost` (`uvicorn --reload`, `npm run dev`, Docker Compose for local Redis only). No public URL, no TLS, no real cross-origin `CORS_ORIGINS`/`NEXT_PUBLIC_API_BASE_URL` values. Likely shape when revisited: Vercel for the Next.js frontend, Render/Fly.io/Railway (or similar) for the FastAPI backend, both free-tier to start.
- **Password-reset flow.** Register/login/refresh/logout exist; "forgot password" doesn't. Needs a transactional email piece (e.g., Resend/SendGrid free tier) to deliver the reset link — this is why it's grouped with deployment rather than done alongside the rest of Phase 7's auth work.
- **XSS via LLM-rendered markdown in the chat UI (Phase 8).** The CRAG pipeline pulls in web search results — untrusted content — that flows into the generated answer, which the chat UI renders. Needs the markdown renderer configured to strip/never execute raw HTML (e.g. `react-markdown` without `rehype-raw`) before this is safe to expose beyond local dev.
- **Security response headers** (CSP, `X-Content-Type-Options`, `X-Frame-Options`, HSTS) — absent from both the API and the Next.js app.
- **Secrets management** beyond `.env` files (e.g. a real secrets manager) — fine for local/learning use, a gap once anything is actually deployed.

Also flagged as optional/likely-skip even in a later pass, not just deferred: frontend error tracking (Sentry), account/session-device management UI, load testing, a dedicated staging environment.
