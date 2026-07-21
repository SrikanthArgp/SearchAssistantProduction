---
id: feature-build
goal: The feature works end-to-end once, exercised for real, in the cheapest environment that can exercise it.
invariant: Every claim of "works" traces to an actual run this session, not to reading the code.
iterate: Implement or fix the smallest piece that could change the observed behavior.
verify: Run it — the CLI, the endpoint, the test — and observe the actual output.
evidence: Terminal output or HTTP response captured this session.
stop: The end-to-end golden path has been observed succeeding once, by running it.
budget: 15 iterations
escalation: Stop; report which sub-piece won't converge and what's been eliminated; ask whether to descope, change approach, or extend.
nests_in: clean-slate-verify
---

# feature-build

The cheap loop. Its only discipline requirement is honesty about the
difference between "I wrote code that should do X" and "I watched X happen."
The evidence bar is deliberately low (one real run) because this loop's
output is only ever an *entry ticket* to `clean-slate-verify` — nothing
downstream trusts it.

**Worked example (this project):** each of Phases 1–14's initial build
passes. The budget of 15 is calibrated generously; most of this project's
build loops converged well under it. The one near-miss this budget exists
for: Phase 13's Langfuse tagging, where the obvious approach
(`propagate_attributes`) silently didn't survive LangGraph's thread-pool
execution of sync nodes — an iterate/verify cycle that could have spun on
variations of the same approach. The escalation forces the "is the approach
itself wrong?" question at a bounded cost.
