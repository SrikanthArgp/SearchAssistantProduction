# Phase → Loop Type Mapping

This project's real 21 phases (`plan.md`/`completed.md`), reclassified by which
loop type (see `loops/loop-catalog.md`) they actually exercised. Most phases are a
single **build-loop** followed by a **verify-loop**; the AWS phases layer a
**deploy-loop** and, from Phase 18 on, an **incident-loop** on top.

| Phase | What it built | Loop type(s) | Notes |
|---|---|---|---|
| 1 — Infrastructure | Repo/project scaffolding | build | — |
| 2 — Database Layer | Postgres/SQLAlchemy | build → verify | — |
| 3 — Auth Layer | JWT auth | build → verify | — |
| 4 — Cache Layer | Redis | build → verify | Windows `ProactorEventLoop`/psycopg async gap found (`completed.md`) |
| 5 — Graph Refactoring | `create_app(checkpointer)` factory | build → verify | — |
| 6 — FastAPI Application | REST API around the graph | build → verify | — |
| 7/8 — Next.js Frontend | Auth UI, chat UI | build → verify | — |
| 9 — Evaluation Suite | RAGAS/Langfuse eval | build → verify | Stop condition = passing 25-item baseline run |
| 10 — Dockerization | Full-stack `docker-compose` | build → verify | Next.js-in-Docker `HOSTNAME`-binding bug found |
| 11 — Test Hardening | Fixture de-dup, unit/integration split | build | — |
| 12 — Production Hardening | structlog, rate limiter, real `/health` | build → verify | — |
| 13 — Langfuse tagging | trace metadata | build → verify | `propagate_attributes` doesn't survive LangGraph's thread pool — found via verify loop |
| 14 — OTel/Grafana Cloud | tracing | build → verify | Degrades gracefully if OTLP env vars absent |
| 15 — Lambda/API GW/CloudFront | AWS serverless | build (Stage A) → deploy+verify (Stage B, LocalStack) → deploy+verify (Stage C, real AWS) | First appearance of the LocalStack→real-AWS two-stage pattern this whole mapping is built around |
| 16 — ECS Fargate | AWS containers | build → deploy+verify (Stage A/B LocalStack) → deploy+verify (Stage C real AWS) | Deliberately independent of `infra/lambda-gate/` at every layer |
| 17 — CI Pipeline | `.github/workflows/ci.yml` | build → verify | Verified via a deliberate-failure run, not just a passing one |
| 18 — CD: Lambda | `cd-lambda.yml` | deploy-loop → incident-loop (LocalStack) → incident-loop (real AWS) | 9 gaps (LocalStack) + 11 gaps (real AWS Stage C) found and fixed |
| 19 — CD: ECS Fargate | `cd-ecs.yml` | deploy-loop → incident-loop (LocalStack) → incident-loop (real AWS) | 4 gaps found in real-AWS Stage C |
| 20 — EKS | `infra/eks/`, ALB, CloudFront | build → deploy+verify → **destroy → rebuild → re-verify** | Only phase with a full destroy/rebuild cycle within itself; surfaced the `-target` dependency-closure gap (IGW/route table not pulled in) |
| 21 — ArgoCD/GitOps | `cd-eks.yml`, ArgoCD `Application` | deploy-loop → incident-loop | Stale-CloudFront-origin-after-new-ALB gap; `GITHUB_TOKEN` `http.extraheader` credential gap |

## Reading the pattern

Every phase from 15 onward is really **two or three nested loops**, not one:

```
build-loop  (make it work, cheapest environment)
   └─► deploy-loop (LocalStack: prove the automation, not just the feature)
          └─► incident-loop (find and fix every real gap LocalStack surfaces)
                 └─► deploy-loop (real AWS: prove fidelity)
                        └─► incident-loop (find and fix every real-AWS-only gap)
```

Phase 20 additionally nested a **destroy/rebuild loop** inside its own verify
pass — a stronger form of "verify from a clean slate" than any earlier phase
attempted, and it's the only phase that caught a Terraform `-target`
dependency-closure bug as a result. Retrospectively, this suggests the
destroy/rebuild loop should have been a standing part of every infra phase's
stop condition, not something that happened to occur once.
