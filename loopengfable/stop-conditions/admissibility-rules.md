# Stop-Condition Admissibility Rules

A stop condition is the sentence that ends a loop. Four tests decide whether
it's admissible in a loopspec. Each test is named for the failure it blocks,
with the incident from this project's real history that demonstrates the
failure.

## Test 1 — Falsifiable: could this sentence be checked by a skeptic?

The condition must name an observation a third party could attempt and watch
fail. "The deploy works" is inadmissible; "a fresh dispatch of `cd.yml
(target: lambda, environment: aws)` goes green through its smoke check, run
URL attached" is admissible.

*Demonstrating incident:* none — this project's `completed.md` entries were
generally good at this. The test exists because the default phrasing of
"done" everywhere else isn't.

## Test 2 — Non-proxy: does the observation touch the actual goal?

The observed thing must be the goal, not a neighbor of the goal. Tests
passing is a proxy for the pipeline working; LocalStack is a proxy for AWS;
"the route exists in the code" is a proxy for "the route responds."
Proxies are fine as *iteration* signals inside the loop — they are
inadmissible as *stop* conditions.

*Demonstrating incident:* the eleven real-AWS gaps behind Lambda's Stage C.
Every one sat in the gap between the proxy (LocalStack green) and the goal
(AWS green): IAM enforcement, an ECR repository policy, CloudFront-OAC
behavior. The proxy was satisfied the whole time.

## Test 3 — Fail-capable: has the check itself ever been seen red?

A check that has never failed is unverified as a check. Either it has
genuinely failed during the loop's earlier iterations, or a deliberate
failure must be injected once to prove the green is earned.

*Demonstrating incidents, one per direction:* Phase 17 did this right —
the CI pipeline was verified with a deliberate-failure run before its green
was trusted. The 2026-07-14 CloudFront incident is the other direction: the
CD smoke check fetched the *current* domain from SSM and checked that —
structurally incapable of failing on a domain rotation, so it stayed green
while both published URLs went dead. That check would not have survived
Test 3.

## Test 4 — State-complete: does it say what state the check starts from?

"Works" from warm state and "works" from reset state are different claims;
the condition must say which one it makes — and outer loops (clean-slate,
teardown-rebuild) should demand the strong one. A condition silent about
starting state defaults, in practice, to whatever state the machine happens
to be in, which is always the warm one.

*Demonstrating incident:* Phase 20's from-nothing rebuild. "The EKS stack
applies cleanly" was true for months from resumed state and false from
empty state (`-target` never pulled in the IGW/route-table). Both
claims used the same words; only Test 4 forces the words to differ.

## Applying the tests

`subagents/stop-condition-auditor.md` runs all four against a loopspec's
`stop:` (and `evidence:`) lines before the loop's first iteration, and
returns pass / rewrite-suggested per test. The audit is one subagent pass
over one file — the cheapest step in this whole framework, defending
against the most expensive failure: a loop that terminates successfully
with its goal still false.
