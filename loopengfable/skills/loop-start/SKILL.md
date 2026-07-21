---
name: loop-start
description: Open a new contracted loop — write its *.loop.md spec (goal, invariant, iterate, verify, evidence, stop, budget, escalation) and have it audited before any implementation begins. Use when starting any bounded unit of work worth more than an hour, before writing code for it.
---

# loop-start

Opens a loop by writing its contract first. The honesty mechanism: the stop
condition and budget get written while you still know nothing about how hard
the work is — before sunk cost exists to negotiate with.

## Steps

1. Pick the loop template from `loopengfable/loopspecs/` that matches the
   work (`feature-build`, `clean-slate-verify`, `pipeline-automation`,
   `dual-target-parity`, `incident-rca`, `teardown-rebuild`) — or write a
   fresh spec in `LOOPSPEC-FORMAT.md`'s schema if none fits.
2. Instantiate it: fill all eight frontmatter fields for *this* piece of
   work. No field may be "TBD" — a TBD budget is no budget, a TBD stop
   condition is goalpost drift pre-authorized.
3. Set `nests_in` honestly. If this loop's green will be used as evidence by
   an outer loop, name the outer loop — and accept that this loop's evidence
   only buys an *attempt* at the outer one, never its result.
4. Spawn `subagents/stop-condition-auditor.md` on the spec. Apply its
   rewrites or explicitly record why not. Do not begin iterating with a
   failed audit outstanding.
5. Add the loop's entry to the forward-state file (`plan.md` or equivalent)
   so a future session can find the contract.
6. Begin iterating.

## When not to use

Trivial or single-step work. A loopspec for a typo fix is ceremony, and
ceremony is how disciplines get abandoned — reserve contracts for work where
an unhonest "done" could actually cost something.
