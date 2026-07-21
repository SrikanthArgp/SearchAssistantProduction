---
id: dual-target-parity
goal: The system passes on both the cheap iteration target and the target of record, independently, with the target of record authoritative on any conflict.
invariant: No change is merged that makes the cheap target pass at the cost of diverging from the target of record; differences are parameterized (env/input/variable), never forked logic.
iterate: Fix a divergence, re-run against whichever target exposed it, then re-run against the other.
verify: The same verify-step executed per-target, separately; a pass is tagged with WHICH target produced it.
evidence: Two independent evidence artifacts, one per target, from the same code revision.
stop: Both targets green on the same revision, and every known divergence is either fixed or recorded as a parameterized, justified difference.
budget: per-target budgets inherited from the nested loop (e.g. pipeline-automation's 12 dispatches each)
escalation: If the targets conflict irreconcilably, the target of record wins by rule; the cheap target's behavior is documented as a fidelity gap, never patched around in shared code.
nests_in: none (this is an outermost loop)
---

# dual-target-parity

Generalizes this project's LocalStack/real-AWS structure: iterate where it's
cheap, but *the record target defines truth* — a rule this project's user
stated explicitly (2026-07-14) after living the alternative. The measured
distance between "cheap target says yes" and "record target says yes" here
was: eleven gaps (Lambda), four gaps (Fargate) — IAM enforcement LocalStack
doesn't perform, an EC2 description-charset rejection, CloudFront-OAC
behavior, a `paths-filter` diff-scope difference. None were knowable from
the cheap target. That distance is why rule 4 of the loopspec format
(`nests_in` is one-way glass) exists: the inner pass buys an attempt at the
outer loop, never the outer result.

The invariant's "parameterized, never forked" clause matches this project's
working pattern: one workflow with an `environment: aws | localstack` input,
rather than two workflows or `if localstack:` branches scattered through
shared logic — because forked logic is how a green cheap-target run stops
telling you anything at all about the record target.
