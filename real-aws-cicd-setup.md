# Configuring Real AWS for GitHub Workflows (Stage C)

**Status (2026-07-13): CLOSED for the Lambda target.** Every step below was actually run against
the real account, `target: lambda, environment: aws` went fully green, and a real chat session was
manually tested end-to-end in a browser. Eleven real, previously-undiscovered gaps were found and
fixed along the way — none anticipated by this doc as originally written. See "What Actually
Happened" at the end of this doc for the short version, or `completed.md`'s Phase 15/18 Stage C
entry for the full list with root causes. **`target: fargate` has not been dispatched against real
AWS yet** — `cd-ecs-deploy-role` picked up most of the same IAM fixes proactively, but ECS/ALB/VPC
have their own resource-creation surface and likely their own new gaps, untested so far.

Scope: one-time setup to make `environment: aws` actually work for `.github/workflows/cd.yml`
(dispatching to `cd-lambda.yml`/`cd-ecs.yml`) against the real AWS account, now that it exists.
Everything up to this point (Phase 15/16 Stage A/B, Phase 18/19) was built and verified against
LocalStack only — see `completed.md`'s Phase 15/16/18/19 entries. This doc closes the gaps those
entries flag as "not yet done": the shared Terraform state backend on real AWS, the GitHub OIDC
provider, the two deploy roles (`cd-lambda-deploy-role`/`cd-ecs-deploy-role`), the
`AWS_ACCOUNT_ID` repo Variable, and a real answer for `var.secrets` in `aws` mode (currently
resolves to an empty string — see Step 5, this **will break the first real deploy** if skipped).

Target repo for all `gh`/GitHub UI steps below: `SrikanthArgp/SearchAssistantProduction` (the
`github` remote — the actual CD push target, distinct from `origin`, per
`github-workflow-trigger.md`).

Nothing here touches `infra/lambda-gate/` or `infra/fargate/`'s own resource definitions — those
are already correct and were already proven end-to-end on LocalStack. This is purely account-level
plumbing: state backend, identity, and secrets delivery.

---

## 0. Prerequisites

- A real AWS account, with a user/role you can authenticate as locally (console or `aws configure
  sso` / access keys) that has effectively admin rights — you only use this once, to bootstrap the
  state backend and the OIDC provider/deploy roles. Nothing in this doc asks you to give GitHub
  Actions long-lived credentials.
- `aws` CLI and `terraform` (1.15.7, matching what's already used) installed locally.
- `gh` CLI authenticated against `SrikanthArgp/SearchAssistantProduction`.
- Decide your region up front. `cd-lambda.yml`/`cd-ecs.yml` currently **hardcode**
  `AWS_REGION: us-east-1` in their own `env:` block (not read from a GitHub Variable, despite
  `cd-dispatcher-steps.md`'s original design sketch assuming `vars.AWS_REGION` — the two drifted
  when the workflows were actually built). Easiest path: keep everything in `us-east-1`. If you
  want a different region, you must edit `AWS_REGION` in both workflow files, not just set a repo
  Variable — a Variable alone won't be read.

---

## 1. Set up a local AWS CLI profile for the one-time bootstrap

```bash
aws configure --profile crag-real-aws
# AWS Access Key ID / Secret Access Key / region (us-east-1) / output format (json)
```

This profile is only ever used from your machine, for the one-time Terraform applies in Steps 2
and 3. It is never given to GitHub.

---

## 2. Apply `infra/bootstrap` against real AWS (shared Terraform state backend)

`infra/bootstrap` creates the S3 bucket + DynamoDB lock table that `infra/lambda-gate/` and
`infra/fargate/` both point their own `backend "s3" {}` blocks at (via `-backend-config`). It uses
**local** Terraform state itself (there's nothing else for it to point at — it's the thing that
creates the remote backend), so this step is a manual, human-run apply, same convention the
LocalStack pass already used.

S3 bucket names must be globally unique across all of AWS, not just your account — the existing
`crag-terraform-state` default almost certainly collides with someone else's bucket. Suffix it
with your account ID:

```bash
cd infra/bootstrap
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile crag-real-aws --query Account --output text)
terraform apply \
  -var="use_localstack=false" \
  -var="aws_profile=crag-real-aws" \
  -var="state_bucket_name=crag-terraform-state-${AWS_ACCOUNT_ID}" \
  -auto-approve
```

Note the bucket name — you need it for Step 3's Terraform and for updating both stacks'
`backend-aws.hcl` files next.

Update both placeholder files (currently marked `TODO: confirm globally-unique name before real
AWS` / `before Stage C`):

- `infra/lambda-gate/backend-aws.hcl`
- `infra/fargate/backend-aws.hcl`

Set `bucket = "crag-terraform-state-<your-account-id>"` in both (the `key` fields already differ
between the two files — leave those as-is, that's what keeps the two stacks' state from
colliding in the one shared bucket).

---

## 3. Register the GitHub OIDC provider + the two deploy roles

One-time, applied from the same local profile. Add a new file so it's clearly scoped as
account-level/shared infrastructure, same spirit as `infra/bootstrap` itself:

**`infra/bootstrap/github-oidc.tf`** (new file):

```hcl
# GitHub's OIDC identity provider — one per AWS account, shared by every workflow/role that
# assumes a role via token.actions.githubusercontent.com. Registered here (not in
# infra/lambda-gate/ or infra/fargate/) because it's account-level and shared by both deploy
# roles below, matching plan.md's Phase 18 step 1 clarification: "the provider is shared; the
# deploy role is not."
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

locals {
  github_repo = "SrikanthArgp/SearchAssistantProduction"
}

# ---------------------------------------------------------------------------
# cd-lambda-deploy-role — used by cd-lambda.yml in `aws` mode only.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "cd_lambda_deploy" {
  name = "cd-lambda-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # Restricted to pushes to main specifically — not repo:<owner>/* or a wildcard ref.
        # Too broad here lets any branch (or any repo under the owner) assume this role.
        StringLike = { "token.actions.githubusercontent.com:sub" = "repo:${local.github_repo}:ref:refs/heads/main" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cd_lambda_terraform_state" {
  name = "terraform-state"
  role = aws_iam_role.cd_lambda_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::crag-terraform-state-${data.aws_caller_identity.current.account_id}"
        Condition = { StringLike = { "s3:prefix" = ["crag/prod/lambda-gate/*"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::crag-terraform-state-${data.aws_caller_identity.current.account_id}/crag/prod/lambda-gate/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:*:*:table/crag-terraform-locks"
      }
    ]
  })
}

resource "aws_iam_role_policy" "cd_lambda_ecr" {
  name = "ecr"
  role = aws_iam_role.cd_lambda_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository", "ecr:DescribeRepositories", "ecr:DeleteRepository", "ecr:TagResource",
          "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
          "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
        ]
        Resource = "arn:aws:ecr:*:*:repository/crag-backend"
      }
    ]
  })
}

resource "aws_iam_role_policy" "cd_lambda_compute" {
  name = "compute"
  role = aws_iam_role.cd_lambda_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:CreateFunction", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration",
          "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:DeleteFunction",
          "lambda:AddPermission", "lambda:RemovePermission", "lambda:TagResource",
          "lambda:CreateFunctionUrlConfig", "lambda:GetFunctionUrlConfig",
          "lambda:UpdateFunctionUrlConfig", "lambda:DeleteFunctionUrlConfig",
        ]
        Resource = "arn:aws:lambda:*:*:function:crag-prod-backend*"
      },
      # apigatewayv2 has no useful resource-level ARN restriction for most of these actions —
      # scoped to the service instead, same tradeoff every apigatewayv2 Terraform role makes.
      { Effect = "Allow", Action = ["apigateway:*"], Resource = "arn:aws:apigateway:*::/apis*" },
      # CloudFront, its cache/origin-request policies, and OACs don't support resource-level
      # IAM restriction at all (AWS-wide limitation, not a scoping choice made here).
      { Effect = "Allow", Action = ["cloudfront:*"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DescribeLogGroups", "logs:TagResource"]
        Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/crag-prod-backend*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:PutBucketPublicAccessBlock", "s3:GetBucketPolicy", "s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::crag-prod-frontend", "arn:aws:s3:::crag-prod-frontend/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParametersByPath", "ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource"]
        Resource = "arn:aws:ssm:*:*:parameter/crag/prod/*"
      },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "arn:aws:kms:*:*:alias/aws/ssm" },
      {
        # Needed only on the full-apply (infra-changed) path — Terraform re-asserts
        # lambda_exec's role on every apply, even when the role itself is unchanged.
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:TagRole", "iam:PassRole"]
        Resource = "arn:aws:iam::*:role/crag-prod-lambda-exec"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# cd-ecs-deploy-role — used by cd-ecs.yml in `aws` mode only. Independent of the role above:
# no shared trust policy, no lambda:* permissions.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "cd_ecs_deploy" {
  name = "cd-ecs-deploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${local.github_repo}:ref:refs/heads/main" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cd_ecs_terraform_state" {
  name = "terraform-state"
  role = aws_iam_role.cd_ecs_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::crag-terraform-state-${data.aws_caller_identity.current.account_id}"
        Condition = { StringLike = { "s3:prefix" = ["crag/prod/fargate/*"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:aws:s3:::crag-terraform-state-${data.aws_caller_identity.current.account_id}/crag/prod/fargate/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:*:*:table/crag-terraform-locks"
      }
    ]
  })
}

resource "aws_iam_role_policy" "cd_ecs_ecr" {
  name = "ecr"
  role = aws_iam_role.cd_ecs_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      {
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository", "ecr:DescribeRepositories", "ecr:DeleteRepository", "ecr:TagResource",
          "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
          "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
        ]
        Resource = "arn:aws:ecr:*:*:repository/crag-prod-ecs-backend"
      }
    ]
  })
}

resource "aws_iam_role_policy" "cd_ecs_compute" {
  name = "compute"
  role = aws_iam_role.cd_ecs_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:*"]
        Resource = ["arn:aws:ecs:*:*:cluster/crag-prod-ecs", "arn:aws:ecs:*:*:service/crag-prod-ecs/*", "arn:aws:ecs:*:*:task-definition/crag-prod-ecs-backend:*"]
      },
      # register-task-definition itself has no useful resource-level restriction.
      { Effect = "Allow", Action = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"], Resource = "*" },
      # VPC/subnet/IGW/route-table/security-group/ALB/target-group creation calls largely don't
      # support resource-level IAM restriction either (standard EC2/ELB limitation) — scoped to
      # the service namespace, same tradeoff as CloudFront above.
      { Effect = "Allow", Action = ["ec2:*"], Resource = "*" },
      { Effect = "Allow", Action = ["elasticloadbalancing:*"], Resource = "*" },
      { Effect = "Allow", Action = ["application-autoscaling:*"], Resource = "*" },
      { Effect = "Allow", Action = ["cloudfront:*"], Resource = "*" },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DescribeLogGroups", "logs:TagResource"]
        Resource = "arn:aws:logs:*:*:log-group:/ecs/crag-prod-ecs*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:PutBucketPublicAccessBlock", "s3:GetBucketPolicy", "s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::crag-prod-ecs-frontend", "arn:aws:s3:::crag-prod-ecs-frontend/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParametersByPath", "ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource"]
        Resource = "arn:aws:ssm:*:*:parameter/crag/prod-ecs/*"
      },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "arn:aws:kms:*:*:alias/aws/ssm" },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:TagRole", "iam:PassRole"]
        Resource = ["arn:aws:iam::*:role/crag-prod-ecs-execution", "arn:aws:iam::*:role/crag-prod-ecs-task"]
      },
      {
        # First-time-in-account only: ECS and ELB each need a service-linked role
        # (AWSServiceRoleForECS / AWSServiceRoleForElasticLoadBalancing) that AWS creates
        # automatically the first time either service is used — but the calling principal
        # needs permission to trigger that creation. No-op (AlreadyExists, harmless) on every
        # apply after the first.
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "arn:aws:iam::*:role/aws-service-role/*"
      },
    ]
  })
}

data "aws_caller_identity" "current" {}
```

Add the `tls` provider to `infra/bootstrap/versions.tf`'s `required_providers` block if it isn't
already there:

```hcl
tls = {
  source  = "hashicorp/tls"
  version = "~> 4.0"
}
```

Apply it:

```bash
cd infra/bootstrap
terraform apply \
  -var="use_localstack=false" \
  -var="aws_profile=crag-real-aws" \
  -var="state_bucket_name=crag-terraform-state-${AWS_ACCOUNT_ID}" \
  -auto-approve
```

Capture the two role ARNs for your own records (not needed by GitHub directly — the workflows
already construct `arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/cd-lambda-deploy-role` /
`.../cd-ecs-deploy-role` from the account ID Variable you set next):

```bash
aws iam get-role --profile crag-real-aws --role-name cd-lambda-deploy-role --query Role.Arn --output text
aws iam get-role --profile crag-real-aws --role-name cd-ecs-deploy-role --query Role.Arn --output text
```

---

## 4. Set the `AWS_ACCOUNT_ID` GitHub repo Variable

Settings → Secrets and variables → Actions → **Variables** tab (not Secrets — this value isn't
sensitive on its own, see `cd-dispatcher-steps.md`'s rationale) → New repository variable:

```bash
gh variable set AWS_ACCOUNT_ID --repo SrikanthArgp/SearchAssistantProduction --body "$AWS_ACCOUNT_ID"
```

`AWS_REGION` is **not** a Variable in this repo's actual workflows (see Step 0) — nothing to set
there unless you're also changing the hardcoded region in the workflow files.

---

## 5. Fix `var.secrets` for `aws` mode — required, currently unset

Both workflows currently resolve `TF_VAR_secrets` like this:

```yaml
TF_VAR_secrets: ${{ inputs.environment == 'localstack' && secrets.LOCALSTACK_SECRETS_JSON || '' }}
```

In `aws` mode this evaluates to an empty string, which isn't valid for a `map(string)` variable —
`terraform apply` will fail immediately on the first (infra-changed) deploy, before touching any
real resource. This is a known, already-flagged open gap (`completed.md`'s Phase 18/19
LocalStack-verification entry: *"Real AWS deploys still have no answer to this — open
follow-up"*), not something new found here.

**Fix, mirroring the existing `LOCALSTACK_SECRETS_JSON` pattern exactly:**

1. Create a GitHub **Secret** (not Variable) called `AWS_SECRETS_JSON`, holding the same 9-key
   JSON map `infra/lambda-gate/secrets.auto.tfvars`'s `secrets = { ... }` block has, but with your
   **real production values** (`REDIS_URL` as a real `rediss://` Upstash URL — not `redis://`,
   that exact mistake bit this project twice already per `completed.md` — `OPENAI_API_KEY`,
   `TAVILY_API_KEY`, `JWT_SECRET_KEY`, `DATABASE_URL`, `DATABASE_URL_PSYCOPG`,
   `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `GRAFANA_OTLP_TOKEN`). Since real credentials are
   involved, do this yourself rather than pasting them into a chat — `github-workflow-trigger.md`'s
   "Re-creating `LOCALSTACK_SECRETS_JSON`" section has the exact extraction approach (parse the
   `.tfvars` file, pipe straight into `gh secret set`, never write plaintext to a location you
   don't immediately delete).

2. Edit both `.github/workflows/cd-lambda.yml` and `.github/workflows/cd-ecs.yml`, changing:

   ```yaml
   TF_VAR_secrets: ${{ inputs.environment == 'localstack' && secrets.LOCALSTACK_SECRETS_JSON || '' }}
   ```

   to:

   ```yaml
   TF_VAR_secrets: ${{ inputs.environment == 'localstack' && secrets.LOCALSTACK_SECRETS_JSON || secrets.AWS_SECRETS_JSON }}
   ```

   `fargate`/`lambda-gate` use **independent** `secrets.auto.tfvars` (deliberate duplication, see
   `infra/fargate/ssm.tf`'s comment) — but both are consumed via the one `TF_VAR_secrets` env var
   per job, scoped to whichever stack's `terraform apply` is running in that job. A single
   `AWS_SECRETS_JSON` GitHub Secret is fine for both as long as its 9 keys are the values you want
   both stacks to end up with in SSM; keep the two stacks' actual SSM values in sync the same way
   `secrets.auto.tfvars` already has to be kept in sync locally.

This is a real code change to the workflow files, not just GitHub configuration — make it (and
commit it) before your first `environment: aws` dispatch.

---

## 6. First dispatch

```bash
gh workflow run cd.yml --repo SrikanthArgp/SearchAssistantProduction --ref main \
  -f target=both -f environment=aws
gh run list --repo SrikanthArgp/SearchAssistantProduction --limit 1
gh run watch <run-id> --repo SrikanthArgp/SearchAssistantProduction --exit-status
```

Expect this to be slow (several minutes) — it's a full `terraform apply` from nothing for both
stacks, same shape as the first LocalStack run. Runs on `ubuntu-latest` this time, not the
self-hosted runner (that's `localstack`-only) — no runner registration step needed here.

Consider dispatching `target: lambda` first, confirming it end-to-end, then `target: fargate`
separately — cheaper to isolate a first-real-AWS-run problem to one stack than to debug both at
once.

---

## 7. Verify

```bash
DOMAIN=$(aws ssm get-parameter --profile crag-real-aws --name /crag/prod/cloudfront_domain --query 'Parameter.Value' --output text)
curl https://$DOMAIN/health
# swap /crag/prod/ for /crag/prod-ecs/ for the Fargate stack
```

Expect `{"status":"ok","db":true,"redis":true}`. Also open `https://$DOMAIN/login.html` in an
actual browser — plain `/login` (no `.html`) is one of the two things LocalStack could never
verify (see below).

**Specifically re-check the two things flagged as LocalStack fidelity gaps, unverifiable until
now** (`completed.md`'s Phase 15 entry, `enterprize-deploy-steps.md` step 15):

1. **CloudFront Function URL rewrite** (`/login` → `/login.html`) — LocalStack never executes
   `viewer-request` CloudFront Functions at all; this is the first real test of that path.
2. **`origin_read_timeout = 60` on the streaming behavior** — send a chat message that takes
   longer than 30s and confirm it doesn't time out. LocalStack's own CloudFront-to-origin proxy
   hardcoded a 30s timeout regardless of this setting; real AWS is expected to honor it, but
   hasn't been proven yet.

---

## 8. Cost / teardown note

Both stacks bill continuously once applied (ALB, NAT-free VPC is cheap but not free; Lambda/ECS
are pay-per-use but CloudFront/S3/SSM have small standing costs too). This project's existing
convention (per `plan.md`'s Cost Profile Summary) is `terraform destroy` between demos rather than
leaving stacks live indefinitely:

```bash
cd infra/lambda-gate && terraform destroy -auto-approve
cd ../fargate && terraform destroy -auto-approve
```

Leave `infra/bootstrap` (state bucket/lock table) and the OIDC provider/deploy roles from Step 3
alone — those are account-level, meant to persist across destroy/reapply cycles of the two deploy
stacks themselves.

---

## What Actually Happened (2026-07-13)

Every step above was run for real. Step 3's Terraform block in this doc is the **original plan**
version — the real `infra/bootstrap/github-oidc.tf` has since grown several more IAM permissions
found only by actually applying and dispatching; treat that file, not this doc's embedded snippet,
as the source of truth for the current policy. Short version of what was missing and had to be
added, in the order it was found (`completed.md`'s Phase 15/18 Stage C entry has the full story
with root causes and exact errors):

- `hashicorp/setup-terraform` in both CD workflows — `ubuntu-latest` ships no Terraform binary.
- `TF_VAR_use_localstack: ${{ inputs.environment == 'localstack' }}` in both CD workflows — this
  variable was never actually set, silently defaulting to `true` even in `aws` mode.
- `providers.tf`'s `profile` gated behind `use_localstack` in both stacks, matching `access_key`/
  `secret_key`'s existing gating.
- `ecr:ListTagsForResource`, `lambda:ListTags`, `logs:ListTagsForResource`/`ListTagsLogGroup`,
  `ssm:ListTagsForResource`, `iam:ListRoleTags`, `s3:GetBucketTagging` (or broader `s3:Get*`/
  `s3:List*`) — Terraform reads tags back unconditionally, even when nothing sets any.
- `logs:DescribeLogGroups` and `ssm:DescribeParameters` as their own `Resource: "*"` statements —
  neither supports resource-level restriction at all.
- `ssm:GetParameters` (plural) alongside `ssm:GetParameter` (singular) — distinct actions.
- `aws_ecr_repository_policy` granting `lambda.amazonaws.com` pull access — **a real design gap**,
  not an IAM-role issue: `ecr.tf`'s original claim that same-account Lambda pulls need no
  repository policy was wrong.
- `lambda:ListVersionsByFunction`, `lambda:GetPolicy`, `iam:ListInstanceProfilesForRole` — assorted
  post-create read-back permissions, found one apply at a time.
- A second `aws_lambda_permission` (`lambda:InvokeFunction`, alongside the existing
  `lambda:InvokeFunctionUrl`) for CloudFront's service principal — AWS's own OAC-for-Lambda docs
  require both; only one existed.
- **Not an infra gap at all**: CloudFront's OAC overwrites the `Authorization` header with its own
  AWS SigV4 signature before forwarding to the streaming Lambda's Function URL origin, which broke
  this app's own JWT bearer auth on that path (chat history + chat send, both 401'd) even after
  every other piece was fixed. Real application-code fix, not Terraform: the frontend now also
  sends the token via a custom `X-Auth-Token` header (which OAC doesn't touch), and the backend
  checks that header first, falling back to `Authorization` — see `backend/auth/dependencies.py`'s
  `extract_bearer_token` and `frontend/lib/api.ts`'s `rawFetch`.

End state: `https://d1at67obwaojws.cloudfront.net` serves the real app — login, logout, session
list, chat history, and streaming a new chat message all confirmed working in an actual browser,
backed by the real Supabase Postgres and Upstash Redis. Nothing has been torn down.
