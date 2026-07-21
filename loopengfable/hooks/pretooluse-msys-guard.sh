#!/usr/bin/env bash
# Constraint C1 (HOOK): MSYS/Git-Bash path-conversion guard.
# PreToolUse hook, matcher: Bash. Exit 2 blocks the tool call and feeds
# stderr back to the agent.
#
# Two shapes of the same underlying bug (MSYS rewrites any leading-"/"
# argument into a Windows path rooted at the Git install dir):
#   1. Frontend static-export builds: NEXT_PUBLIC_API_BASE_URL=/v1 becomes
#      C:/Program Files/Git/v1, baked into the compiled bundle.
#      Cost before enforcement: three incidents (Phases 15, 16, 20).
#   2. AWS CLI SSM parameter names: --name /crag/... gets the same mangling.
#
# Reads the raw tool-call JSON from stdin; substring checks only (no jq
# dependency). If your Claude Code version's payload shape differs, the
# substring approach still works on the embedded command text.

input="$(cat)"

# Shape 1: static-export build without the env guard
if echo "$input" | grep -q "NEXT_OUTPUT_MODE=export"; then
  if ! echo "$input" | grep -q "MSYS_NO_PATHCONV"; then
    cat >&2 <<'EOF'
BLOCKED [constraint C1 - loopengfable/hooks/pretooluse-msys-guard.sh]

Frontend static-export build without MSYS_NO_PATHCONV=1. On Git Bash this
silently rewrites the leading "/" in NEXT_PUBLIC_API_BASE_URL=/v1 into
"C:/Program Files/Git/v1" and bakes it into the compiled bundle; browsers
then request file:///C:/Program%20Files/Git/... and get blocked.

Re-run prefixed:
  MSYS_NO_PATHCONV=1 NEXT_OUTPUT_MODE=export NEXT_PUBLIC_API_BASE_URL=/v1 npm run build

(And remember: if a broken bundle already shipped, re-sync alone is not
enough - CloudFront edge caches need invalidation too.)
EOF
    exit 2
  fi
fi

# Shape 2: SSM parameter fetch with a leading-slash --name, same guard needed
if echo "$input" | grep -q -- "--name /"; then
  if ! echo "$input" | grep -q "MSYS_NO_PATHCONV"; then
    cat >&2 <<'EOF'
BLOCKED [constraint C1 - loopengfable/hooks/pretooluse-msys-guard.sh]

AWS CLI call with a leading-"/" --name argument (e.g. --name /crag/...)
without MSYS_NO_PATHCONV=1. Git Bash will mangle the parameter name into a
Windows path and the lookup will fail confusingly.

Re-run with MSYS_NO_PATHCONV=1 set (export it or prefix the command).
EOF
    exit 2
  fi
fi

exit 0
