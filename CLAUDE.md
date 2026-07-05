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
│   ├── .chroma/           # persisted Chroma DB (gitignored)
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

Before running the graph for the first time, populate the Chroma vector store by uncommenting the `Chroma.from_documents(...)` block in `multi_agent/ingestion.py` and running it once. After the store is built, re-comment that block so subsequent runs use the persisted `multi_agent/.chroma/` directory.

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

- `plan.md` — full target design: new folder structure, schema, API endpoints, phase-by-phase migration order (Phases 1–15), plus a follow-on enterprise-grade AWS deployment pass (Phases 16–17, design-only, not scheduled until 1–15 are absorbed)
  - Phases 1–9 are already **built and tested**, including the Next.js frontend split across Phase 7 (auth) and Phase 8 (chat UI), and the Phase 9 RAGAS/Langfuse eval suite under `backend/eval/` with a passing baseline run recorded in `completed.md`; Phases 10–15 (full-stack Dockerization in Phase 10, test hardening, production hardening, Langfuse/OTel observability bookkeeping, CI) are still design-only in `plan.md`, not present in the current code
  - Phases 16–17 (AWS serverless via Lambda/API Gateway/CloudFront, then AWS containers via ECS Fargate — swapped in for an originally-planned EKS, for cost) are the enterprise-grade deployment pass; see `plan.md`'s "Deferred to a Future Enterprise-Grade Pass" section and Cost Profile Summary table
- `completed.md` — what's actually done vs. still pending, updated after every phase, including real issues hit along the way (e.g. Windows `ProactorEventLoop` incompatibility with psycopg async, `passlib`/`bcrypt` version conflict) and why each was resolved the way it was

As of this writing: Phases 1–6 (Infrastructure, Database Layer, Auth Layer, Cache Layer, Graph Refactoring, FastAPI Application) are complete and tested — see `test_reports/` (one report per phase, human-readable, functionality-first) for what's actually verified. `multi_agent/graph.py` exposes a `create_app(checkpointer)` factory (Phase 5) and is wired into a full REST API under `api/` — `config.py`, `api/schemas/`, `db/crud/`, `api/dependencies.py`, `api/routers/{auth,sessions,chat}.py`, `api/error_handlers.py`, `api/main.py` (Phase 6). Run it locally with `python run_api.py`, **not** `uvicorn api.main:app` directly — see that file's docstring for why the two aren't equivalent on Windows. All of the above lives under `backend/`, with the graph itself further isolated under `backend/multi_agent/` — see "Repository layout" above. Phases 7–8 (the Next.js frontend, under `frontend/` at the repo root, split across auth and chat UI) are also complete and tested — see `completed.md`'s Phase 7/8 entries. Phase 9 (the RAGAS/Langfuse evaluation suite, under `backend/eval/`) is also complete, with a passing 25-item baseline run recorded — see `completed.md`'s Phase 9 entry. Phases 10–15 (full-stack Dockerization on local Docker Desktop, test hardening, production hardening, Langfuse/OTel observability bookkeeping, CI) are still design-only in `plan.md`.
