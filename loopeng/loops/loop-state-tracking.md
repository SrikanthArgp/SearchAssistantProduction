# Loop State Tracking

A loop that can't survive a session boundary isn't a loop — it's a one-off that
happens to repeat by coincidence. This project's real answer to persistent loop
state was `plan.md` + `completed.md` at the repo root, which is exactly right;
loop engineering formalizes *why* that pattern works and what it needs to keep
working as the project scales past 21 phases.

## The two-file pattern, formalized

**`plan.md` — the loop's forward state.** What loop is next, what its scope is,
what's explicitly deferred and why (this project's "Deferred to a Future
Enterprise-Grade Pass" section is a good example — deferred items are named, not
silently dropped). Updated when scope changes, not when work happens.

**`completed.md` — the loop's backward state.** What's actually done, what
verification proved it, and — critically — every real gap found getting there.
This is the file that makes the incident-loop's output durable. Updated at the
close of every verify/deploy/incident loop, in the same sitting, not deferred.

## Why both are required

`plan.md` alone tells you intent, not reality — a phase can be "planned" forever
without anyone noticing it never shipped. `completed.md` alone tells you history,
not direction — without `plan.md`'s explicit phase numbering and deferred-items
list, there's no way to tell "not done yet" from "deliberately out of scope."
This project's own Phase 15–19 renumbering (2026-07-07, to keep CI/CD phases next
to the deploy targets they build against) is an example of `plan.md` doing its
job: the reorganization is recorded as a deliberate decision, not lost.

## Cross-session continuity

Because both files live in the repo (not in a session-scoped memory), a new
Claude Code session picks up exactly where the last one left off by reading
them — this is why `CLAUDE.md` tells every session to read `plan.md`/
`completed.md` before touching `db/`, `auth/`, `cache/`, or extending the plan.
The auto-memory system (`~/.claude/projects/.../memory/`) is a *second*,
complementary state layer — it captures things that shouldn't live in
version-controlled docs (standing behavioral feedback, cross-project user
preferences) but would clutter `plan.md`/`completed.md` if inlined there. The
division of labor:

| State | Lives in | Survives |
|---|---|---|
| What's built, what's next, what's deferred | `plan.md` | Git history, all sessions, all users of the repo |
| What's actually verified, every real gap found | `completed.md` | Git history, all sessions, all users of the repo |
| Standing behavioral rules, cross-project preferences | auto-memory (`constraints/standing-constraints.md` formalizes the relevant ones here) | This user's Claude Code sessions only, not committed to the repo |

## Applying this to a new project from scratch

1. Create `plan.md` and `completed.md` (or equivalent) in commit #1, before any
   feature code — an empty loop-state file is a placeholder that gets used;
   a promise to "add docs later" doesn't.
2. Every closed loop updates `completed.md` in the same commit/session as the
   verification that closed it (see `skills/phase-close/SKILL.md`).
3. Every new constraint discovered via an incident-loop gets classified
   (mechanical vs. judgment, see `constraints/standing-constraints.md`) and
   either gains a hook or gets added to the relevant subagent's checklist —
   *before* the loop is considered closed.
