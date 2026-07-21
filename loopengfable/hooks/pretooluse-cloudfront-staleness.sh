#!/usr/bin/env bash
# Constraint C4 (HOOK, warn-only): CloudFront domain staleness warning.
# PreToolUse hook, matcher: Bash. Exit 0 always (warn, never block) -
# stderr surfaces the warning without stopping the call, because touching a
# known-old domain is sometimes legitimate (comparing old vs. new).
#
# History: applies that touch origin/OAC config force-replace the
# distribution and mint a new random *.cloudfront.net domain. On 2026-07-14
# both live stacks rotated silently; the in-pipeline smoke check couldn't
# catch it (it reads the CURRENT domain from SSM - structurally
# always-green, an admissibility Test 3 failure). "This site can't be
# reached" right after a green CD run is the rotation signature, not an
# outage.

input="$(cat)"

if echo "$input" | grep -qE '[a-z0-9]{13,14}\.cloudfront\.net'; then
  cat >&2 <<'EOF'
WARNING [constraint C4 - loopengfable/hooks/pretooluse-cloudfront-staleness.sh]

This command references a literal *.cloudfront.net domain. These domains
are NOT stable on this project - any apply touching origin/OAC config
force-replaces the distribution and mints a new domain (it happened
2026-07-14 to both live stacks at once).

If this domain came from memory, a doc, or earlier in the conversation
rather than a fresh fetch, re-fetch first (with MSYS_NO_PATHCONV=1 - C1):
  aws ssm get-parameter --profile crag-real-aws --name /crag/prod/cloudfront_domain --query 'Parameter.Value' --output text
  aws ssm get-parameter --profile crag-real-aws --name /crag/prod-ecs/cloudfront_domain --query 'Parameter.Value' --output text
(EKS: check infra/eks's terraform output / its own SSM path.)

Proceeding anyway - this is a warning, not a block.
EOF
fi

exit 0
