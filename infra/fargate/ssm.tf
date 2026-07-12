# Own copy of infra/lambda-gate/ssm.tf's secrets, at this stack's own path (local.ssm_prefix,
# network.tf) — not a read of infra/lambda-gate/'s parameters. Deliberate duplication, not an
# oversight: this stack doesn't depend on infra/lambda-gate/ at any layer, including runtime
# secret reads, so its ECS tasks can fetch secrets even if infra/lambda-gate/ was never applied
# (or was destroyed). Cost is real: secret values (infra/fargate/secrets.auto.tfvars, gitignored)
# now need to be kept in sync with infra/lambda-gate/secrets.auto.tfvars by hand.
#
# for_each can't iterate var.secrets directly — Terraform refuses a sensitive value as a
# for_each argument. The key *names* aren't secret, only the values are, so it's safe to iterate
# the nonsensitive key set and look each value up from the still-sensitive map.
resource "aws_ssm_parameter" "secrets" {
  for_each = nonsensitive(toset(keys(var.secrets)))

  name  = "${local.ssm_prefix}/${each.value}"
  type  = "SecureString"
  value = var.secrets[each.value]
}

# Not a secret, unlike the block above — the CD dispatcher's smoke-check step
# (cd-ecs-deploy-steps.md) reads this via `aws ssm get-parameter`, since a
# GitHub Actions runner has no access to this stack's Terraform state and the
# domain can't be a static GitHub Variable (no custom domain this phase, so
# the auto-generated hostname changes on every destroy/reapply). This
# stack's own parameter, not a read of infra/lambda-gate/'s — same
# independence rationale as the secrets block above. See
# grand-enterprize-deploy-steps.md's "Follow-Up (2026-07-11)" section.
resource "aws_ssm_parameter" "cloudfront_domain" {
  name  = "${local.ssm_prefix}/cloudfront_domain"
  type  = "String"
  value = aws_cloudfront_distribution.this.domain_name
}
