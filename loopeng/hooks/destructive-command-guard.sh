#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash). Mechanically enforces
# loopeng/subagents/destructive-action-guard.md's first line of defense:
# no destroy/force/reset/skip-hooks command runs without an explicit,
# already-confirmed bypass marker. This does not replace asking the user —
# it makes "forgot to ask" mechanically impossible instead of relying on
# the assistant to remember every time.
#
# Bypass: once the user has explicitly authorized the specific action in the
# conversation, re-issue the command with LOOPENG_CONFIRM_DESTRUCTIVE=1
# prefixed. Do not set this preemptively "just in case" — set it only after
# real confirmation for that specific command.

input="$(cat)"

pattern='terraform destroy|git push[^"'"'"']*--force|git reset --hard|git clean -f|git branch -D|--no-verify|--no-gpg-sign'

if echo "$input" | grep -qE "$pattern"; then
  if ! echo "$input" | grep -q "LOOPENG_CONFIRM_DESTRUCTIVE=1"; then
    cat >&2 <<'EOF'
Blocked by loopeng/hooks/destructive-command-guard.sh:

This command matches a destructive/irreversible pattern (terraform destroy,
force-push, reset --hard, clean -f, branch -D, --no-verify, or
--no-gpg-sign).

Per loopeng/subagents/destructive-action-guard.md: confirm this specific
action with the user first (scope, workspace/environment, recoverability).
This project has one legitimate precedent (Phase 20's deliberate EKS
teardown-and-rebuild) — every destroy should look like that one: explicit
and scoped, not an accidental side effect of debugging something else.

If the user has already confirmed, re-run the same command prefixed with
LOOPENG_CONFIRM_DESTRUCTIVE=1 to proceed.
EOF
    exit 2
  fi
fi

exit 0
