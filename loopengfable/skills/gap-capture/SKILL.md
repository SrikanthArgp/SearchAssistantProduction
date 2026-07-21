---
name: gap-capture
description: Capture a surprise (failure, or success-for-the-wrong-reason) the moment it's diagnosed — verbatim error, one-sentence mechanism, owning-layer fix, and a provisional enforcement class — before the loop takes its next iteration. Use immediately on diagnosis, while the error text is still in the terminal.
---

# gap-capture

The compounding mechanism of the whole framework. Gaps captured at diagnosis
time are precise; gaps reconstructed at close-time are folklore; gaps never
captured are next quarter's incidents. This project's most valuable
documented outputs — the 9/11/4-gap lists in `completed.md`'s Phase 18–19
entries — were exactly this, done as prose after the fact; this skill moves
the capture to the moment of diagnosis.

## The capture record (five lines, into the current loop's notes / the phase's backward-state entry)

1. **Signature** — the failure verbatim: exact error text, log line, or
   observed wrong behavior. Verbatim matters because signatures are how
   future sessions match a recurrence in seconds (a browser request to
   `file:///C:/Program%20Files/Git/...` *is* the MSYS bug; no further
   debugging needed — that shortcut only works if the signature was
   captured exactly).
2. **Mechanism** — root cause in one sentence. Can't state it in one
   sentence → the diagnosis isn't done; capture the signature now and mark
   mechanism pending, but don't invent one.
3. **Fix + owning layer** — what was changed, at which layer, and why that
   layer owns it (the `X-Auth-Token`-at-the-application-layer standard, not
   the weaken-the-edge shortcut).
4. **Provisional enforcement class** — HOOK / AGENT / DOC per
   `loopengfable/constraints/constraints.md`. Provisional here; settled
   finally at `loop-close` step 5. If HOOK and the script is under ~20
   lines, just write it now.
5. **Recurrence check** — is this signature, or this *class* of mechanism,
   already in the constraints index? A recurrence of a decided-but-unbuilt
   enforcement is logged as a process defect (constraint C8), separately
   from the gap itself.

## What counts as a surprise

Not just failures. A check passing for the wrong reason (the always-green
smoke check), a step succeeding that should have failed (an apply "working"
against the wrong workspace), a dependency satisfied by accident (warm
state) — all capture-worthy. The test: *did reality differ from the model
of it you were operating on?* If yes, the model needs the patch, and this
record is the patch.
