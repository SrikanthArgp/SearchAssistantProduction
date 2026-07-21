---
name: phase-scaffold
description: Scaffold a new project phase — adds a numbered entry to plan.md and a matching placeholder entry to completed.md with an explicit, falsifiable stop condition. Use when starting a new bounded unit of work (a "phase") on this project, before writing any implementation code.
---

# Phase Scaffold

Starts a new loop-engineering "phase" the same way every prior phase in this
project (see root `plan.md` / `completed.md`) should have started: state defined
before code written.

## Steps

1. Read the current `plan.md` to find the next phase number and confirm the new
   phase doesn't overlap an existing one's scope.
2. Write a new `### Phase N — <name>` section in `plan.md` containing:
   - **Scope** — one paragraph, what's in and explicitly what's out.
   - **Stop condition** — one falsifiable sentence (see
     `loopeng/01-methodology/stop-conditions.md` for the bar to hit — a
     concrete, checkable observation, not "should work").
   - **Loop type(s)** this phase will need (see `loopeng/loops/loop-catalog.md`)
     — most application phases are build→verify; infra phases are typically
     build→deploy→incident, and dual-target infra phases add the dual-target
     loop on top.
3. Add a matching `### Phase N — <name>` placeholder to `completed.md` marked
   "not started," so the backward-state file always has a slot waiting — this
   makes it visible if a phase is planned but never closed.
4. Do not write any implementation code as part of this skill. Scaffolding is
   the plan-state step; the build-loop is separate.

## When not to use this

If the work is a bugfix, a small refactor, or anything that doesn't warrant its
own falsifiable stop condition and phase number, don't scaffold a phase for it —
this skill is for the same *kind* of unit as this project's actual Phases 1–21,
not every commit.
