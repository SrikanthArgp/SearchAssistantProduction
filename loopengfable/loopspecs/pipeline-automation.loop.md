---
id: pipeline-automation
goal: The pipeline itself — dispatched, not hand-assisted — takes the system from nothing to verified-running.
invariant: No pipeline step is ever performed by hand during a test of the pipeline; a failing dispatch is fixed by changing the workflow, then re-dispatching. (Sole documented exception - the one-time bootstrap prerequisite, e.g. infra/bootstrap's state bucket/lock table.)
iterate: Fix the workflow (or the infra it drives), commit, dispatch the actual workflow again.
verify: The dispatched run's own logs and its own smoke check, read end to end — not a locally reproduced equivalent.
evidence: The workflow run URL/ID and its log excerpts for the fixed step.
stop: A single dispatch, starting from no pre-provisioned resources beyond the documented bootstrap, goes green through every step including its smoke check.
budget: 12 dispatches per target environment
escalation: Stop; present the dispatch-by-dispatch gap list; ask whether to continue, descope a step, or accept a documented manual prerequisite (which then enters the invariant's exception list VISIBLY).
nests_in: dual-target-parity
---

# pipeline-automation

The invariant is the entire point of this loop, and it is the most tempting
one in this file to violate — because hand-running the failing step is
always faster *this iteration* and always costs more *in total*. A pipeline
whose test environment was pre-cooked by hand proves only that the cook can
deploy. This project learned this well enough to encode it as standing
feedback ("never manually invoke `infra/*/scripts/*.sh` while testing CD —
let the workflow perform every step"), including the sharpest sub-case: when
a fresh environment breaks the pipeline (no ECR repo exists yet), the fix is
to make *the workflow* detect and handle it, because real usage will hit the
same fresh-environment case eventually.

**Worked example:** Phases 18/19's LocalStack verification — nine real gaps
fixed across dispatches of the actual workflows via a self-hosted runner,
each dispatch a full real `terraform apply` + ECR push + deploy + smoke
check. Phase 21's variant: the bot-commit push kept failing identically
across several credential changes until the constant-across-attempts factor
was found (checkout's leftover `GITHUB_TOKEN` `http.extraheader` overriding
every embedded token). The budget-and-escalation clause exists precisely for
that shape of failure: identical results from different attempts means the
varied factor isn't the cause — escalate and hunt the constant.

The budget of 12 dispatches is calibrated from this project's real
convergence data: Lambda's real-AWS Stage C took roughly eleven gap-fix
dispatches; Fargate's took four. Past twelve, presume something constant is
wrong rather than something enumerable.
