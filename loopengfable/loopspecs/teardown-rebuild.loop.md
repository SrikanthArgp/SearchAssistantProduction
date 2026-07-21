---
id: teardown-rebuild
goal: The system, destroyed to nothing, can be rebuilt to its verified state by the documented path alone.
invariant: The rebuild uses only what a stranger would have - the repo, the documented bootstrap, and declared secrets; no memory of the previous build, no leftover state, no undocumented hand-steps.
iterate: Destroy (confirmed, scoped - see the destructive-action gate in hooks/), rebuild via the documented path, run clean-slate-verify's golden path against the result.
verify: The rebuilt system passes the same verify-step the original system passed, plus a diff of "steps actually needed" vs. "steps documented."
evidence: The rebuild transcript, the golden-path result, and the doc-diff (empty diff = docs are honest).
stop: A from-nothing rebuild reaches verified-green with zero undocumented interventions.
budget: 2 full rebuild attempts
escalation: A second failed rebuild means the documented path is wrong in a way spot-fixes aren't capturing - stop and rewrite the runbook against the transcript before attempting a third.
nests_in: none (outermost; the strongest claim this framework can certify)
---

# teardown-rebuild

The most expensive loop, run the least often, producing the strongest
possible evidence: *nothing about this system depends on state we can't
recreate.* Resumed builds — every `terraform apply` against existing state,
every redeploy over a warm cluster — accumulate silent dependencies on
things that already exist; only destruction reveals them.

**Worked example — the incident that earns this loop its place:** Phase 20's
EKS stack was destroyed at explicit user request and rebuilt from empty
state the same day. The fresh apply failed after ~25 minutes
(`NodeCreationFailure`): the runbook's Stage 1 `-target` list assumed
Terraform's dependency closure would pull in the IGW, route table, and
route-table association — but nothing in the targeted resources actually
*referenced* them, so they were never created. The node got a public IP and
no route out (confirmed via `nodeadm`'s console log retrying
`EC2/DescribeInstances` forever). Every previous resumed apply had masked
this completely, because the networking already existed in state. One
rebuild found what dozens of resumes never could — and the fix went into
the runbook (the doc-diff clause), which is the loop's real deliverable.

The tight budget (2) is deliberate: rebuilds are slow and destroys have
blast radius, so this loop shouldn't thrash. Its cadence: once at any infra
phase's close (making "rebuildable from nothing" part of *done*), and once
before declaring any environment production-worthy.
