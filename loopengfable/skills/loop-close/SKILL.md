---
name: loop-close
description: Close a contracted loop — check the stop condition verbatim against evidence artifacts, record as-built deviations, settle all gap enforcement decisions, and update the backward-state file in the same sitting. Use when a loop's stop condition appears to be met, or when its budget escalation ends it early.
---

# loop-close

Two legitimate ways in: the stop condition is met, or the budget escalation
ended the loop with the user's decision. There is no third way; "we're
basically done" is goalpost drift at the finish line.

## Steps

1. **Re-read the spec's `stop:` line verbatim** — from the file, not from
   memory. Memory of a stop condition reliably relaxes toward whatever the
   current state happens to satisfy.
2. **Match it against evidence artifacts** of the type the spec's
   `evidence:` line demands. A claimed close with no artifact of the named
   type is not closeable — go produce the artifact or reopen the loop.
3. **Apply admissibility Test 3 retroactively** (see
   `loopengfable/stop-conditions/admissibility-rules.md`): was the
   verify-step ever observed red during this loop? If it was green from the
   first iteration and never wavered, inject one deliberate failure to prove
   the check can fail before trusting it — the cost is minutes; the
   alternative is the always-green smoke check that missed a dead domain.
4. **Record deviations.** Everything the as-built differs from the spec's
   original intent, listed explicitly — the model is `completed.md`'s real
   Phase 20 entry (four confirmed deviations, each with its reason). An
   unrecorded deviation is a trap for the next session's assumptions.
5. **Settle gap debt (constraint C8).** Every gap captured during this loop
   must have its enforcement decision made — HOOK (and the hook *written
   now*), AGENT (checklist updated now), or DOC (accepted risk, reason
   stated). A loop may not close with a decided-HOOK gap whose hook doesn't
   exist yet; that exact state is how a three-incident bug stays a
   three-incident bug.
6. **Update the backward-state file** (`completed.md` or equivalent) in this
   same sitting: what was built, what evidence closed it, the deviation
   list, the gap list. Same-sitting matters — deferred documentation is how
   loop state and reality diverge between sessions.
7. If this loop `nests_in` a parent: note that the parent is now *eligible*
   for its own verify-step. Do not mark the parent progressed — eligibility
   is all that inner evidence buys.
