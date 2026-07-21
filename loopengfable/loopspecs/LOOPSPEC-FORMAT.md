# Loopspec Format

A loopspec is the contract for one loop, written **before the loop runs**.
One file per loop instance, named `<slug>.loop.md`, YAML frontmatter plus a
short body. The frontmatter is deliberately terse — it's the checkable part.
The body carries reasoning.

## Schema

```yaml
---
id: <kebab-case-slug>            # stable reference for gap logs and close-out entries
goal: <one sentence>             # the statement this loop exists to make true
invariant: <one sentence>        # what must hold on EVERY iteration (checked per-pass)
iterate: <one sentence>          # the smallest state-changing action
verify: <one sentence>           # how each iteration is observed
evidence: <artifact type>        # what the verify-step must produce (URL response, log, report path, screenshot)
stop: <one sentence>             # admissible per stop-conditions/admissibility-rules.md
budget: <N iterations | duration> # hard bound
escalation: <one sentence>       # what happens at the budget (always involves the user)
nests_in: <parent loop id | none> # inner evidence NEVER satisfies the parent's stop
---
```

## Rules

1. **Written before entry.** A loopspec created after iteration 3 is a
   rationalization, not a contract. If scope genuinely changes mid-loop,
   edit the spec *visibly* (the diff is the record) and re-audit it.
2. **Audited before entry.** `subagents/stop-condition-auditor.md` reviews
   the spec — chiefly the `stop:` and `evidence:` lines — before the first
   iteration.
3. **The `evidence:` line is load-bearing.** If the verify-step doesn't
   produce the named artifact type, the iteration doesn't count as verified,
   no matter how confident the run felt.
4. **`nests_in` is one-way glass.** A child loop closing contributes nothing
   to the parent's stop condition except eligibility to attempt the parent's
   own verify-step. (LocalStack green → you may now dispatch against real
   AWS; it proves nothing about real AWS.)
5. **Budgets are estimates, escalations are promises.** Getting the budget
   wrong is expected and fine. Skipping the escalation when it's hit is the
   only way to actually break the contract.

## Instances in this folder

Six loopspecs, each a generalization of a loop this project actually ran —
written as *reusable templates* with this project's real run as the worked
example in the body:

| File | Generalizes | This project's real instance |
|---|---|---|
| `feature-build.loop.md` | make it work once, cheaply | Phases 1–14, each |
| `clean-slate-verify.loop.md` | works repeatedly from reset state | every phase's verification pass |
| `pipeline-automation.loop.md` | the automation does it, not hands | Phases 18/19/21 CD workflows |
| `dual-target-parity.loop.md` | cheap target and target-of-record both pass, record wins | LocalStack vs. real AWS, Phases 15–21 |
| `incident-rca.loop.md` | one failure → one root cause → fix at owning layer | all 24+ documented gaps |
| `teardown-rebuild.loop.md` | from-nothing rebuild reproduces the verified state | Phase 20's destroy/rebuild |
```
