# The Operating Model

Loop engineering treats an agentic coding project as a set of **explicitly
contracted loops** rather than a stream of tasks. Three commitments define it.

## 1. A loop is a contract, not a habit

Before any loop runs, its contract exists as a file (see
`loopspecs/LOOPSPEC-FORMAT.md`). The contract declares:

- **Goal** — what true statement about the world the loop exists to make true.
- **Invariant** — what must stay true on *every* iteration (e.g. "no manual
  script substitutes for a pipeline step"). Invariants are checked each pass,
  not once at the end.
- **Iterate-step** — the smallest action that could change the system's state
  toward the goal.
- **Verify-step** — how each iteration's effect is observed. Observation must
  produce an **evidence artifact** (a log, a URL response, a screenshot, a test
  report path) — not a feeling of confidence.
- **Stop condition** — an admissible one (see
  `stop-conditions/admissibility-rules.md`).
- **Budget + escalation** — a maximum iteration count or wall-clock bound, and
  what happens when it's hit: stop, summarize what's known, and surface to the
  user. Hitting a budget is a *normal, designed outcome*, not a failure.

## 2. Evidence outranks assertion

The unit of progress is not "the agent says it works" but "here is the
artifact that would look different if it didn't." This project's real history
is a catalog of why: a green LocalStack run asserted the CD pipeline worked;
real AWS then produced eleven distinct counter-examples (Phase 15/18 Stage C).
A smoke check asserted the CloudFront URL was healthy; it was querying the
*current* SSM value and would have passed even while every bookmarked URL on
earth was dead (the 2026-07-14 domain-rotation incident). In both cases the
assertion was sincere and wrong — only a stronger evidence requirement
distinguishes them from real verification.

## 3. Divergence is the product

The purpose of running a loop instead of a straight line is that each
iteration can *surprise* you — and every surprise (a "gap") is captured with a
root cause and an enforcement decision before the loop continues (see
`skills/gap-capture/SKILL.md`). This project generated at least 24 documented
gaps across Phases 18–21 alone; those gap lists are demonstrably more valuable
than the green checkmarks, because the checkmarks describe one moment and the
gaps describe the terrain. Loop engineering's bet is simple: make gap capture
a contractual obligation of every iteration, and the project's knowledge
compounds instead of evaporating between sessions.

## The failure taxonomy this model defends against

| Pathology | What it looks like | Which contract element prevents it |
|---|---|---|
| **Spinning** | Iterations without state change (the Phase 19 bootstrap "hang" — wrong Terraform workspace, silently hitting LocalStack endpoints forever) | Budget + escalation |
| **Goalpost drift** | Stop condition quietly reinterpreted mid-loop so the current state qualifies | Stop condition written before the loop, audited by `subagents/stop-condition-auditor.md` |
| **Proxy verification** | Verifying something adjacent to the goal (tests pass ≠ pipeline works; LocalStack ≠ AWS) | Admissibility rule 2 (`stop-conditions/admissibility-rules.md`) |
| **Invariant erosion** | "Just this once" manual workarounds that invalidate what the loop proves (hand-running `infra/*/scripts/*.sh` during a CD test) | Invariant checked per-iteration, not per-loop |
| **Amnesia** | Lessons learned in one session, relearned in another (the MSYS path bug, three times: Phases 15, 16, 20) | Gap capture with mandatory enforcement decision (`constraints/constraints.md`) |
