# Packaging & Porting

How to carry this framework to the next project, and — more important —
which parts travel and which parts are this project's scar tissue.

## Plugin layout

`plugin.json` beside this file is the manifest. Expected tree when packaged:

```
contracted-loops/
├── plugin.json
├── skills/{loop-start,loop-check,loop-close,gap-capture}/SKILL.md
├── agents/{stop-condition-auditor,parity-checker,loop-warden}.md
├── hooks/*.sh + settings.fragment.json
└── loopspecs/          # ship the format spec + the six templates; instances stay per-project
```

Without a marketplace: copy `skills/` and `subagents/` (renamed `agents/`)
into the target project's `.claude/`, merge `hooks/settings.fragment.json`
into its `.claude/settings.json`, fix hook paths, copy `loopspecs/` to the
project root as the contract library.

## What travels unmodified (the framework)

- **The loopspec format** and all six loop templates — the worked examples
  in their bodies are this project's, but the contracts generalize: every
  project has a cheap target and a target of record, every project has
  warm-state lies, every project spins sometimes.
- **All four skills** — the lifecycle (contract → iterate → check → close,
  gap-capture throughout) has no project-specific content.
- **stop-condition-auditor** and **loop-warden** — they audit the framework's
  own artifacts, so they port wherever the framework does.
- **pretooluse-destructive-gate.sh** and **stop-state-persistence-nudge.sh**
  — generic; extend the destructive pattern list rather than replacing it.
- **The constraint register format** (constraints.md + index.json + the
  HOOK/AGENT/DOC classes + rule C8). Ship the *format* with C5/C8 pre-seeded;
  the target project earns the rest of its rows itself.

## What is scar tissue (adapt or drop when porting)

- **pretooluse-msys-guard.sh (C1)** — only meaningful on Windows Git Bash
  with leading-`/` argument builds. Drop elsewhere; keep as the reference
  example of "incident → 20-line hook, same day."
- **pretooluse-cloudfront-staleness.sh (C4)** — only meaningful behind
  CloudFront with rotating domains. The *general* lesson (identifiers you
  memorize can rotate under you; re-fetch at time of use) belongs in the
  target project's constraint register the first time it bites.
- **parity-checker's C6 and IAM sections** — AWS/Terraform-specific; the C2
  and C3 sections generalize to any cheap-target/record-target split
  (emulator vs. device, staging vs. prod, mock vs. live API).
- **Budget calibrations** in the loopspec templates (15 iterations, 12
  dispatches, 2 rebuilds) — derived from *this* project's convergence data.
  Keep them as starting points, then recalibrate from the target project's
  own close-out records after the first few loops.

## The porting principle

The framework's generic half is the *shape* of the discipline: contracts
before work, evidence over assertion, budgets with escalations, gaps into
enforcement. The project-specific half is the accumulated register of that
one project's surprises. Port the shape everywhere; let each project grow
its own register — and expect the new project's first few incident-rca
loops to feel expensive, because that's the register being earned.
