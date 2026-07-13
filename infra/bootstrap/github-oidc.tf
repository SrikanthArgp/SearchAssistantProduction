# GitHub's OIDC identity provider — one per AWS account, shared by every workflow/role that
# assumes a role via token.actions.githubusercontent.com. Registered here (not in
# infra/lambda-gate/ or infra/fargate/) because it's account-level and shared by both deploy
# roles below, matching plan.md's Phase 18 step 1 clarification: "the provider is shared; the
# deploy role is not." See real-aws-cicd-setup.md for the full rationale/walkthrough.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

data "aws_caller_identity" "current" {}

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
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = "arn:aws:s3:::crag-terraform-state-${data.aws_caller_identity.current.account_id}"
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
          "ecr:CreateRepository", "ecr:DescribeRepositories", "ecr:DeleteRepository",
          "ecr:TagResource", "ecr:ListTagsForResource",
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
          "lambda:AddPermission", "lambda:RemovePermission", "lambda:TagResource", "lambda:ListTags",
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
        Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DescribeLogGroups", "logs:TagResource", "logs:ListTagsForResource", "logs:ListTagsLogGroup"]
        Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/crag-prod-backend*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:PutBucketPublicAccessBlock", "s3:GetBucketPolicy", "s3:GetBucketTagging", "s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::crag-prod-frontend", "arn:aws:s3:::crag-prod-frontend/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParametersByPath", "ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:ListTagsForResource"]
        Resource = "arn:aws:ssm:*:*:parameter/crag/prod/*"
      },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "arn:aws:kms:*:*:alias/aws/ssm" },
      {
        # Needed only on the full-apply (infra-changed) path — Terraform re-asserts
        # lambda_exec's role on every apply, even when the role itself is unchanged.
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:TagRole", "iam:ListRoleTags", "iam:PassRole"]
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
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = "arn:aws:s3:::crag-terraform-state-${data.aws_caller_identity.current.account_id}"
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
          "ecr:CreateRepository", "ecr:DescribeRepositories", "ecr:DeleteRepository",
          "ecr:TagResource", "ecr:ListTagsForResource",
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
        Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DescribeLogGroups", "logs:TagResource", "logs:ListTagsForResource", "logs:ListTagsLogGroup"]
        Resource = "arn:aws:logs:*:*:log-group:/ecs/crag-prod-ecs*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:CreateBucket", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:PutBucketPublicAccessBlock", "s3:GetBucketPolicy", "s3:GetBucketTagging", "s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::crag-prod-ecs-frontend", "arn:aws:s3:::crag-prod-ecs-frontend/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParametersByPath", "ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:ListTagsForResource"]
        Resource = "arn:aws:ssm:*:*:parameter/crag/prod-ecs/*"
      },
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:GenerateDataKey"], Resource = "arn:aws:kms:*:*:alias/aws/ssm" },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:TagRole", "iam:ListRoleTags", "iam:PassRole"]
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
