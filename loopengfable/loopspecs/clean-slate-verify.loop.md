---
id: clean-slate-verify
goal: The feature works repeatedly, starting from reset state, on the golden path a real user would take.
invariant: No verification run reuses warm state (caches, existing containers, logged-in sessions, populated DBs) that a fresh user wouldn't have.
iterate: Reset the relevant state, run the golden path, fix what broke.
verify: The full user-visible flow, exercised as a user would — browser for UIs, curl for APIs, fresh checkout for build steps.
evidence: A browser test transcript (Playwright or manual step list), or complete request/response pairs — plus a statement of what was reset.
stop: The golden path succeeds from reset state, and the verify-step has ALSO been observed failing at least once (any earlier iteration counts) so its green is known to be falsifiable.
budget: 8 iterations
escalation: Stop; the gap list goes to the user with the question of whether the feature or the environment is the problem.
nests_in: none (or dual-target-parity when a target-of-record exists)
---

# clean-slate-verify

The trust-producing loop. Two clauses do the work:

**The reset clause.** Warm state is where false confidence lives. This
project's sharpest illustration is Phase 20: every *resumed* Terraform apply
passed; the one *from-nothing* apply exposed that the IGW/route-table were
never in the `-target` dependency closure at all. (That specific case gets
its own outer loop — `teardown-rebuild` — but the principle is the same at
every scale, down to "does login work in an incognito window.")

**The falsifiability clause** ("observed failing at least once") is borrowed
from this project's Phase 17, which verified the CI pipeline with a
deliberate-failure run before trusting its green. A verify-step that has
never failed is indistinguishable from a verify-step that can't fail — e.g.
the real-AWS smoke check that queried the *current* CloudFront domain from
SSM and therefore passed even when the domain had just rotated out from
under every published URL (2026-07-14 incident).

**Worked example:** the standard this project converged on by Phase 15 —
"login/logout/session-list/chat-history/chat-send all work in a real browser
against the live stack" — is this loop's stop condition instantiated for
the chat app.
