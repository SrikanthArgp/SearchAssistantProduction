# Loop Engineering — A Fresh Retrospective Design (Fable run)

**Premise:** rerun this project's entire history (Phases 1–21, per root
`plan.md`/`completed.md`) as if loop engineering had been the operating
discipline from commit #1. This folder contains the steps we would have
followed, and the real, usable artifacts we would have created — written
independently of the earlier `loopeng/` folder, as a second take on the same
brief, so the two can be compared.

**The central design idea of this take:** a loop is not a habit or a prose
convention — it is a **contract**, written down as a first-class spec file
before the loop runs. Every loop spec declares six things: goal, invariant,
iterate-step, verify-step, stop condition, and **iteration budget with an
escalation rule**. The last one is what most iterative processes silently
lack: a loop without a budget doesn't converge, it spins — and an agent
spinning politely looks identical to an agent making progress until you count
iterations. This project's real history contains both kinds (compare Phase 15's
Stage C, which converged after repeated dispatches each fixing a named gap,
against Phase 19's self-inflicted ~9-minute `terraform plan` hang, which was a
loop with no budget and no escalation).

Nothing outside this folder was modified.

## Layout

```
loopengfable/
├── approach/            # the operating model and the ordered steps
├── loopspecs/           # loops as first-class contract files (*.loop.md) + the format spec
├── stop-conditions/     # what makes a stop condition admissible
├── constraints/         # standing rules with enforcement class + machine-readable index
├── skills/              # SKILL.md files: loop-start, loop-check, loop-close, gap-capture
├── subagents/           # stop-condition-auditor, parity-checker, loop-warden
├── hooks/               # PreToolUse guards + a Stop-event state-persistence nudge + settings fragment
└── plugin/              # packaging manifest for reuse on the next project
```

## Reading order

1. `approach/00-operating-model.md` — the mental model: contracts, budgets, evidence.
2. `approach/01-steps.md` — the ordered steps to run a project this way.
3. `loopspecs/LOOPSPEC-FORMAT.md` then any `*.loop.md` — the contract format and six concrete instances derived from this project's real work.
4. `stop-conditions/admissibility-rules.md` — the four tests a stop condition must pass.
5. `constraints/constraints.md` — the standing rules, each traced to the incident that taught it.
6. `skills/`, `subagents/`, `hooks/` — the executable/installable artifacts.
7. `approach/02-retrospective-map.md` — what would have gone differently, phase by phase.
8. `plugin/PACKAGING.md` — how to carry all of this to the next project.

## Fidelity caveat

Skill frontmatter, subagent frontmatter, hook event names, and plugin manifest
shape follow this Claude Code installation as of 2026-07-19. These schemas have
changed across versions; verify before installing on a different setup.
