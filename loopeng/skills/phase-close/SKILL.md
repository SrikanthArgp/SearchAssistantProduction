---
name: phase-close
description: Close out a project phase — verifies the stop condition was actually met with checkable evidence, then updates completed.md in the same sitting (not as a deferred follow-up). Use when a phase's implementation and verification are both finished and need to be recorded as done.
---

# Phase Close

Formalizes the rule from `loopeng/01-methodology/loop-engineering-approach.md`
step 10: "done" means "documented as done, including every gap found getting
there," recorded in the same sitting as verification — not queued as a
follow-up task that quietly goes stale.

## Steps

1. Re-read the phase's stop condition from `plan.md` (written by
   `phase-scaffold`, or found retroactively if the phase predates that skill).
2. Confirm the stop condition was met with **checkable evidence** — a URL that
   was actually curled, a test report that was actually run, a browser flow
   that was actually clicked through. If the only evidence is "the code looks
   correct," the phase is not done — return to the verify-loop.
3. If real gaps were found and fixed while getting to the stop condition,
   confirm each one has been logged via `skills/gap-log/SKILL.md` first — a
   phase-close should never be the first place a gap is mentioned.
4. Update the `completed.md` entry for this phase:
   - What was actually built (may differ from `plan.md`'s original scope —
     record deviations explicitly, the way this project's actual `completed.md`
     entries do, e.g. Phase 20's four confirmed deviations from its design doc).
   - What verified it (the concrete evidence from step 2).
   - Every gap found and fixed (cross-reference `skills/gap-log/SKILL.md`
     entries).
5. If closing this phase revealed a constraint that should apply to earlier or
   later phases too, add it to `loopeng/constraints/standing-constraints.md`
   and classify it (mechanical → write the hook; judgment → update the
   relevant subagent's checklist) before considering the phase fully closed.
6. Only after 1–5: mark the phase done. Do not mark a phase done and leave the
   `completed.md` update as a "TODO, will update later" — that gap is exactly
   how loop state drifts from reality between sessions.
