---
name: gap-log
description: Record a real gap found during a verify/deploy/incident loop — root cause, fix, and the layer it was fixed at — in the format this project's completed.md already uses (e.g. the Phase 18/19 "9 gaps found" and Phase 15/18 Stage C "11 gaps found" entries). Use immediately when a real failure is diagnosed and fixed, before moving on to the next check.
---

# Gap Log

This project's most valuable real output has consistently been the list of
concrete gaps found while trying to close a verify/deploy/incident loop — not
the green checkmark at the end. This skill makes capturing that a required step,
not something that only happens to survive into `completed.md` because someone
remembered to write a good summary afterward.

## Steps

1. State the failure concretely: the actual error text, log line, or observed
   wrong behavior — not a paraphrase. (Example from this project's real history:
   "browser console shows a request to `file:///C:/Program Files/Git/v1/auth/
   login`" is a concrete gap statement; "the frontend build was broken" is not.)
2. State the root cause in one sentence. If you can't state it in one sentence,
   the diagnosis isn't finished yet — don't log a guess as a root cause.
3. State which layer the fix was applied at, and why that layer (not a
   different one that would have papered over it). This project's real example:
   the CloudFront-OAC-vs-JWT conflict was fixed at the *application* layer (a
   custom `X-Auth-Token` header) rather than by weakening CloudFront's OAC —
   state that kind of reasoning explicitly.
4. Classify the gap per `loopeng/constraints/standing-constraints.md`:
   - **Mechanically checkable** → note that a hook should exist or be added
     (see `loopeng/hooks/`) so this can't recur silently.
   - **Judgment-requiring** → note that the relevant subagent's checklist
     (see `loopeng/subagents/infra-gap-hunter.md`) should be updated.
5. Append the gap to the current phase's `completed.md` entry, in the same
   list-style format as the existing Phase 18/19 and Phase 15/18/16/19 Stage C
   entries — one line per gap, root cause and fix both stated, not just "fixed
   a bug."
6. If this is the **second** occurrence of the same class of gap (e.g. the MSYS
   path bug recurring across Phases 15/16/20), treat that itself as a process
   failure worth logging: a first-time gap is normal; a second occurrence means
   step 4's classification/enforcement didn't actually get followed through.
