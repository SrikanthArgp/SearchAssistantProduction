# One SecureString per backend/config.py's _SSM_SECRET_KEYS entry, at the exact path prefix
# config.py's bootstrap_env() reads (SSM_PARAMETER_PREFIX, default "/crag/prod" — kept in sync
# with var.project_name/var.environment here rather than hardcoded twice).
#
# for_each can't iterate var.secrets directly — Terraform refuses a sensitive value as a
# for_each argument (the key set could otherwise leak sensitive data via resource addresses).
# The key *names* (OPENAI_API_KEY, etc.) aren't secret, only the values are, so it's safe to
# iterate the nonsensitive key set and look each value up from the still-sensitive map.
resource "aws_ssm_parameter" "secrets" {
  for_each = nonsensitive(toset(keys(var.secrets)))

  name  = "/${var.project_name}/${var.environment}/${each.value}"
  type  = "SecureString"
  value = var.secrets[each.value]
}

# Not a secret, unlike the block above — the CD dispatcher's smoke-check step
# (cd-lambda-deploy-steps.md) reads this via `aws ssm get-parameter`, since a
# GitHub Actions runner has no access to this stack's Terraform state and the
# domain can't be a static GitHub Variable (no custom domain this phase, so
# the auto-generated hostname changes on every destroy/reapply). See
# enterprize-deploy-steps.md's "Follow-Up (2026-07-11)" section.
resource "aws_ssm_parameter" "cloudfront_domain" {
  name  = "/${var.project_name}/${var.environment}/cloudfront_domain"
  type  = "String"
  value = aws_cloudfront_distribution.this.domain_name
}
