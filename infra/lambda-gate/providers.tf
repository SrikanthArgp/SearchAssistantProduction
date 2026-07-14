# Re-touched (no content change) to force paths-filter's slow-path detection on the next
# cd-lambda.yml dispatch — same recurring single-commit-diff gap documented in ecr.tf. LocalStack
# was reset (fresh container, infra/bootstrap/ reapplied 2026-07-14) so this stack has no
# resources at all right now, but the last real commit only touched docs, so a non-infra diff
# would take the fast (image-only) path against a stack that doesn't exist yet.
#
# Re-touched again in the same commit as the terraform_wrapper: false fix (cd-lambda.yml) —
# bundled deliberately, not as two separate commits, so this dispatch doesn't repeat the
# documented "next commit only touched workflow YAML, so the filter said no infra changes"
# gotcha from this same file's earlier comment history.

provider "aws" {
  region = var.aws_region

  # Real gap found on the first real-AWS CD dispatch (2026-07-13): this was unconditional
  # (`profile = var.aws_profile`), not gated by use_localstack the way access_key/secret_key
  # below correctly are. var.aws_profile defaults to "localstack" — a named AWS CLI profile that
  # only exists in this dev machine's own ~/.aws/config, not on an ephemeral ubuntu-latest CD
  # runner authenticating via OIDC-minted env-var credentials. Failed with "loading configuration:
  # failed to get shared config profile, localstack". Only ever worked for LocalStack CI runs by
  # coincidence, since the self-hosted runner is this same dev machine. Root cause was one layer
  # deeper still: cd-lambda.yml/cd-ecs.yml never set TF_VAR_use_localstack at all, so this
  # variable itself silently defaulted to true on every real-AWS run too — fixed alongside this.
  profile = var.use_localstack ? var.aws_profile : null

  # See infra/bootstrap/main.tf's provider block for what each of these does — identical
  # reasoning, duplicated here because Terraform provider blocks can't be shared/imported
  # across root modules.
  access_key                  = var.use_localstack ? "test" : null
  secret_key                  = var.use_localstack ? "test" : null
  skip_credentials_validation = var.use_localstack
  skip_metadata_api_check     = var.use_localstack
  skip_requesting_account_id  = var.use_localstack
  s3_use_path_style           = var.use_localstack

  # Every service this phase's architecture touches (per enterprize-deploy-steps.md's wiring
  # table), routed at LocalStack's single edge port (4566) when use_localstack — real AWS
  # resolves each service's normal regional endpoint instead, so this block is skipped
  # entirely there. apigatewayv2 and cloudfront specifically need LocalStack Pro/Ultimate,
  # not the free Community edition — the rest (s3, dynamodb, iam, sts, lambda, ecr, ssm,
  # logs, kms) work on Community.
  dynamic "endpoints" {
    for_each = var.use_localstack ? [1] : []
    content {
      s3             = "http://localhost:4566"
      dynamodb       = "http://localhost:4566"
      iam            = "http://localhost:4566"
      sts            = "http://localhost:4566"
      lambda         = "http://localhost:4566"
      ecr            = "http://localhost:4566"
      ssm            = "http://localhost:4566"
      cloudwatchlogs = "http://localhost:4566"
      kms            = "http://localhost:4566"
      apigatewayv2   = "http://localhost:4566"
      cloudfront     = "http://localhost:4566"
    }
  }
}
