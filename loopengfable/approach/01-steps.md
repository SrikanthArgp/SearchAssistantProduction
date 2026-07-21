# The Steps, In Order

How a project runs under loop engineering, from empty repo to production.
Each step names its implementing artifact.

## Step 0 — Install the discipline before the first feature

In commit #1, alongside the repo scaffold:

- Create the two state files: a forward-state file (this project's `plan.md`)
  and a backward-state file (`completed.md`). Empty is fine; existing is what
  matters.
- Install the hooks (`hooks/settings.fragment.json`) — the destructive-command
  gate and any environment-specific guards known on day one. Guards added
  after the first incident are guards that missed the first incident.
- Create `loopspecs/` with the format spec. No loop instances yet.

## Step 1 — Contract the loop before entering it

When a bounded unit of work begins (this project's "phase"), write its
`*.loop.md` contract first — invoke `skills/loop-start/SKILL.md`. The
critical discipline: the **stop condition and budget are written while you
still know nothing about how hard the work is**, which is exactly when
they're honest. A stop condition written after three failed attempts is
negotiated with fatigue.

Have `subagents/stop-condition-auditor.md` audit the contract before any
implementation. This is cheap (one subagent pass over one file) and catches
the single most expensive class of error: an inadmissible stop condition that
lets the loop "succeed" while the goal is false.

## Step 2 — Iterate small, verify every pass, capture every surprise

Run the loop body: iterate-step, then verify-step, producing an evidence
artifact each pass. When verification surprises you — anything fails, or
succeeds for the wrong reason — invoke `skills/gap-capture/SKILL.md`
**before** the next iteration, not at loop close. A gap captured while the
error text is still in the terminal is precise; a gap reconstructed at
close-time is folklore.

Check the invariant every pass. For this project's deploy loops the invariant
was "the automation does every step itself" — an invariant that erodes one
innocent manual `docker push` at a time unless it's checked per-iteration.

## Step 3 — Watch the budget

`skills/loop-check/SKILL.md` runs at intervals: iterations consumed vs.
budget, and — more important — **is state actually changing between
iterations?** Two consecutive iterations with identical observable state
means the loop is spinning regardless of remaining budget; escalate
immediately. (Calibration from this project's real history: real convergent
loops here typically closed within 4–11 iterations even against real AWS —
Fargate Stage C took 4 dispatches, Lambda Stage C took ~11 gap-fix cycles. A
loop past ~12 iterations without a shrinking gap list is presumptively
spinning.)

## Step 4 — Escalate honestly at the budget

When the budget is hit, the designed behavior is: stop, write down what is
known (which iterations, which gaps, which hypotheses eliminated), and hand
the decision to the user — extend the budget, change the approach, or accept
partial. Never silently extend. The user extending a budget with full
information is collaboration; the agent extending it silently is the spinning
pathology wearing a work ethic.

## Step 5 — Close only against the contract

`skills/loop-close/SKILL.md`: the stop condition is re-read *verbatim* from
the contract and checked against evidence artifacts — not against memory of
what the goal roughly was. Deviations from the original design are recorded
as deviations (the way `completed.md`'s real Phase 20 entry lists four
confirmed deviations from its design doc), not silently absorbed. The
backward-state file is updated in the same sitting.

## Step 6 — Convert gaps into permanent defenses

At close, every captured gap gets an enforcement decision recorded in
`constraints/constraints.md`: **hook** (mechanically checkable), **subagent
checklist** (judgment-requiring), or **accepted risk** (explicitly declined,
with reason). The rule that makes this bite: *a gap recurring after its
enforcement decision was "hook" but the hook was never written is a process
defect, chargeable to the loop that closed without writing it.* Under this
rule, the MSYS path bug costs one incident, not three.

## Step 7 — Nest loops; never conflate their evidence

Bigger goals are loops of loops: build-loop inside verify-loop inside
dual-target-loop (see `loopspecs/`). The one rule of nesting: **an inner
loop's evidence never satisfies an outer loop's stop condition.** LocalStack
passing (inner) never closes the real-AWS loop (outer); a hand-verified
deploy (inner) never closes the pipeline-automation loop (outer). Every
Stage-C gap list in this project's history is a measurement of exactly this
distance — 11 gaps between "LocalStack says yes" and "AWS says yes" for
Lambda alone.
