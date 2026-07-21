# Standing Constraints

Durable rules this project actually accumulated, each traced to the real incident
that produced it. Loop engineering's claim is that these should have been
declared as constraints at the phase where the risk first existed (column 3),
not discovered as lessons at the phase where they were first violated (column 4).

| Constraint | Enforcement | Should've applied from | Actually learned at |
|---|---|---|---|
| Never manually run `infra/*/scripts/*.sh` as a workaround while testing CD — let the workflow perform every step itself | judgment (subagent / self-check) | Phase 18 (first CD workflow) | Phase 18/19 LocalStack verification pass |
| CI/CD and Terraform must work on **both** LocalStack and real AWS; real AWS wins on conflict | judgment (subagent design review) | Phase 15 (first infra phase) | Stated explicitly 2026-07-14, after Phases 15/16/18/19 Stage C gaps had already been found and patched individually |
| `MSYS_NO_PATHCONV=1` required for any frontend static-export build on Windows Git Bash | mechanical (hook) | Phase 15 (first static-export build) | Recurred 3×: Phases 15, 16, 20 |
| Real-AWS CloudFront domains are not stable across applies that touch `cloudfront.tf` — always re-fetch via SSM/`terraform output`, never trust a bookmarked URL | mechanical (hook, warn-only) | Phase 15 (first CloudFront resource) | 2026-07-14, after an apply silently rotated both live domains |
| `infra/bootstrap` has no dedicated backend — relies on Terraform workspaces (`default`=LocalStack, `real-aws`=real AWS) with no `.tfvars` enforcing the 3 required `-var` overrides; always confirm `terraform workspace show` before running anything against real AWS | judgment (checklist in subagent) | Phase 15 (bootstrap created) | Phase 21, misdiagnosed first as a "hang" |
| `actions/checkout@v4` leaves a `GITHUB_TOKEN`-derived `http.extraheader` active for the whole job, silently overriding any other token embedded in a push URL — must be cleared before a bot-commit push with a different credential | mechanical (workflow step, documented) | Phase 17 (first workflow with any push-back-to-repo need) | Phase 21 |
| Destructive actions (`terraform destroy`, force-push, IAM/credential changes) require explicit confirmation, never silently skipped | mechanical (hook) | Phase 1 | Never formally violated in this project, but never mechanically enforced either — Phase 20's destroy was a deliberate, confirmed, user-requested action; the constraint exists to make that the only kind |

## Why two enforcement types

**Mechanical (hook-enforced)** constraints are ones a regex/string-match/env-var
check can catch without understanding intent — the MSYS path bug, the CloudFront
domain-staleness warning, the checkout-token-clearing step. These get real hook
scripts (see `hooks/`) because a human/agent forgetting to check by hand is
exactly the failure mode that produced the recurrence (3× for MSYS alone).

**Judgment (subagent-enforced)** constraints require reading intent or design,
not just text — "does this Terraform change preserve real-AWS fidelity," "was
this CD test run actually exercising the automation or did it lean on a manual
script." These get a subagent (see `subagents/infra-gap-hunter.md`) doing an
independent pass, because a hook pattern-matching on file diffs can't tell "this
IAM policy is appropriately scoped" from "this IAM policy is a rubber stamp."

## Applying new constraints going forward

When a new gap is found and fixed (see `skills/gap-log/SKILL.md`), classify it
immediately: if it's mechanically checkable, write the hook before closing the
loop, not after the next recurrence. If it requires judgment, add it to
`subagents/infra-gap-hunter.md`'s checklist. A gap that recurs a second time
without gaining an enforcement mechanism is a process failure, independent of
whether the second occurrence was itself fixed quickly.
