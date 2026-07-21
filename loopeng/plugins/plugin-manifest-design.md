# Packaging as a Reusable Plugin

Everything under `loopeng/skills/`, `loopeng/subagents/`, and `loopeng/hooks/`
is written to be usable directly by this project (paths in `settings.snippet.json`
assume this repo's root). To reuse the same loop-engineering discipline on a
*different* project, package these as a Claude Code plugin instead of copying
files by hand.

## Why a plugin instead of copy-paste

A plugin gives the artifacts one install/update point instead of N manually
synced copies — important here because several of these artifacts (the MSYS
guard, the dual-target constraint) encode lessons that took multiple real
incidents to learn on *this* project. Copy-pasted files drift; a plugin
version doesn't.

## Suggested manifest (`loopeng/plugins/plugin.json`)

See the sibling `plugin.json` in this folder for the actual manifest. Its shape
follows this Claude Code installation's plugin schema as of 2026-07-19 —
**verify field names against `claude plugin --help` (or current docs) before
assuming this loads correctly on a different install/version.**

## Directory shape a plugin expects

```
loop-engineering-toolkit/
├── plugin.json
├── skills/
│   ├── phase-scaffold/SKILL.md
│   ├── phase-close/SKILL.md
│   ├── gap-log/SKILL.md
│   └── cloudfront-refresh/SKILL.md      # project-specific — see note below
├── agents/
│   ├── phase-verifier.md
│   ├── infra-gap-hunter.md
│   └── destructive-action-guard.md
└── hooks/
    ├── msys-pathconv-guard.sh
    ├── destructive-command-guard.sh
    └── settings.snippet.json
```

This mirrors `loopeng/`'s own layout (`skills/` → `agents/` naming is the one
difference most plugin schemas expect for subagents).

## What's generic vs. project-specific when porting to a new project

**Generic — reuse as-is:**
- `phase-scaffold`, `phase-close`, `gap-log` skills — the phase/stop-condition/
  gap-logging discipline doesn't depend on this being a CRAG agent.
- `phase-verifier`, `destructive-action-guard` subagents — general-purpose.
- `destructive-command-guard.sh` — the pattern list (terraform destroy,
  force-push, etc.) is generic; extend rather than replace.

**Project-specific — adapt or drop:**
- `cloudfront-refresh` skill and the CloudFront-specific parts of
  `infra-gap-hunter` — only relevant if the new project also deploys behind
  CloudFront with SSM-stored domains.
- `msys-pathconv-guard.sh` — only relevant on Windows Git Bash projects doing
  static-export-style builds with leading-`/` arguments.
- The dual-target (LocalStack/real-AWS) checklist in `infra-gap-hunter` —
  generalizes to "cheap dev-loop target vs. target of record," but the
  specific checks (IAM scoping gaps, CloudFront OAC) are AWS-specific.

## Installing locally without a plugin marketplace

Until/unless this is published to a plugin marketplace, the fastest path to
reuse on a sibling project is: copy `loopeng/skills/`, `loopeng/subagents/`
(renamed `agents/` if the target project's convention expects that), and
`loopeng/hooks/` into that project's `.claude/` directory, then merge
`hooks/settings.snippet.json`'s contents into that project's `.claude/
settings.json`, fixing the hook script paths to match.
