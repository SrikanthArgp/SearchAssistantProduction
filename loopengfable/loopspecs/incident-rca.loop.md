---
id: incident-rca
goal: One concrete failure is reduced to a one-sentence root cause, fixed at the layer that owns the problem, and converted into a permanent defense.
invariant: No fix is applied whose mechanism of action can't be stated; "this made the error go away" is not a mechanism.
iterate: Form one hypothesis, design the cheapest observation that would distinguish it from its rivals, observe.
verify: The observation's actual output, compared against what each live hypothesis predicted.
evidence: The distinguishing observation (log line, command output, config dump) that eliminated or confirmed a hypothesis.
stop: Root cause stated in one sentence; fix applied at the owning layer; failure re-run and observed NOT recurring; gap captured with an enforcement decision (skills/gap-capture).
budget: 6 hypothesis cycles
escalation: Stop; present the hypothesis ledger (eliminated, surviving, untested) to the user; identical failures across supposedly-different attempts get flagged explicitly as "the varied factor is not the cause."
nests_in: whatever loop surfaced the incident
---

# incident-rca

Two clauses distinguish this from ordinary debugging:

**The owning-layer clause.** A fix belongs at the layer whose contract was
violated, even when a different layer offers a quicker patch. This project's
exemplar: CloudFront's OAC conflicted with the app's JWT `Authorization`
handling — the fix went into the *application* (a custom `X-Auth-Token`
header) rather than weakening the edge's security posture, because the edge
was doing its job correctly. The anti-exemplar this clause bans: granting
`iam:*` because some narrower permission was missing.

**The hypothesis-ledger escalation.** The single highest-leverage diagnostic
rule this project's history teaches: *when different attempts fail
identically, the thing you're varying is not the cause.* Phase 21's
credential debugging varied the token three times (fine-grained →
+Administration → classic full-repo) against an identical failure — the
answer was a constant (checkout's leftover `http.extraheader` authenticating
every push as `GITHUB_TOKEN` regardless of the embedded credential). Phase
21's other case: the "bootstrap hang" was a wrong-workspace constant
misread as slowness. The ledger format forces constants into view because
eliminated hypotheses accumulate in writing instead of being re-tried.

**Worked examples at smaller scale:** the MSYS path-mangling signature
(`file:///C:/Program%20Files/Git/...` in a browser console) — once captured
here with its one-sentence root cause (MSYS argv conversion treats any
leading-`/` argument as a POSIX path), the *diagnosis* step of any
recurrence is free; the enforcement decision (a hook) makes recurrence
itself impossible. That's this loop's full pipeline: failure → mechanism →
owning-layer fix → permanent defense.
