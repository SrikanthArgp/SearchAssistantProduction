# Loop Catalog

The recurring loop types this project actually ran, named so they can be
referenced consistently elsewhere in `loopeng/`. Each has a distinct stop
condition (see `01-methodology/stop-conditions.md`) and a distinct failure mode
if collapsed into a different loop type.

## build-loop
**Purpose:** make a feature work once, in the cheapest environment.
**Typical actor:** the main session, or a `phase-builder`-style execution pass.
**Failure mode if skipped/rushed:** none by itself — this is the cheap loop. The
failure mode is treating its completion as if it were a verify-loop's.

## verify-loop
**Purpose:** make a feature work repeatedly, from a clean/reset state, with
falsifiable evidence.
**Typical actor:** `subagents/phase-verifier.md` — deliberately not the same
context that did the build, to avoid rubber-stamping.
**Failure mode if collapsed into build-loop:** "looks done" gets recorded as
"is done." This project's own `completed.md` shows this never fully happened
(every phase has a real verification note), but the *gap between* build and
verify narrowed dangerously in a few early phases (4, 13) where a real bug
(Windows `ProactorEventLoop`, `propagate_attributes` not surviving LangGraph's
thread pool) was only caught because verification happened to be thorough that
day, not because it was structurally guaranteed.

## deploy-loop
**Purpose:** prove the *automation* produces the running system, not that a
human following a runbook can.
**Typical actor:** the actual CD workflow (`cd-lambda.yml`, `cd-ecs.yml`,
`cd-eks.yml`), dispatched for real, not a hand-run equivalent of its steps.
**Failure mode if collapsed into build-loop:** exactly the failure
`feedback-no-manual-scripts-for-cicd-testing` exists to prevent — a green run
that only proves a script works, not that the pipeline does.

## incident-loop
**Purpose:** take one concrete failure (a real error, not a hypothetical) to a
logged root cause and a fix at the correct layer.
**Typical actor:** main session or `subagents/infra-gap-hunter.md` for
infra-specific incidents.
**Failure mode if skipped:** the fix is applied at the wrong layer (patching a
symptom) or never logged, so the same class of gap recurs — this project's MSYS
path bug recurring 3× is the concrete example of what happens when an
incident-loop's output (the fix) isn't paired with a durable enforcement
mechanism (see `constraints/standing-constraints.md`).

## dual-target loop
**Purpose:** confirm LocalStack and real AWS both pass *independently*, with
real AWS's behavior as the tiebreaker on any conflict.
**Typical actor:** the CD workflow's `environment: aws | localstack` input,
dispatched separately for each value — never inferred from one run.
**Failure mode if collapsed into a single pass:** LocalStack's looser IAM/
networking enforcement hides gaps (IAM scoping, CloudFront-OAC behavior,
`paths-filter` single-commit-diff behavior) that only real AWS enforces —
exactly what Phases 15/16/18/19's Stage C passes existed to catch.

## destroy/rebuild loop
**Purpose:** confirm the system can be built from **nothing** (empty Terraform
state), not just resumed from existing state.
**Typical actor:** main session, with `subagents/destructive-action-guard.md`
confirming the destroy is intentional before it runs.
**Failure mode if never run:** dependency-closure bugs that only manifest on a
true fresh-state apply go undetected indefinitely — this project's Phase 20
`-target` gap (IGW/route table never actually referenced by the targeted
resources, so never created) is the concrete example; every prior *resumed*
apply had silently relied on state that already had the networking in place.
