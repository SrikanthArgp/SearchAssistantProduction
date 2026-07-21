# Loop Engineering — Retrospective Applied to This Project

This folder answers one question: **if we had run this project's 21 phases (see
root `plan.md` / `completed.md`) as a deliberate "loop engineering" discipline from
day one, what would we have built, and how would it have worked?**

"Loop engineering" here means: using Claude Code's own agentic primitives — skills,
subagents, hooks, constraints, and explicit stop conditions — as the actual
project-management mechanism for iterative build → verify → fix cycles, instead of
letting that discipline emerge ad hoc (which is what actually happened — plan.md and
completed.md ended up serving this purpose organically, but the rules were
discovered and written down *after* being violated at least once each: see
`constraints/standing-constraints.md`).

Everything under this folder is a **real, usable artifact** — skill files, subagent
definitions, hook scripts, a settings.json snippet, a plugin manifest — structured so
they could actually be dropped into `.claude/` and used going forward on this
project or copied to a new one. They are not just descriptive documentation, though
each folder's catalog/README explains the reasoning.

Nothing outside this folder was modified to produce it.

## Layout

```
loopeng/
├── 01-methodology/       # the steps to follow, and how the 21 real phases map onto them
├── constraints/          # durable rules, formalized from this project's actual feedback/project memories
├── loops/                # the recurring loop types this project actually ran, and how their state was tracked
├── skills/                # real SKILL.md files: phase-scaffold, phase-close, gap-log, cloudfront-refresh
├── subagents/             # real subagent definitions: phase-verifier, infra-gap-hunter, destructive-action-guard
├── hooks/                 # real hook scripts + a settings.json snippet wiring them in
└── plugins/               # packaging the above as a reusable Claude Code plugin
```

## Reading order

1. `01-methodology/loop-engineering-approach.md` — the 10 steps, in order.
2. `01-methodology/phase-to-loop-mapping.md` — which of this project's real 21 phases exercised which loop type.
3. `01-methodology/stop-conditions.md` — what "done" actually means per loop type, made falsifiable.
4. `constraints/standing-constraints.md` — the durable rules, several of which were only learned the hard way.
5. `loops/loop-catalog.md` and `loops/loop-state-tracking.md` — the loop types themselves and how state persisted across sessions.
6. `skills/`, `subagents/`, `hooks/` — the artifacts implementing the above.
7. `plugins/plugin-manifest-design.md` — how to bundle it all for reuse on the next project.

## A note on fidelity

The skill/subagent/hook file formats here follow the schema this Claude Code
installation uses as of 2026-07-19. Skill and subagent frontmatter, and hook
event names/payload shape, have changed across Claude Code versions before —
verify against `claude --version` / current docs before assuming these are wired
correctly on a different install.
