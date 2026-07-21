# Loop Engineering Approach — Steps (from project start)

These are the steps we would have followed starting at Phase 1, in order. Each
step names the artifact that implements it (see other folders in `loopeng/`) and
the point in this project's real history where skipping it actually cost time.

## 1. Define the loop unit and its stop condition before writing code

A "loop" needs a bounded unit of work with an explicit entry and exit. This
project's real unit already existed implicitly: a **phase** (1–21 in `plan.md`).
Loop engineering makes this explicit from the start: no phase begins without a
one-paragraph stop condition written down first (see
`01-methodology/stop-conditions.md`). "Feature works" is not a stop condition;
"real browser test confirms login/chat against the live CloudFront URL" is —
this is in fact the stop condition this project converged on by Phase 15/16, just
several phases late.

## 2. Establish persistent state artifacts before starting any loop

A loop that doesn't survive a context reset or a new session isn't a loop, it's a
one-off. `plan.md` (target design + roadmap) and `completed.md` (actual status +
every real gap found) are this project's loop-state files. They should be
scaffolded on day 1, not grown organically — see `skills/phase-scaffold/SKILL.md`
and `loops/loop-state-tracking.md`.

## 3. Encode standing constraints as durable, checkable rules

Prose in `CLAUDE.md` is necessary but not sufficient — a constraint a human has to
remember to re-check is a constraint that gets violated under pressure. Split
constraints into two kinds and implement each differently:

- **Mechanically checkable** (a hook can verify it without judgment): e.g. "never
  build the frontend on Windows Git Bash without `MSYS_NO_PATHCONV=1`" (see
  `hooks/msys-pathconv-guard.sh`) — this bug recurred three times (Phases 15, 16,
  20) before being written down; a hook would have caught it every time.
- **Judgment-requiring** (needs an independent read, not a regex): e.g. "CI/CD
  must work on both LocalStack and real AWS, real-AWS wins on conflict" — this
  needs a subagent doing an independent design check, not a hook (see
  `subagents/infra-gap-hunter.md`).

See `constraints/standing-constraints.md` for the full formalized list, each
traced back to the real memory/incident that produced it.

## 4. Separate the "build" loop from the "verify" loop

Build = make it work once, by hand, in the easiest environment. Verify = make it
work repeatedly, from a clean slate, against the real target. This project's
actual pattern — Stage A/B against LocalStack, then a separate Stage C against
real AWS — is exactly this separation, applied to Phases 15/16/18/19/20/21. Loop
engineering makes it a rule from Phase 1 rather than a pattern that emerged by
Phase 15: **no loop closes on a LocalStack-only or dev-machine-only pass** if a
higher-fidelity target exists.

## 5. Treat "real gap found" as the primary unit of learning, and log every one

`completed.md`'s Phase 18/19 entry lists nine real gaps found running CD against
LocalStack; the Phase 15/18 Stage C entry lists eleven more against real AWS; the
Phase 16/19 Stage C entry lists four. This was already this project's most
valuable output — more valuable than the green checkmarks — but it was captured
as prose after the fact. Loop engineering makes gap-logging a required step of
closing any verify loop, not an incidental side effect: see
`skills/gap-log/SKILL.md`.

## 6. Use subagents for independent verification, not just execution

The agent that writes the Terraform should not be the one that certifies the
stack is done — it has every incentive (explicit or not) to declare victory early.
A separate verifier subagent, spawned fresh (no shared context, no sunk-cost bias
toward the approach already taken), re-checks against the stop condition. See
`subagents/phase-verifier.md`.

## 7. Gate destructive/irreversible actions behind a hook, from Phase 1

`terraform destroy`, force-push, credential/IAM changes, and clearing git hooks
should require explicit confirmation mechanically, not just as a habit the
assistant is supposed to remember under CLAUDE.md's general guidance. See
`hooks/destructive-command-guard.sh`. (Phase 20's real EKS teardown-and-rebuild
was a deliberate, user-requested destroy — the guard should confirm loudly, not
block outright, since destroys are sometimes exactly the right call.)

## 8. Define stop conditions per loop type up front, and make them falsifiable

See `01-methodology/stop-conditions.md`. A stop condition should be phrased so
that a skeptical reader could check it against evidence (a URL, a log line, a
test report) — not "should be working," but "curl against
`https://<live-cloudfront-domain>/health` returns 200."

## 9. Re-run the loop against every real target before closing it

This project's own hard-won rule (`constraints/standing-constraints.md` →
dual-target parity) should have been a Phase-1 constraint, not a Phase-18 lesson.
Declaring it early would have caught the CloudFront-to-ALB port-routing bug and
the `/health` routing gap in Phase 15/16 instead of Phase 18/19.

## 10. Update loop-state artifacts as part of closing the loop, not as a follow-up

"Done" means "documented as done, including every gap found getting there," or it
isn't done. `completed.md` updates should happen in the same sitting as the
verification pass, not as a separate task queued for later (which is how work
silently goes stale between sessions). See `skills/phase-close/SKILL.md`.
