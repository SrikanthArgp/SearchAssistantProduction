# Stop Conditions Catalog

A stop condition is falsifiable if a skeptical reader could check it against
concrete evidence (a URL response, a log line, a test report, a screenshot) without
trusting the agent's self-report. "Should be working" is not a stop condition.
"Tests pass" is a weak one (tests can mock away the exact thing that's broken —
this project's own `feedback-no-manual-scripts-for-cicd-testing` memory is
precisely about a class of false-positive verification). The conditions below are
written at the strength this project's later phases actually converged on.

## Per loop type (see `loops/loop-catalog.md` for the loop definitions)

### build-loop
Stop when: the feature works end-to-end **once**, exercised by hand, in the
cheapest available environment (local dev server, LocalStack, unit tests).
Explicitly *not* a stop condition: "the code looks right," "it should compile,"
or any claim not backed by actually running it.

### verify-loop
Stop when: the feature works **repeatedly**, from a **clean/reset state**, with
evidence a third party could check:
- A real HTTP response (`curl` / browser network tab), not just "the route exists."
- A real browser test (Playwright or manual) exercising the actual golden path —
  this project's standard from Phase 15 onward: "login/logout/session-list/
  chat-history/chat-send all work end-to-end against the live stack."
- For eval-type work (Phase 9): a recorded baseline metric run, not just "the
  harness runs without crashing."

### deploy-loop
Stop when: the automation itself — not a hand-run script — produced the running
system, from nothing. This project's explicit rule
(`feedback-no-manual-scripts-for-cicd-testing`): if `infra/*/scripts/*.sh` had to
be run by hand to get the CD workflow to pass, the loop has not actually closed —
it's proven a script works, not that the pipeline does. The one standing
exception is `infra/bootstrap/` (shared state bucket/lock table), which is
documented as a legitimate manual one-time prerequisite in real usage too.

### incident-loop
Stop when: (1) the specific failure is reproduced with a concrete error/log, (2)
the root cause is stated in one sentence, (3) the fix is applied at the layer
that actually owns the problem (this project's own example: the CloudFront-OAC-
vs-app-JWT-auth conflict was fixed at the *application* level via a custom
`X-Auth-Token` header, not by weakening CloudFront's OAC), and (4) the gap and
fix are logged (`skills/gap-log/SKILL.md`) before moving on. A patched symptom
without a logged root cause does not close the loop.

### dual-target loop (LocalStack + real AWS)
Stop when: both targets pass **independently and separately** — a LocalStack pass
does not imply a real-AWS pass, and per this project's standing rule
(`feedback-cicd-dual-target-real-aws-priority`), if the two ever conflict, real
AWS's behavior wins and LocalStack's workflow gets adjusted to match, not the
other way around.

### destroy/rebuild loop
Stop when: a **from-nothing** apply (not a resume of existing state) produces the
same verified end state as before the destroy. Phase 20 is the only phase in this
project that actually ran this loop, and it caught a real bug (`-target`
dependency closure silently skipping the IGW/route table) that every prior
resume-based apply had never exercised. Retrospectively this should be a standing
requirement for any infra phase claiming to be "done," not an occasional deeper
check.

## Anti-pattern: the false-positive stop condition

Every one of this project's real "N gaps found" entries in `completed.md` exists
because an earlier, weaker stop condition was satisfied while the real system was
still broken (a green CI run that never touched the actual deploy path; a
LocalStack pass that didn't apply to real AWS's IAM enforcement; a smoke check
querying the *current* SSM value, which passes even when CloudFront rotated to a
new domain — see `constraints/standing-constraints.md`). When a stop condition
can be satisfied without the underlying capability being true, it isn't a stop
condition — it's noise wearing a checkmark.
