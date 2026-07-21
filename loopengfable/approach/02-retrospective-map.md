# Retrospective Map — What Would Have Gone Differently

Phase-by-phase, where the contracted-loop discipline would have changed this
project's actual history, and where it would have changed nothing (worth
being honest about both).

## Phases 1–6 (infra scaffold, DB, auth, cache, graph refactor, FastAPI)

**Changes little.** These were well-bounded build→verify loops that this
project ran competently without formal contracts. The one concrete win:
Phase 4's Windows `ProactorEventLoop`/psycopg-async incompatibility would
have been gap-captured with an enforcement decision, seeding a
"Windows-asyncio quirks" constraint entry early. Marginal value.

## Phases 7–8 (frontend auth + chat UI)

**Changes little**, with one exception: a contracted verify-step of "real
browser flow, not component tests" from the start. This project did in fact
do real browser verification here — the discipline would have made it
contractual rather than diligent.

## Phase 9 (eval suite)

**Model case — no change needed.** A 25-item baseline run recorded as
evidence is exactly what an admissible stop condition looks like. Under loop
engineering this phase is the template other phases get compared to.

## Phase 10 (Dockerization)

The Next.js `HOSTNAME`-binding bug gets captured with root cause. Minor.

## Phases 15–16 (Lambda + Fargate, Stages A/B/C)

**This is where the discipline starts paying for itself.**

- The Stage A/B/C structure this project *invented here* is loop nesting done
  right — under loop engineering it exists from the format spec on day one
  (`loopspecs/dual-target-parity.loop.md`) instead of being discovered.
- The MSYS path-mangling bug (first occurrence, Phase 15): gap-capture forces
  an enforcement decision. It's mechanically checkable → the hook
  (`hooks/pretooluse-msys-guard.sh`) gets written *that day*. Its Phase 16
  and Phase 20 recurrences — two full debug cycles including a baked-broken
  frontend bundle behind CloudFront edge caching — never happen.
- The stale-scripts relative-path bug found in Phase 16 (leftover from the
  folder restructure) is an invariant-erosion signal: scripts that exist but
  aren't exercised by the loop rot silently. The invariant "the loop
  exercises every artifact it claims" flags them earlier.

## Phases 17–19 (CI, CD Lambda, CD Fargate)

- **Phase 17's deliberate-failure verification run is the discipline in
  miniature** — proving the pipeline can fail is evidence the green run means
  something. Loop engineering makes this mandatory for every pipeline loop:
  a verify-step that has never been observed to fail is unfalsifiable.
- The nine LocalStack gaps and eleven+four real-AWS gaps don't disappear
  under loop engineering — **that's the wrong expectation.** Those gaps were
  discovered *by* iterating against real targets; the discipline can't know
  IAM is missing `ecs:DeregisterTaskDefinition` before AWS says so. What
  changes: each gap is captured with an enforcement decision at discovery
  (several of the eleven were recurrences of *classes* — IAM-scoping gaps —
  that a parity-checker checklist grows to cover), and the budget/escalation
  rule turns the Phase 19 bootstrap misdiagnosis (~9 minutes of silent
  wrong-workspace hanging) into a fast escalation: two iterations with no
  state change → stop, check assumptions → `terraform workspace show` →
  found it in one minute instead of nine, and — because the gap-capture
  includes root cause — it's never re-misdiagnosed as a hang again.

## Phase 20 (EKS) — the destroy/rebuild vindication

The single strongest argument for contracted loops in this project's real
history: the **from-nothing rebuild** (user-requested, same day) caught a
Terraform `-target` dependency-closure gap — IGW/route-table never actually
referenced by the targeted resources, so a fresh apply left the node with no
route out, failing after ~25 minutes — that **every resumed apply had
silently masked.** Under loop engineering, "rebuild from empty state" is the
contracted stop condition of every infra loop
(`loopspecs/teardown-rebuild.loop.md`), not a fortunate user whim. Also:
the four as-built-vs-designed deviations this phase honestly recorded are
exactly what `loop-close`'s deviation section formalizes.

## Phase 21 (ArgoCD/GitOps)

The `GITHUB_TOKEN` `http.extraheader` incident is the strongest *budget*
case: several credential changes (fine-grained PAT → +Administration →
classic full-repo) each failed **identically**. Identical failure across
distinct attempts is the spinning signature — the escalation rule triggers
after the second identical failure and forces the question "what is constant
across all attempts?", which is precisely the question that found the answer
(checkout's leftover auth header overriding every credential). The
ruleset-bypass dead end (org-only mechanism, personal repo) also gets
gap-captured so no future session retries it.

## Net assessment

Loop engineering would not have found different bugs — iteration against
real targets found them, and that engine this project already had. It would
have: (1) eliminated every *recurrence* (MSYS ×2 extra, IAM-class repeats),
(2) collapsed spin time (bootstrap hang, credential cycling), and (3) made
the strongest practices this project discovered late — Stage C separation,
deliberate-failure runs, from-nothing rebuilds — day-one contracts instead
of hard-won conclusions.
