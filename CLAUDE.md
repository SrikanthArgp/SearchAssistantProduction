# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For human-facing "how do I run this locally and test it" steps covering both `backend/` and `frontend/` together, see the root `README.md` — this file focuses on codebase structure and conventions for Claude Code sessions.

## Repository layout

This is a monorepo: all Python backend code lives under **`backend/`**, which is its own project root — `backend/pyproject.toml`, `backend/uv.lock`, `backend/.venv`, `backend/.env`. **Every command below runs from inside `backend/`, not the repo root.** `plan.md`/`completed.md`/`CLAUDE.md` stay at the repo root since they're cross-cutting project docs (they also cover the Phase 7/8 `frontend/` work once that exists) — note that path references inside those two files predate this restructure and are written relative to the *old* flat layout, not `backend/`.

Within `backend/`, the CRAG graph itself (LangGraph state machine, chains, nodes, ingestion, agent-tracing observability) lives under **`multi_agent/`** — everything else (`api/`, `auth/`, `cache/`, `db/`, `config.py`, `run_api.py`, `tests/`) is the web/persistence layer built around it in Phases 1–6:

```
backend/
├── multi_agent/          # the agent itself — importable as `multi_agent.*`
│   ├── graph.py          # create_app(checkpointer) factory, routing/grading decisions
│   ├── state.py          # GraphState TypedDict
│   ├── consts.py         # node name constants
│   ├── nodes/            # retrieve, grade_documents, generate, web_search
│   ├── chains/           # router, retrieval_grader, generation, hallucination_grader, answer_grader
│   ├── ingestion.py       # Chroma vector store setup + retriever
│   ├── .chroma/           # persisted Chroma DB (committed to git — static corpus, see below)
│   ├── observability/     # Langfuse callback handler
│   └── main.py            # CLI entry point (MemorySaver checkpointer)
├── api/                   # FastAPI app (Phase 6) — imports from multi_agent.*
├── auth/, cache/, db/     # JWT auth, Redis cache, Postgres/SQLAlchemy (Phases 2–4)
├── eval/                   # RAGAS/Langfuse eval suite (Phase 9) — dataset.py, metrics.py, langfuse_eval.py, run_eval.py
├── config.py               # pydantic-settings
├── run_api.py               # FastAPI entry point — see its docstring for why this isn't `uvicorn api.main:app`
└── tests/                   # phase-organized test suite (multi_agent/chains/tests/ holds the graph's own chain tests)
```

## Setup

`cd backend`, then copy `.env.example` to `.env` and fill in your API keys:
- `OPENAI_API_KEY` — used by all chains and embeddings
- `TAVILY_API_KEY` — used by the web search node
- `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` / `LANGFUSE_HOST` — agent observability (Langfuse Cloud), wired into both `multi_agent/main.py` and `api/routers/chat.py`

`multi_agent/.chroma/` is committed to git (the corpus is static — see "Vector store" below), so a fresh checkout already has a working vector store; nothing needs to be built before running the graph. To re-ingest (e.g. after changing the source URLs or splitter settings), uncomment the `Chroma.from_documents(...)` block in `multi_agent/ingestion.py`, run it once, re-comment it, then commit the refreshed `multi_agent/.chroma/` directory.

## Commands

All of these run from `backend/`:

```bash
cd backend

# Run the agent end-to-end (CLI, in-memory checkpointer)
python multi_agent/main.py

# Run the FastAPI app (Phase 6) — NOT `uvicorn api.main:app` directly, see run_api.py's docstring
python run_api.py

# Run all tests (integration tests hit real LLMs/DB/Redis — require valid API keys and .env)
pytest tests/ multi_agent/chains/tests/ -m "not integration"

# Run a single test
pytest multi_agent/chains/tests/test_chains.py::test_router_to_vectorstore
```

## Architecture

This is a **Corrective RAG (CRAG)** multi-agent pipeline built with LangGraph. The graph routes questions either to a local vector store or to web search, grades retrieved documents for relevance, generates an answer, then grades the answer for hallucinations and usefulness before returning.

### Graph flow (`multi_agent/graph.py`)

```
question → route_question
              ├─► websearch → generate
              └─► retrieve → grade_documents
                                ├─► generate (all docs relevant)
                                └─► websearch → generate (some docs irrelevant)

generate → grade_generation_grounded_in_documents_and_question
              ├─► END          (useful)
              ├─► websearch    (not useful — retry with web results)
              └─► generate     (not supported — hallucination detected, retry)
```

Node constants (`RETRIEVE`, `GRADE_DOCUMENTS`, `GENERATE`, `WEBSEARCH`) are defined in `multi_agent/consts.py`.

### State (`multi_agent/state.py`)

`GraphState` is a `TypedDict` with four fields passed between every node:
- `question` — the original user question
- `documents` — list of retrieved/filtered `Document` objects
- `generation` — the LLM's answer string
- `web_search` — flag set by `grade_documents` to trigger a web search fallback

### Chains (`multi_agent/chains/`)

Each file builds a standalone LangChain runnable (prompt | LLM | parser):

| File | Purpose | Output type |
|---|---|---|
| `router.py` | Routes question to `vectorstore` or `websearch` | `RouteQuery` (structured) |
| `retrieval_grader.py` | Scores a single document for relevance | `GradeDocuments` (binary `"yes"/"no"`) |
| `generation.py` | Generates an answer from context | `str` (via `rlm/rag-prompt` from LangChain Hub) |
| `hallucination_grader.py` | Checks if generation is grounded in documents | `GradeHallucinations` (binary `bool`) |
| `answer_grader.py` | Checks if generation addresses the question | `GradeAnswer` (binary `bool`) |

All chains use `ChatOpenAI(temperature=0)` with structured output via Pydantic models where grading is required.

### Nodes (`multi_agent/nodes/`)

Thin wrappers that call the chains and return updated state slices:
- `retrieve` — queries the Chroma retriever from `multi_agent/ingestion.py`
- `grade_documents` — iterates documents through `retrieval_grader`; sets `web_search=True` if any doc is irrelevant
- `generate` — calls `generation_chain`
- `web_search` — calls `TavilySearchResults(k=3)` and appends results as a `Document`

### Vector store (`multi_agent/ingestion.py` + `multi_agent/.chroma/`)

Documents are loaded from three Lilian Weng blog posts (agents, prompt engineering, adversarial attacks), split with `RecursiveCharacterTextSplitter` (chunk size 250, no overlap), embedded with `OpenAIEmbeddings`, and stored in a local Chroma collection named `rag-chroma`. The persist directory is resolved relative to `ingestion.py`'s own file location (`Path(__file__).resolve().parent / ".chroma"`), not the process's cwd — deliberate, so it resolves correctly regardless of whether a command is run from `backend/` or `backend/multi_agent/`.

### Memory / checkpointing (`multi_agent/graph.py`)

`graph.py` exposes `create_app(checkpointer)` — a factory, not a hardcoded checkpointer. `multi_agent/main.py` (CLI) compiles it with `MemorySaver()` (in-memory, lost on restart). The FastAPI app (`api/main.py`, Phase 6) compiles it per-request with `AsyncPostgresSaver` bound to a shared `psycopg_pool.AsyncConnectionPool`, durable across restarts — `chat_sessions.id` is used directly as the LangGraph `thread_id`. Either way, queries pass `thread_id` via `config={"configurable": {"thread_id": "..."}}` for conversation-level state isolation.

## Productionization Migration (in progress)

This repo is being turned into a production REST API — JWT auth, per-user sessions, Postgres + Redis persistence, RAGAS/Langfuse evaluation. The plan, current status, and reasoning behind every deviation from it (with the "why") live in two files — **read them before touching `db/`, `auth/`, `cache/`, or adding to the plan**:

- `plan.md` — full target design: new folder structure, schema, API endpoints, phase-by-phase migration order (Phases 1–14), plus a follow-on enterprise-grade AWS deployment + CI/CD pass (Phases 15–19, design-only, not scheduled until 1–14 are absorbed), plus a further additive EKS + ArgoCD/GitOps pass (Phases 20–21, design-only, added 2026-07-09, not scheduled until 15–19 are absorbed)
  - Phases 1–14 are already **built and tested**, including the Next.js frontend split across Phase 7 (auth) and Phase 8 (chat UI), the Phase 9 RAGAS/Langfuse eval suite under `backend/eval/` with a passing baseline run recorded in `completed.md`, Phase 10's full-stack Dockerization (root `Dockerfile` + `frontend/Dockerfile` + root `docker-compose.yml`, `docker compose up --build` runs backend + frontend + Redis together), Phase 11's test-suite hardening (unit/integration tier split, de-duplicated fixtures), Phase 12's production hardening (structured logging baseline, a general per-user rate limiter, real `/health` dependency checks), Phase 13's Langfuse trace tagging (`user_id`/`session_id`/`trace_name` via LangChain config metadata), and Phase 14's OpenTelemetry/Grafana Cloud tracing (`api/otel_client.py`, general FastAPI/SQLAlchemy/Redis spans, correlated with Langfuse via `X-Request-ID`); Phase 15's Stage A (Terraform scaffolding applied against LocalStack, Lambda Web Adapter, `boto3`, SSM-aware `config.bootstrap_env()`, frontend static export) and Stage B (the Lambda/API Gateway/CloudFront/SSM Terraform apply against LocalStack — backend compute + frontend S3/CloudFront, verified end-to-end including a real browser test) are both built and verified — see `completed.md`'s Phase 15 entry; Phase 16's Stage A/B (AWS container deployment via ECS Fargate — `infra/fargate/`, deliberately independent of `infra/lambda-gate/` at every layer: own ECR repo, own SSM parameters, own S3 bucket, own scripts) is also built and verified end-to-end against LocalStack, including a real Playwright browser test against the live CloudFront URL and a manual user browser check — see `completed.md`'s Phase 16 entry and `grand-enterprize-deploy-steps.md`'s "Actually Built" section for every deviation from the original design and every real gap found (a LocalStack-only CloudFront-to-ALB port-routing bug, a relative-path bug in `infra/lambda-gate/`'s own scripts left over from the folder restructure, and recurrences of two already-known LocalStack fidelity gaps). Phase 17 (CI Pipeline, `.github/workflows/ci.yml`) is complete and merged — see `completed.md`'s Phase 17 entry. Phase 18 (CD: Lambda) and Phase 19 (CD: ECS Fargate) are both **verified end to end against LocalStack via a self-hosted GitHub Actions runner** registered on this dev machine (GitHub-hosted runners can't reach LocalStack) — `cd.yml`/`cd-lambda.yml`/`cd-ecs.yml` gained an `environment: aws | localstack` input, and both workflows ran fully green: real `terraform apply` creating both stacks from nothing, real ECR push, real Lambda/ECS deploy, real passing `/health` smoke check through each stack's own CloudFront domain. Nine real gaps were found and fixed doing this — see `completed.md`'s combined Phase 18/19 LocalStack-verification entry for the full list, including a `/health`-not-routed-through-CloudFront bug fixed in both `cloudfront.tf`s. The Chroma-vector-store-provisioning gap from that pass is now resolved (2026-07-12): since the corpus is static, `multi_agent/.chroma/` was committed to git instead of gitignored, so every checkout (including CI/CD runners) has it via the Dockerfile's normal `COPY . ./` — the LocalStack-only "seed from this dev machine" workaround step was removed from `cd-lambda.yml`/`cd-ecs.yml` as obsolete. Real AWS deploys (`environment: aws`) are untouched by any of this and still wait on their own OIDC deploy roles and Phase 15/16's Stage C — Phase 16's Stage C (real AWS) is still not started. Both stacks are currently left live on LocalStack, and the self-hosted runner is still registered — cleanup is a deliberate follow-up, not automatic
  - Phases 15–19 (AWS serverless via Lambda/API Gateway/CloudFront, then AWS containers via ECS Fargate — swapped in for an originally-planned EKS, for cost — then a CI pipeline and GitHub-Actions-driven CD for each deploy target, renumbered 2026-07-07 so CI/CD follow the targets they build against) are the enterprise-grade deployment + pipeline pass; see `plan.md`'s "Deferred to a Future Enterprise-Grade Pass" section and Cost Profile Summary table
- `completed.md` — what's actually done vs. still pending, updated after every phase, including real issues hit along the way (e.g. Windows `ProactorEventLoop` incompatibility with psycopg async, `passlib`/`bcrypt` version conflict) and why each was resolved the way it was

As of this writing: Phases 1–6 (Infrastructure, Database Layer, Auth Layer, Cache Layer, Graph Refactoring, FastAPI Application) are complete and tested — see `test_reports/` (one report per phase, human-readable, functionality-first) for what's actually verified. `multi_agent/graph.py` exposes a `create_app(checkpointer)` factory (Phase 5) and is wired into a full REST API under `api/` — `config.py`, `api/schemas/`, `db/crud/`, `api/dependencies.py`, `api/routers/{auth,sessions,chat}.py`, `api/error_handlers.py`, `api/main.py` (Phase 6). Run it locally with `python run_api.py`, **not** `uvicorn api.main:app` directly — see that file's docstring for why the two aren't equivalent on Windows. All of the above lives under `backend/`, with the graph itself further isolated under `backend/multi_agent/` — see "Repository layout" above. Phases 7–8 (the Next.js frontend, under `frontend/` at the repo root, split across auth and chat UI) are also complete and tested — see `completed.md`'s Phase 7/8 entries. Phase 9 (the RAGAS/Langfuse evaluation suite, under `backend/eval/`) is also complete, with a passing 25-item baseline run recorded — see `completed.md`'s Phase 9 entry. Phase 10 (full-stack Dockerization) is also complete — root `Dockerfile` (backend) + `frontend/Dockerfile` (multi-stage, `.next/standalone`) + root `docker-compose.yml` (backend + frontend + Redis; Postgres stays on Supabase, not containerized); `docker compose up --build` runs the whole stack, verified end-to-end including the Redis-down failure path — see `completed.md`'s Phase 10 entry, including a real Next.js-in-Docker `HOSTNAME`-binding bug found and fixed along the way. Phase 11 (test hardening) is also complete — de-duplicated `db_session`/`fake_redis`/HTTP-client fixtures now live in `tests/conftest.py`, the unit/integration marker split is accurate (no unmarked real-LLM calls in the fast tier), and `playwright.config.ts` auto-starts the backend for `npm run test:e2e` — see `completed.md`'s Phase 11 entry. Phase 12 (production hardening) is also complete — `api/logging_config.py` (structlog baseline, `request_id`/`user_id`/`session_id` bound via contextvars), `enforce_general_rate_limit` (per-user Redis bucket on the sessions/chat routers), and `/health` now runs a real `SELECT 1` + Redis `PING` — see `completed.md`'s Phase 12 entry. Phase 13 (Langfuse trace tagging) is also complete — `api/routers/chat.py`'s `_graph_config` tags every trace with `user_id`/`session_id`/`trace_name` via LangChain's `metadata` dict (not `propagate_attributes`, which doesn't survive LangGraph's thread-pool execution of this graph's sync nodes) — see `completed.md`'s Phase 13 entry. Phase 14 (OpenTelemetry + Grafana Cloud) is also complete — `api/otel_client.py`'s `setup_otel(app, db_engine)` instruments FastAPI/SQLAlchemy/Redis and exports to Grafana Cloud Tempo via OTLP (degrading to local-only spans if `GRAFANA_OTLP_INSTANCE_ID`/`GRAFANA_OTLP_TOKEN`/`OTEL_EXPORTER_OTLP_ENDPOINT` aren't configured), `api/logging_config.py` now injects `trace_id`/`span_id` into every log line from the active OTel span, and both Langfuse and OTel traces for the same request are joinable via a shared `request_id` — see `completed.md`'s Phase 14 entry. Phase 15's Stage A (AWS serverless deployment prep: `infra/` Terraform scaffolding + bootstrap applied against LocalStack, the Lambda Web Adapter in `backend/Dockerfile`, `boto3`, `config.py`'s `bootstrap_env()` SSM/`.env` switch, and the frontend's static-export build) is also complete and verified end-to-end, including a real Playwright run against a live backend and LLM — see `completed.md`'s Phase 15 entry. Phase 15's Stage B (the actual Lambda/API Gateway/CloudFront/SSM Terraform apply against LocalStack — backend compute + frontend S3/CloudFront) is also complete — CLOSED in `completed.md`, verified end-to-end against LocalStack including a real browser test. Phase 16's Stage A/B (ECS Fargate — `infra/fargate/`) is also complete and verified end-to-end against LocalStack, including a real Playwright browser test — see `completed.md`'s Phase 16 entry; built fully independent of `infra/lambda-gate/`, a deliberate deviation from the original shared-resource design (own ECR repo, own SSM parameters at `/crag/prod-ecs/*`, own S3 bucket and scripts) — see `grand-enterprize-deploy-steps.md`'s "Actually Built" section for the full list of deviations and real gaps found. **Phase 17 (CI Pipeline) is also complete** — `.github/workflows/ci.yml` (`backend` job: ruff + dependency-free fast tests; `frontend` job: eslint + Vitest + `next build`), merged via PR after a real deliberate-failure verification run — see `completed.md`'s Phase 17 entry. **Phase 18 (CD: Lambda) and Phase 19 (CD: ECS Fargate) are both verified end to end against LocalStack** (`.github/workflows/cd.yml` dispatching to `cd-lambda.yml`/`cd-ecs.yml`, plus a `deployment_circuit_breaker` addition to `infra/fargate/ecs.tf` and a `/health` CloudFront routing fix to both `cloudfront.tf`s) via a self-hosted GitHub Actions runner on this dev machine — real `terraform apply`, real ECR push, real Lambda/ECS deploy, real passing smoke check, nine real gaps found and fixed along the way — see `completed.md`'s combined Phase 18/19 LocalStack-verification entry. Real AWS runs (`environment: aws`) still wait on their own OIDC deploy roles and Phase 15/16's Stage C. Phase 16's Stage C (real AWS) is still not started.
