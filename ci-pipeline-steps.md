# Phase 17 — CI Pipeline: Step-by-Step

Scope: a deliberately minimal GitHub Actions workflow, two jobs — backend (`ruff` + the fast unit test tier) and frontend (`eslint` + Vitest unit tests + `next build`) — on every push/PR to `main`. No Playwright e2e (needs a live backend + real API keys — out of scope for a no-secrets CI job, see Gotchas), no build-and-push image, no deploy — those are Phases 18/19. Full design/rationale lives in `plan.md`'s Phase 17 section — this doc is the execution checklist plus the operational detail (workflow YAML, gotchas) the plan intentionally left out.

Status: **built** — `.github/workflows/ci.yml` exists with both jobs, verified green locally (backend: `ruff check .` clean, 65/65 fast-tier tests pass in ~5s with no services running; frontend: `eslint` clean, 32/32 Vitest tests pass, `next build` succeeds) before ever pushing. Sequenced after both AWS deploy targets (Phase 15 Lambda, Phase 16 ECS) — see `plan.md`'s 2026-07-07 renumbering decision. Companion to [`cd-dispatcher-steps.md`](./cd-dispatcher-steps.md) (design added 2026-07-11) — as of that same day, `cd.yml` is `workflow_dispatch`-only (dev-phase decision, no automatic trigger off this workflow yet; that's deferred, see the dispatcher doc's "Deferred" section), so today this workflow has **no** downstream automatic effect at all. This workflow itself is unchanged either way — still a plain `push`/`pull_request` trigger with no awareness of what (if anything) runs after it. **See "Known Follow-Up" below** for one small, not-yet-applied change this file will need if/when the automatic trigger is added back and Phase 21 (EKS) exists.

---

## Architecture Overview

```mermaid
flowchart LR
    Dev(["Developer"]) -->|push / PR to main| Trigger["GitHub Actions trigger\non: push, pull_request"]
    Trigger --> BJob["Job: backend"]
    Trigger --> FJob["Job: frontend"]

    BJob --> Checkout["Checkout code"]
    Checkout --> SetupUV["Install uv\n(astral-sh/setup-uv)"]
    SetupUV --> Sync["uv sync --extra dev --extra prod --extra eval --frozen\n(backend/, working-directory)"]
    Sync --> Lint["ruff check ."]
    Lint -->|fail| Blocked1["backend job fails"]
    Lint -->|pass| Test["python -m pytest -m \"not integration\n and not requires_db and not requires_redis\""]
    Test -->|fail| Blocked1
    Test -->|pass| BGreen["backend: success"]

    FJob --> FCheckout["Checkout code"]
    FCheckout --> SetupNode["Install Node 20\n(actions/setup-node, npm cache)"]
    SetupNode --> NpmCi["npm ci\n(frontend/, working-directory)"]
    NpmCi --> FLint["eslint"]
    FLint -->|fail| Blocked2["frontend job fails"]
    FLint -->|pass| FTest["vitest run\n(unit tests only — e2e/** excluded)"]
    FTest -->|fail| Blocked2
    FTest -->|pass| Build["next build"]
    Build -->|fail| Blocked2
    Build -->|pass| FGreen["frontend: success"]

    BGreen --> Green["Both jobs green"]
    FGreen --> Green
    Green --> Gate{"Required status checks\nset in branch protection?"}
    Gate -->|yes| Merge["Merge blocked until both green\n(actually enforced)"]
    Gate -->|no| Warn["Green checks are advisory only —\nmerge is NOT actually blocked"]
```

The two jobs run in parallel and are independent status checks — a frontend-only PR still has to wait on the backend job (and vice versa), which is deliberate: `ci.yml` is one source of truth for "is `main` safe," not two workflows a reviewer has to reconcile. The gate at the bottom is deliberately drawn as a decision, not an assumption — creating `ci.yml` makes the checks *exist*, it doesn't make them *required*. See Gotchas.

---

## Why this stays minimal

Every other phase in this plan (15, 16, 18, 19) earns its complexity from a real constraint — SSE streaming, IAM scoping, VPC networking. CI doesn't have an equivalent forcing function yet: there's no deploy stage wired to it (that's Phases 18/19), no matrix of Python or Node versions to support (single target each — Python `>=3.11`, Node 20). The frontend job is scoped the same way as the backend one — lint + the tests that already exist (Vitest, from Phases 7–8) + a build — deliberately **not** including Playwright e2e, which needs a live backend, a live LLM, and real API keys as secrets; that's a different shape of workflow than "no secrets needed" (see Gotchas for what it would take). Adding coverage reporting, dependency caching tuned beyond the default, or a lint-fix-and-commit step now would be solving problems this project doesn't have yet. Keep it to lint + test + build per job until something concrete demands more.

---

## Prerequisites

- A GitHub repo with `main` as the default branch (already true).
- Nothing else — unlike Phases 15/16, this workflow needs no AWS credentials, no LocalStack, no secrets at all in its current lint+test+build scope.

---

## Steps

1. Add `ruff` to `backend/pyproject.toml`'s `dev` extra — **it wasn't there** (verified: `dev = ["pytest>=8.0", "pytest-asyncio>=0.24", "httpx>=0.27", "fakeredis>=2.26"]`, no `ruff` entry). Ran `uv add --optional dev ruff` from `backend/`, which updated `pyproject.toml` and `uv.lock` (`ruff==0.15.21`).
2. Added a `[tool.ruff]` block: `target-version = "py311"` (matching `requires-python = ">=3.11"`) and, under `[tool.ruff.lint]`, `ignore = ["E402"]` — **a real finding, not a default**: running `ruff check .` cold surfaced 41 errors, 40 of which were `E402` (import not at top of file) concentrated in exactly the files that deliberately call `load_dotenv()` before importing modules that read env vars at import time (`multi_agent/main.py`, `multi_agent/graph.py`, `api/main.py`, `tests/conftest.py`, `eval/run_eval.py`, `multi_agent/chains/tests/test_chains.py`) — a documented pattern (see `CLAUDE.md`), not lint debt. Ignored project-wide rather than sprinkling `# noqa: E402` across six files. The 41st error (`F401`, an unused `OperationalError` import in `tests/phase12_production/test_health.py`, referenced only in a comment) was a genuine dead import — removed it. `ruff check .` is clean after both fixes.
3. **Real finding: `pytest -m "not integration"` alone is not actually dependency-free.** Running it locally with no Redis/Postgres running (the state any GitHub Actions runner starts in) produced 10 failures — `tests/phase1_infrastructure/test_redis_health.py` and `tests/phase4_cache/test_sessions_real_redis.py`, all marked `requires_redis` but *not* `integration`. `-m "not integration and not requires_db and not requires_redis"` is the actual dependency-free fast tier: 65 passed, 0 failed, ~5s, confirmed with no services running at all. Used that exact marker expression in the workflow, not the bare `not integration` this doc originally specified.
4. Create `.github/workflows/ci.yml` with two independent jobs, `backend` and `frontend` (see the full workflow below).
5. `backend` job: `defaults.run.working-directory: backend` — this repo's convention is that all commands run from `backend/`, not the repo root; see `CLAUDE.md`. Steps: checkout → install `uv` → `uv sync --extra dev --extra prod --extra eval --frozen` (all three extras, not just `dev` — see Gotchas) → `ruff check .` → `python -m pytest -m "not integration and not requires_db and not requires_redis"` (not bare `pytest` — see Gotchas).
6. `frontend` job: `defaults.run.working-directory: frontend`. Steps: checkout → `actions/setup-node@v4` (Node 20, `cache: npm`) → `npm ci` (not `npm install` — see Gotchas) → `npm run lint` (eslint) → `npm test` (`vitest run`; `vitest.config.mts` already excludes `e2e/**` from its glob, so Playwright specs aren't picked up) → `npm run build` (`next build`, default `"standalone"` output — this job proves the app compiles/type-checks, it isn't producing a deploy artifact). Verified all four steps green locally before writing the workflow: `npm run lint` clean, `npm test` → 32/32 passed, `npm run build` → compiled + typechecked + all 5 routes prerendered, no env vars needed.
7. Verify: push a branch with a deliberate lint error and a deliberate failing test in each job, confirm both jobs independently fail the workflow; fix both, confirm it goes green.
8. Go to the repo's branch protection settings for `main` and add **both** `backend` and `frontend` as **required status checks** — the workflow existing does not do this automatically (see Gotchas).

---

## GitHub Actions Workflow

The actual, committed workflow — reproduced here for reference; `.github/workflows/ci.yml` is the source of truth if the two ever drift.

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

# Cancel superseded runs on the same PR/branch instead of letting them queue.
concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  backend:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install uv
        uses: astral-sh/setup-uv@v3
        with:
          version: "latest"
          enable-cache: true
          cache-dependency-glob: "backend/uv.lock"

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Install dependencies (frozen)
        # All three extras, not just dev — see Gotchas.
        run: uv sync --extra dev --extra prod --extra eval --frozen

      - name: Lint
        run: uv run ruff check .

      - name: Fast unit test tier
        # Excludes requires_db/requires_redis too, not just integration — see Gotchas.
        run: uv run python -m pytest -m "not integration and not requires_db and not requires_redis"
        env:
          DATABASE_URL: "postgresql+psycopg://test:test@localhost:5432/test"
          DATABASE_URL_PSYCOPG: "postgresql://test:test@localhost:5432/test"
          REDIS_URL: "redis://localhost:6379/0"
          JWT_SECRET_KEY: "ci-dummy-secret-not-for-real-use"
          OPENAI_API_KEY: "sk-ci-dummy-not-a-real-key"
          TAVILY_API_KEY: "tvly-ci-dummy-not-a-real-key"

  frontend:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: frontend
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"
          cache-dependency-path: frontend/package-lock.json

      - name: Install dependencies
        run: npm ci

      - name: Lint
        run: npm run lint

      - name: Unit tests
        run: npm test

      - name: Build
        run: npm run build
```

---

## Known Follow-Up (not yet applied)

**This section describes a possible future change to the already-built `ci.yml`, not something this phase's original build missed** — flagging it now so it isn't lost, since the need for it only became clear when the Phase 18/19/21 dispatcher design (`cd-dispatcher-steps.md`) was added on 2026-07-11, well after this phase shipped. **This is conditional on two things both being true when Phase 21 is actually built**, so check `cd-dispatcher-steps.md`'s current state before assuming it applies:

1. [Phase 21 (`cd-eks.yml`)](./ci-cd-eks-steps.md) exists, **and**
2. `cd.yml` has an automatic `workflow_run`-off-`ci.yml` trigger — which, as of this writing, it deliberately does **not**: `cd.yml` is `workflow_dispatch`-only for the dev phase (see `cd-dispatcher-steps.md`'s "Why manual-only" and "Deferred" sections). If `cd.yml` is still manual-only when Phase 21 is built, this follow-up does not apply yet — a bot commit re-triggering `ci.yml` is harmless when nothing downstream fires automatically from `ci.yml` succeeding.

If both conditions hold: `ci.yml` needs `paths-ignore: ['gitops/multi-agent/**']` added to its `push` trigger. Reasoning: under the dispatcher design, `cd-lambda.yml`/`cd-ecs.yml`/`cd-eks.yml` are all `workflow_call`-only — the *only* thing that can trigger any of them is `cd.yml`. If `cd.yml` is `workflow_run`-triggered off `ci.yml`, that makes `ci.yml`'s `push` trigger the **sole entry point** for the entire CD chain, not just for CI. Phase 21's bot commit (patching `gitops/multi-agent/values.yaml`) pushes to `main` just like any other commit — without the filter, that push re-triggers `ci.yml`, which re-triggers `cd.yml`, which redeploys *every* configured target (Lambda, ECS, and EKS again) in response to a commit that only ever needed to update one YAML field. Before the dispatcher design, this loop-prevention filter lived directly on `cd-eks.yml`'s own (now-removed) `push` trigger — see `ci-cd-eks-steps.md`'s Gotchas for the full before/after. Do not add this filter to `ci.yml` before both conditions hold; there's nothing yet that would push to `gitops/multi-agent/**`, and an unused path filter is just a place for the actual glob to drift from reality.

---

## Gotchas

- **`OPENAI_API_KEY`/`TAVILY_API_KEY` are also required for collection, not just the four `config.py` fields — found on the third real PR run.** `multi_agent/chains/*.py` (`generation.py`, `retrieval_grader.py`, `router.py`, `answer_grader.py`, `hallucination_grader.py`) all instantiate `ChatOpenAI(temperature=0)` at **module import time**, not lazily — `langchain_openai`'s `validate_environment` constructs a real `openai.OpenAI()` client eagerly in `__init__`, which raises `OpenAIError` immediately if `OPENAI_API_KEY` isn't set, before any test runs and without making a network call. `multi_agent/nodes/web_search.py`'s module-level `TavilySearchResults(k=3)` has the identical pattern — its `api_wrapper` field's `default_factory` constructs a `TavilySearchAPIWrapper`, whose `tavily_api_key: SecretStr` field has an eager `validate_environment` validator reading `TAVILY_API_KEY` (confirmed by reading `langchain_community`'s source directly, not guessed). Both are on the same `tests/conftest.py` → `api.dependencies` → `multi_agent.graph` import chain as `db/base.py`'s `DATABASE_URL` read, so every fast-tier test pays this cost at collection even if it never touches a chain. Fixed with dummy values (`sk-ci-dummy-not-a-real-key` / `tvly-ci-dummy-not-a-real-key`) — neither needs to be a real key, since construction is all that happens, never an actual API call.
  - **This one exposed a real flaw in "verify locally by renaming `.env` away": it didn't actually simulate a no-`.env` environment.** `python-dotenv`'s `load_dotenv()` (called with no args in `tests/conftest.py`) walks **upward from the calling module's directory** when no path is given, not just checking `backend/.env` — and it found and loaded an unrelated, pre-existing `.env` file two directories above the repo root (`Langgraph-Projects/.env`, a stray file from a sibling project on this machine, not part of this repo), which happened to define `OPENAI_API_KEY`. That masked this exact failure through two local "verified" runs, even with `backend/.env` renamed aside — the earlier `DATABASE_URL`/extras fixes were verified correctly because the stray file didn't affect *those* variables, but this one slipped through. Corrected verification method: rename `backend/.env` aside **and create an empty `backend/.env` in its place** (a `touch`, zero content) — `find_dotenv()` stops at the first `.env` it finds regardless of content, so an empty one blocks the upward walk from ever reaching the stray file, actually reproducing what a fresh CI checkout sees. Confirmed both ways: reproduced the CI failure locally with the empty-`.env` technique first (proving the technique itself was sound), then confirmed the fix resolves it (65/65 pass).

- **The dummy `DATABASE_URL` must use `+psycopg`, not `+asyncpg` — found on the second real PR run, after the extras fix above.** `db/base.py`'s `create_async_engine()` (imported transitively via `tests/conftest.py` → `api.dependencies` → `auth.dependencies` → `db.base`) uses SQLAlchemy's psycopg3 async dialect — `asyncpg` isn't a project dependency at all. A `postgresql+asyncpg://...` dummy URL (this doc's original value, never actually run against a `.env`-less environment before this phase) fails at *import* time with `ModuleNotFoundError: No module named 'asyncpg'`, before any test even runs — it doesn't need a reachable DB to fail, just the URL scheme parsed by SQLAlchemy's dialect loader. Fixed to `postgresql+psycopg://test:test@localhost:5432/test`. **Verified by properly simulating a no-`.env` CI environment locally**, not just by reasoning about it: temporarily renamed `backend/.env` aside, exported the four dummy env vars in the shell, ran the exact fast-tier command — 65/65 passed — then restored `.env`. A local run with `.env` present would never have caught this, since `python-dotenv`'s `load_dotenv()` doesn't override already-set env vars, but also doesn't get a chance to set `DATABASE_URL` at all if it's already correct from the real `.env` — the bug only surfaces when nothing but the dummy value is available, which is exactly CI's situation.

- **`uv sync --extra dev --frozen` alone is not enough to even collect the fast tier — found on the first real PR run, not caught locally.** The first push of this workflow failed `backend` in 16s with `ModuleNotFoundError: No module named 'langgraph.checkpoint.postgres'`: `tests/conftest.py` imports `api.dependencies`, which imports `langgraph.checkpoint.postgres.aio` — a `prod`-extra package, not `dev`. It passed locally first because the local `.venv` already had `prod`/`eval` synced from earlier phases (`completed.md`'s Environment Reference: `uv sync --extra dev --extra prod --extra eval`), masking the gap. Reproduced the CI failure locally with `uv sync --extra dev --extra prod --frozen` (drops `eval`) → next failure, `ModuleNotFoundError: No module named 'ragas'`, from `tests/phase9_eval/test_dataset_and_metrics.py` needing `ragas` at collection time. `uv sync --extra dev --extra prod --extra eval --frozen` is what the fast tier actually needs — confirmed by running the full command fresh: 65/65 pass. **Lesson for verifying this kind of thing going forward**: a local pass with an already-populated `.venv` doesn't prove a clean-install command is sufficient; re-running the exact sync command CI uses (extras and all) against the same venv is what actually catches this class of gap before pushing.

- **`pytest -m "not integration"` alone is not the dependency-free fast tier — confirmed by actually running it with no services up.** `test_redis_health.py` and `test_sessions_real_redis.py` are marked `requires_redis` only, not `integration`, and both need a real Redis connection — with no Redis running (the default state of a GitHub Actions runner, dummy `REDIS_URL` notwithstanding) they fail with `redis.exceptions.ConnectionError`, 10 failures total. The workflow uses `-m "not integration and not requires_db and not requires_redis"` — verified locally to pass 65/65 in ~5s with zero services running. If a future test adds `requires_db`/`requires_redis` without excluding it the same way, it'll pass locally (real Postgres/Redis available) and fail in CI, looking like a flaky CI environment when it's actually a marker mismatch.

- **`ruff` wasn't installed** — `backend/pyproject.toml`'s `dev` extra didn't include it before this phase (verified by reading the file, not assumed). Now added via `uv add --optional dev ruff` (`ruff==0.15.21`), with `[tool.ruff.lint] ignore = ["E402"]` — see Steps above for why: 40 of 41 cold-run errors were `E402` from the deliberate `load_dotenv()`-before-import pattern, not real issues.

- **Bare `pytest` fails in this workflow the same way it fails locally on Windows — for a different, cross-platform reason.** `completed.md`'s Phase 11 entry documents that the bare `pytest` console-script does not add the current working directory to `sys.path` (no `pythonpath` set in `[tool.pytest.ini_options]`, no root `conftest.py`), so `pytest tests/ ... -m "..."` fails collection with `ModuleNotFoundError` for first-party imports (`config`, `api`, `multi_agent`, ...). `python -m pytest` does add cwd to `sys.path` and is the form that actually works — and this isn't Windows-specific, it's how Python's `-m` flag behaves everywhere, so `ubuntu-latest` runners hit the exact same failure if the workflow uses bare `pytest`/`uv run pytest`. Use `uv run python -m pytest`, matching `CLAUDE.md`'s own documented local command.

- **`Settings()` may construct eagerly during test collection, not just at real app startup.** `config.py`'s `Settings` has four fields with no default: `database_url`, `database_url_psycopg`, `redis_url`, `jwt_secret_key` — a missing one raises a `pydantic.ValidationError` at construction time. Locally this is masked by `tests/conftest.py`'s `load_dotenv()` reading a real `backend/.env`; CI has no `.env` file at all, and `load_dotenv()` silently no-ops if the file doesn't exist rather than erroring. The dummy env vars in the workflow cover this.

- **Registered `pytest` markers avoid a red herring.** `backend/pyproject.toml`'s `[tool.pytest.ini_options]` already registers `integration`, `requires_db`, and `requires_redis` as markers — so the `-m` expression above won't emit `PytestUnknownMarkWarning`. If a future test adds a new marker without registering it here, that warning becomes noise in CI logs that's easy to mistake for a real problem; keep marker registration and marker usage in sync.

- **`npm ci`, not `npm install`, for the frontend job** — same reasoning as `uv sync --frozen`: `npm ci` fails if `package-lock.json` is out of sync with `package.json` instead of silently re-resolving and installing different versions than what's committed, and it's meaningfully faster on a clean runner (no dependency resolution, just installs exactly what the lockfile pins).

- **Playwright e2e is deliberately not in this workflow.** `frontend/playwright.config.ts` auto-starts the backend for local `npm run test:e2e` (Phase 11), but that backend needs real `OPENAI_API_KEY`/`TAVILY_API_KEY` (the CRAG graph makes real LLM/search calls) plus reachable Postgres/Redis — a materially bigger workflow (secrets, service containers or LocalStack, browser install) than this phase's no-secrets scope. `npm test` (`vitest run`) already excludes `e2e/**` via `vitest.config.mts`'s glob, so this is enforced by config, not just convention — e2e specs can't accidentally leak into the CI job.

- **`ci.yml` existing does not enforce anything by itself.** GitHub only blocks a merge on a failing/missing check if that check is explicitly added as a **required status check** under the repo's branch protection rules for `main` (Settings → Branches → Branch protection rule) — and with two jobs now, both `backend` and `frontend` need to be added separately; adding only one leaves the other job's red X purely informational. Skipping this step means the green/red indicator doesn't actually block anything. This is the most common way a freshly-added CI workflow quietly does nothing.

- **`uv sync --frozen` vs plain `uv sync`.** `--frozen` fails the sync (and the whole job) if `uv.lock` is out of sync with `pyproject.toml`, instead of silently re-resolving and writing a new lock file inside the ephemeral runner. Without it, a stale committed lock file can pass CI while actually installing different versions than what's pinned — defeating the point of committing `uv.lock` at all. Always use `--frozen` in CI; never in local dev (there you *want* `uv sync` to update the lock).

- **Concurrency cancellation is a convenience, not a correctness requirement, for this workflow specifically** — since neither job does anything but lint+test+build (no shared external state, no deploy), a canceled stale run can't leave anything partially applied. This is *not* true for Phases 18/19's CD workflows, where cancel-in-progress needs much more care (see those docs' Gotchas) — don't copy this workflow's `concurrency` block there unmodified.
