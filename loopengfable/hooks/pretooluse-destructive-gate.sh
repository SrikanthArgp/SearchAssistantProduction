#!/usr/bin/env bash
# Constraint C5 (HOOK): destructive-action confirmation gate.
# PreToolUse hook, matcher: Bash. Exit 2 blocks and feeds stderr to the agent.
#
# Not a prohibition - a deliberateness guarantee. This project's most
# productive single event was a destroy (Phase 20's user-requested
# teardown/rebuild, which caught the -target dependency-closure gap no
# resumed apply could see). The gate exists so every destroy is that kind:
# explicit, scoped, confirmed with the user - never a debugging reflex.
#
# Bypass protocol: after the user confirms the SPECIFIC action, re-issue the
# command prefixed with LOOPENG_CONFIRMED=1. Never set it preemptively; the
# prefix is the record that confirmation happened.

input="$(cat)"

pattern='terraform destroy|push +.*--force|push +-f |reset --hard|git clean -fd?x?|branch -D|--no-verify|--no-gpg-sign'

if echo "$input" | grep -qE "$pattern"; then
  if ! echo "$input" | grep -q "LOOPENG_CONFIRMED=1"; then
    cat >&2 <<'EOF'
BLOCKED [constraint C5 - loopengfable/hooks/pretooluse-destructive-gate.sh]

Destructive/irreversible pattern detected (terraform destroy, force-push,
reset --hard, clean -f, branch -D, or a hook/signing bypass flag).

Before proceeding, confirm with the user - explicitly, for this specific
action - covering:
  1. Scope: does the blast radius match intent? (-target lists checked)
  2. Environment: right Terraform workspace / AWS profile? Wrong-workspace
     commands do not error here - they silently hit the wrong cloud
     (constraint C6's history).
  3. Recoverability: what is the way back if this is wrong? State it.
  4. Authorization: was THIS action requested, or is it a shortcut past
     some other obstacle (a failing hook, a held lock)? If the latter,
     surface the obstacle instead.

Once the user has confirmed, re-run the same command prefixed with
LOOPENG_CONFIRMED=1
EOF
    exit 2
  fi
fi

exit 0
