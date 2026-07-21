#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Blocks the MSYS/Git-Bash path-mangling bug
# that has recurred 3x on this project (Phases 15, 16, 20) — a frontend
# static-export build run without MSYS_NO_PATHCONV=1 silently mangles the
# leading "/" in NEXT_PUBLIC_API_BASE_URL=/v1 into a Windows path rooted at
# the Git install dir, which then gets baked into the compiled JS bundle.
#
# See loopeng/skills/cloudfront-refresh/SKILL.md and
# loopeng/constraints/standing-constraints.md for the full history.
#
# Claude Code passes the tool call payload as JSON on stdin. This script does
# a plain substring check on the raw payload rather than parsing JSON fields,
# so it has no dependency on jq being installed — good enough for this
# specific, narrow pattern. If your Claude Code version's PreToolUse payload
# shape differs, verify field names before relying on stricter parsing.

input="$(cat)"

if echo "$input" | grep -q "NEXT_OUTPUT_MODE=export"; then
  if ! echo "$input" | grep -q "MSYS_NO_PATHCONV"; then
    cat >&2 <<'EOF'
Blocked by loopeng/hooks/msys-pathconv-guard.sh:

This command builds the frontend static export (NEXT_OUTPUT_MODE=export)
without MSYS_NO_PATHCONV=1. On Windows Git Bash this silently mangles the
leading "/" in NEXT_PUBLIC_API_BASE_URL=/v1 into a Windows path (e.g.
"C:/Program Files/Git/v1"), which gets baked into the compiled JS bundle —
the browser then tries to fetch file:///C:/Program%20Files/Git/... instead of
a real relative API call.

Re-run with MSYS_NO_PATHCONV=1 prefixed, e.g.:
  MSYS_NO_PATHCONV=1 NEXT_OUTPUT_MODE=export NEXT_PUBLIC_API_BASE_URL=/v1 npm run build
EOF
    exit 2
  fi
fi

exit 0
