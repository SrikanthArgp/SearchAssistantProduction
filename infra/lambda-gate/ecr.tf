# CORRECTION (2026-07-13, real real-AWS apply): the header comment here used to claim
# "Same-account Lambda pulls need no repository policy — only cross-account pulls would." That's
# wrong. aws_lambda_function.backend/.backend_stream both failed to create with "Lambda does not
# have permission to access the ECR image. Check the ECR permissions." — a real AWS-side check
# distinct from any IAM identity policy (our deploy role's own ECR permissions were already
# sufficient; this is Lambda's control plane checking the repository's own resource policy before
# it will let the Lambda service pull the image), and it applies within the same account too.
# Fixed below with aws_ecr_repository_policy.backend, granting principal lambda.amazonaws.com
# pull access scoped to this account's Lambda functions.
#
# LocalStack instances are ephemeral — a restarted/reset one has none of this stack's resources,
# even though this repo's git state (and Terraform's remote state, once infra/bootstrap/ is
# reapplied) says otherwise. cd-lambda.yml's own path-filter only runs its full
# init/apply/build-and-push path when a commit's diff touches infra/lambda-gate/**, so a
# non-infra commit against a freshly reset LocalStack hits the exact chicken-and-egg gap
# completed.md's Phase 18/19 entry already documents (empty ECR breaks `aws ecr
# get-login-password`). Recovering from that should always go through a real CD run whose diff
# touches this directory (so the workflow's own steps do the work) — never by manually running
# infra/lambda-gate/scripts/*.sh or hand-invoking docker/terraform outside the workflow, since
# that only hides the gap instead of proving the pipeline can self-heal.
#
# A second, related gap found on the very first real-AWS dispatch (2026-07-13): dorny/paths-filter
# on a workflow_dispatch event (no `before` field in the payload) only diffs the single
# immediately-preceding commit, not cumulative changes since the last successful deploy — visible
# in the run log as "'before' field is missing in event payload - changes will be detected from
# last commit". A commit that touched infra/lambda-gate/** correctly took the slow path but failed
# before creating any real resources (a separate bug, since fixed); the very next commit only
# touched workflow YAML, so the filter said "no infra changes" and took the fast path against a
# stack that didn't exist yet — `aws ecr get-login-password` / `docker push` failed with "The
# repository with name 'crag-backend' does not exist". Same recovery as above: the next commit
# needs to actually touch this directory.
#
# A third gap on the same first dispatch: this resource's own create succeeded (confirmed via
# `aws ecr describe-repositories` directly), but the apply still failed on the post-create tag
# read-back (ecr:ListTagsForResource, missing from the deploy role's IAM policy — fixed in
# infra/bootstrap/github-oidc.tf). Confirmed aws_ecr_repository.backend was still recorded in
# Terraform state despite that later failure, so no "already exists" conflict on retry.
#
# A fourth gap, same first-real-AWS pass: the full apply (lambda.tf/apigateway.tf/cloudfront.tf/
# s3.tf/ssm.tf all at once) partially succeeded before hitting a batch of read-permission
# AccessDenied errors (iam:ListAttachedRolePolicies, logs:DescribeLogGroups,
# ssm:DescribeParameters, s3:GetBucketAcl — fixed in infra/bootstrap/github-oidc.tf) —
# aws_apigatewayv2_stage.default and aws_cloudfront_function.url_rewrite were both created before
# the batch of errors surfaced, confirming Terraform validates/reads the whole plan rather than
# stopping at the first resource that fails.
#
# A fifth gap, next retry: every resource applied successfully except the SSM secret parameters'
# tag read-back, which needed ssm:GetParameters (plural, batch-get — a distinct IAM action from
# ssm:GetParameter singular) that SSM's ListTagsForResource calls internally. Fixed in
# infra/bootstrap/github-oidc.tf.
#
# A sixth gap, next retry: that same failed attempt left aws_iam_role.lambda_exec tainted (create
# succeeded, a later read in the same apply errored), forcing a destroy+recreate on this retry —
# which itself needed iam:ListInstanceProfilesForRole, also fixed in
# infra/bootstrap/github-oidc.tf.
resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"

  force_delete = var.use_localstack
}

data "aws_caller_identity" "current" {}

# See the header comment above — required even for same-account Lambda pulls, not just
# cross-account ones.
#
# A seventh gap, next retry: both Lambda functions actually created successfully once the
# repository policy above existed, but failed on the post-create version read-back
# (lambda:ListVersionsByFunction, missing from the deploy role's IAM policy — fixed in
# infra/bootstrap/github-oidc.tf).
resource "aws_ecr_repository_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowLambdaPull"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Condition = {
        StringEquals = { "aws:sourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}
