#!/usr/bin/env bash
# Stop hook (fires when the agent finishes responding): loop-state
# persistence nudge - the mechanical backstop for loop-close step 6 and
# the loop-warden's "state-file staleness" check.
#
# If the working tree has substantive tracked changes but neither state
# file (plan.md / completed.md) is among them, remind that loop state may
# be drifting from reality. Warn-only (exit 0): plenty of turns
# legitimately change code without closing a loop - the nudge exists so a
# session that DID close a loop can't end with the backward-state file
# untouched by accident.
#
# Deferred documentation is how this drift happens: "done" recorded a
# session later is reconstructed from memory, and memory relaxes toward
# whatever the current state satisfies.

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 0

changed="$(git diff --name-only HEAD 2>/dev/null)"

# Nothing changed, or git unavailable: stay silent.
[ -z "$changed" ] && exit 0

# State files already touched: discipline held, stay silent.
if echo "$changed" | grep -qE '^(plan\.md|completed\.md)$'; then
  exit 0
fi

# Only trivial/doc-only changes: don't nag.
if ! echo "$changed" | grep -qE '\.(py|ts|tsx|tf|ya?ml|sh|json)$'; then
  exit 0
fi

cat >&2 <<EOF
NUDGE [loopengfable/hooks/stop-state-persistence-nudge.sh]

Substantive files changed this session without plan.md/completed.md moving:
$(echo "$changed" | head -10)

If a loop was closed (or a real gap was found) this session, the state
files are due an update in this same sitting - see
loopengfable/skills/loop-close/SKILL.md step 6 and
loopengfable/skills/gap-capture/SKILL.md. If no loop event happened,
ignore this.
EOF

exit 0
