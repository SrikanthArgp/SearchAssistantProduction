# Same-account Lambda pulls need no repository policy (see enterprize-deploy-steps.md's
# wiring table) — only cross-account pulls would.
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
resource "aws_ecr_repository" "backend" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"

  force_delete = var.use_localstack
}
