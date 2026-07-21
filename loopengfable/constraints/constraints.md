# Standing Constraints

The permanent output of `incident-rca` loops: rules that survive their
originating incident. Every constraint carries an **enforcement class**,
because a rule without a decided enforcement mechanism is a wish:

- **HOOK** — mechanically checkable; a script gates the action (see `hooks/`).
- **AGENT** — judgment-requiring; lives in a subagent's checklist (see `subagents/`).
- **DOC** — accepted as convention only; explicitly means "we chose not to
  enforce this mechanically, and recurrence is a priced-in risk." DOC must be
  chosen, never defaulted into.

A machine-readable index lives in `constraints.index.json` beside this file,
so hooks and subagents can reference constraint IDs stably.

---

## C1 — Frontend static-export builds on Git Bash require `MSYS_NO_PATHCONV=1`
**Class: HOOK** (`hooks/pretooluse-msys-guard.sh`)
MSYS argv conversion rewrites any leading-`/` argument into a Windows path
rooted at the Git install dir; `NEXT_PUBLIC_API_BASE_URL=/v1` becomes
`C:/Program Files/Git/v1` *baked into the compiled bundle*. Cost of learning
this without enforcement: three incidents (Phases 15, 16, 20), each with its
own debug cycle plus CloudFront cache invalidation. The same conversion hits
AWS CLI args like `--name /crag/...` — the hook watches both shapes.

## C2 — Never hand-run a pipeline's steps while testing the pipeline
**Class: AGENT** (`subagents/parity-checker.md`) + it is the per-iteration
*invariant* of `loopspecs/pipeline-automation.loop.md`.
A hook can't tell a legitimate ad-hoc command from a pipeline step being
smuggled past the workflow; a reviewer can. Sole documented exception:
`infra/bootstrap` (state bucket/lock table), a manual one-time prerequisite
in real usage too.

## C3 — Cheap-target/record-target parity; record target wins conflicts
**Class: AGENT** (`subagents/parity-checker.md`)
No LocalStack-only endpoints/ARNs in shared code, no IAM scoping skipped
because the cheap target doesn't enforce it, differences parameterized via
the `environment` input rather than forked logic. Stated as a standing rule
by the user 2026-07-14, after Stage C measured the cost of its absence at
11 + 4 gaps.

## C4 — Never report a CloudFront domain from memory
**Class: HOOK, warn-only** (`hooks/pretooluse-cloudfront-staleness.sh`)
Applies that touch origin/OAC config force-replace the distribution and mint
a new random `*.cloudfront.net` domain; the in-pipeline smoke check can't
catch it (Test 3 failure — see `stop-conditions/admissibility-rules.md`).
Always re-fetch via SSM/`terraform output` at time of use. Warn-only because
fetching a stale domain is sometimes legitimate (comparing old vs. new).

## C5 — Destructive actions require explicit, per-action confirmation
**Class: HOOK** (`hooks/pretooluse-destructive-gate.sh`)
`terraform destroy`, force-push, `reset --hard`, hook-skipping flags. The
gate's job is not to prevent destroys — Phase 20's user-requested
teardown-rebuild was this framework's most productive single event — but to
guarantee every destroy is that kind: deliberate, scoped, confirmed.

## C6 — Before any real-AWS command in a workspace-switched Terraform root, confirm the workspace
**Class: AGENT** (checklist item in `subagents/parity-checker.md`)
`infra/bootstrap` has no dedicated backend; `default` workspace = LocalStack,
`real-aws` = real AWS, with three `-var` overrides required and no `.tfvars`
enforcing them. Wrong-workspace commands don't error — they silently talk to
LocalStack, which reads as a hang. Cost of learning: one ~9-minute
misdiagnosis (Phase 19 close-out) plus a repeat misdiagnosis in Phase 21's
first session.

## C7 — After `actions/checkout`, clear its auth header before pushing with any other credential
**Class: DOC** (workflow-code convention, noted here; the fix is one `git
config --unset-all http.extraheader`-style line in the workflow before the push)
`actions/checkout@v4` persists a `GITHUB_TOKEN`-derived `http.extraheader`
for the whole job, silently overriding whatever token is embedded in a push
URL. Cost of learning: an entire credential-debugging arc (three token
changes, one org-only dead end) that varied everything except the constant.
Class DOC is justified only because the fix now lives in the workflow file
itself (`cd-eks.yml`) where recurrence would require deleting it.

## C8 — A gap's enforcement decision is due at loop close, not "later"
**Class: AGENT** (`subagents/loop-warden.md` flags loops closing with
undecided gaps)
The meta-constraint that generates the others. Scoreboard logic: a first
incident is the cost of discovery; a recurrence after a decided-but-unbuilt
HOOK is a process defect chargeable to the loop that closed without building
it. Under C8, C1 costs one incident instead of three.
