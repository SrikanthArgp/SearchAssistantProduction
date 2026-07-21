---
name: loop-check
description: Mid-loop health check — budget consumed, state actually changing between iterations, invariant still intact, gap-capture debt zero. Use every few iterations inside a contracted loop, and immediately whenever two consecutive iterations produce identical observable results.
---

# loop-check

The pulse-taking skill. Its most important output is the spinning
determination, because a spinning agent and a progressing agent look
identical from inside the work.

## Steps

1. **Count.** Iterations consumed vs. the spec's budget. Past budget →
   go directly to the escalation clause; do not take "one more attempt"
   first. (The attempt after the budget is exactly the one the contract
   exists to prevent taking silently.)
2. **Diff the last two iterations' observable results.** Identical results
   from different attempts is the spinning signature, and it means *the
   factor being varied is not the cause*. This project's canonical case:
   three different push credentials failing with the identical error —
   because the true cause (checkout's leftover auth header) was constant
   across all three. On detection: stop varying, list what has been
   constant across every attempt, and investigate those instead.
3. **Check the invariant.** Re-read the spec's `invariant:` line and ask
   whether the last few iterations honored it — this is where "just this
   once I'll run the step by hand" gets caught while it's still one
   violation instead of a rotted loop.
4. **Check gap-capture debt.** Any surprise from recent iterations not yet
   captured via `skills/gap-capture/SKILL.md`? Capture now, while the error
   text is still in the terminal. Debt compounds into folklore.
5. **Verify state-change is real, not cosmetic.** A wrong-target loop can
   *feel* busy while touching nothing — this project's bootstrap
   "hang" was iterations against a silently wrong Terraform workspace,
   observably changing nothing. If effort is high and observable diff is
   nil, suspect the environment/target before the code.
