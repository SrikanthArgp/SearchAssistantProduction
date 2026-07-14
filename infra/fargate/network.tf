locals {
  name_prefix = "${var.project_name}-${var.environment}-ecs"

  # "-ecs" suffix on the environment segment, not just the name — this stack's SSM parameters
  # (ssm.tf) live at their own path, distinct from infra/lambda-gate/ssm.tf's
  # /{project_name}/{environment}/*, so both stacks' aws_ssm_parameter resources can exist (and
  # be applied/destroyed) independently without a literal SSM parameter-name collision.
  ssm_prefix = "/${var.project_name}/${var.environment}-ecs"
}

# Fargate tasks always require a VPC, unlike Phase 15's Lambda, which deliberately stayed out of
# one entirely — so unlike ecs.tf's ECR repo and iam.tf's SSM path, there's nothing to reuse from
# infra/lambda-gate/ here. Public subnets + an Internet Gateway, not private subnets + NAT
# Gateway, keeps this phase's mandatory networking cost at the IGW (free) instead of NAT
# (~$32/month) — plan.md Phase 16 step 1.
data "aws_availability_zones" "available" {
  state = "available"
}

# Re-touched (no content change) to force paths-filter's slow-path detection on the next
# cd-ecs.yml dispatch — same recurring single-commit-diff gap documented in ecr.tf. The prior
# full apply got partway (security group created, old task definition destroyed) before failing
# on a missing IAM permission (see infra/bootstrap/github-oidc.tf's cd_ecs_compute fix), and the
# fix commit itself didn't touch infra/fargate/**, so this stack still needs one more full-apply
# pass to actually finish creating everything.
#
# Re-touched again (2026-07-14, still no content change): LocalStack was reset (fresh container,
# infra/bootstrap/ reapplied) so this stack has no resources at all right now, but the last real
# commit only touched docs — same gap, same recovery.
#
# Re-touched a third time in the same commit as the terraform_wrapper: false fix (cd-ecs.yml) —
# bundled deliberately so this dispatch doesn't repeat the documented "next commit only touched
# workflow YAML" gotcha from infra/lambda-gate/ecr.tf's comment history.

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# Two AZs — the minimum an ALB requires, and the smallest subnet count that satisfies it.
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.name_prefix}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ALB open on 80 only — no ACM cert is obtainable for either LocalStack or a real ALB's own
# *.elb.amazonaws.com DNS name without owning a custom domain, and this phase has none (same "no
# custom domain" constraint infra/lambda-gate/cloudfront.tf's viewer_certificate already
# accepted). CloudFront still terminates HTTPS for viewers at its own edge with the default
# *.cloudfront.net cert (cloudfront.tf) — only the CloudFront-to-ALB hop is plain HTTP, the same
# trust boundary infra/lambda-gate/cloudfront.tf already accepts for its API Gateway origin.
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "ALB: public HTTP in (CloudFront origin), all egress"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-alb" }
}

# Task reachable only from the ALB's own security group, not the public internet directly, even
# though the task also carries a public IP (assign_public_ip in ecs.tf) — the public IP exists so
# the task can reach Supabase/Upstash/OpenAI/Tavily over the Internet Gateway without a NAT
# Gateway, not so the ALB's own health checks/routing can be bypassed.
resource "aws_security_group" "ecs_task" {
  name        = "${local.name_prefix}-task"
  # No apostrophe here (unlike the comment above) - EC2's CreateSecurityGroup only accepts
  # descriptions from a-zA-Z0-9. _-:/()#,@[]+=&;{}!$* - apostrophes are rejected outright, a real
  # gap found on this stack's first real-AWS apply.
  description = "ECS task: only the ALB security group can reach the container port; all egress"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-task" }
}
