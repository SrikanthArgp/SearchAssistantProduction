# Phase 20 — EKS Manual Deploy: Runbook (as-built)

Step-by-step commands to stand up the Phase 20 EKS deployment on real AWS from nothing, matching what's actually in `infra/eks/` and `gitops/multi-agent/` today — not the original design in [`eks-enterprize-deploy-steps.md`](./eks-enterprize-deploy-steps.md), which still describes a Secrets Store CSI Driver and a two-Terraform-config CloudFront split that were never built. See that doc's "Built vs. Designed" section for the full list of deviations this runbook already reflects. **Phase 21/ArgoCD is now built** (see [`ci-cd-eks-steps.md`](./ci-cd-eks-steps.md)) and handles the *ongoing* image-tag bump once this runbook's Stages 1–8 have stood the cluster up at least once — this runbook itself is still run entirely by hand, since Phase 21 never automates the initial cluster bring-up or Helm install, only redeploys of an already-bootstrapped cluster.

---

## Prerequisites

- Tools: `terraform`, `aws` CLI v2, `docker`, `kubectl`, `helm` v3
- `aws sts get-caller-identity --profile crag-real-aws` succeeds (reauth first if not — this profile isn't standard AWS SSO on this machine, so `aws sso login` won't work; use whatever this machine's normal reauth method is)
- `infra/bootstrap` already applied for real AWS (shared state bucket `crag-terraform-state-247673029324` + lock table `crag-terraform-locks`) — already done per `completed.md`, nothing to do here unless starting from a fresh AWS account
- `infra/eks/secrets.auto.tfvars` populated (gitignored) with the 9 keys `backend/config.py`'s `_SSM_SECRET_KEYS` expects: `DATABASE_URL`, `DATABASE_URL_PSYCOPG`, `REDIS_URL`, `JWT_SECRET_KEY`, `OPENAI_API_KEY`, `TAVILY_API_KEY`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, `GRAFANA_OTLP_TOKEN`

---

## Stage 1 — Terraform: cluster, nodes, IAM/IRSA, ECR, SSM, S3 (everything except CloudFront)

CloudFront can't be created yet — `cloudfront.tf`'s `data "aws_lb" "backend"` looks up the ALB by the tags the AWS Load Balancer Controller sets on it, and that ALB doesn't exist until the controller reconciles an `Ingress` in Stage 5. So this first apply deliberately targets everything *except* `cloudfront.tf`'s resources and the S3 bucket policy (which references the CloudFront distribution's ARN):

```bash
cd infra/eks
export AWS_PROFILE=crag-real-aws
terraform init -backend-config=backend-aws.hcl

terraform apply -var="use_localstack=false" \
  -target=aws_eks_node_group.this \
  -target=aws_iam_role_policy.backend_irsa_ssm \
  -target=aws_iam_role_policy.backend_irsa_kms \
  -target=aws_iam_role_policy.alb_controller_irsa \
  -target=aws_ecr_repository.backend \
  -target=aws_ssm_parameter.secrets \
  -target=aws_s3_bucket.frontend \
  -target=aws_internet_gateway.this \
  -target=aws_route_table.public \
  -target=aws_route_table_association.public
```

Targeting `aws_eks_node_group.this` and the two IRSA role policies pulls in their full dependency chain automatically — VPC, subnets, the EKS cluster, the node group, the OIDC provider, and both `backend_irsa`/`alb_controller_irsa` roles. **It does NOT pull in the IGW/route table/route-table-association** — this was this doc's own claim until a from-scratch redeploy on 2026-07-16 disproved it: Terraform's `-target` dependency closure only follows resources an attribute actually *references* (the node group/cluster reference `subnet_ids`, which pulls in the subnets and their VPC), and nothing in that chain references the route table back — the reference direction is the other way (route table → subnet via `route_table_id`/`subnet_id`). Omitting these three explicit targets leaves the public subnets with no route to the internet (falling back to the VPC's default main route table, local-only), so the node's `nodeadm` bootstrap can start but its EC2 API calls (`Fetching instance details`) never complete, and the node group eventually fails with `NodeCreationFailure: Instances failed to join the kubernetes cluster` after ~25-30 min. Confirmed via `aws ec2 get-console-output` showing `nodeadm` retrying `EC2/DescribeInstances` indefinitely, and `aws ec2 describe-route-tables`/`describe-internet-gateways` filtered to this stack coming back empty. Fix: destroy the failed node group (`terraform destroy -target=aws_eks_node_group.this`) and add the three targets above before recreating it.

## Stage 2 — Point kubectl at the cluster, confirm nodes

```bash
aws eks update-kubeconfig --name crag-prod-eks --region us-east-1
kubectl get nodes    # expect one t3.medium, Ready
```

If the node never goes `Ready`, this is the first real failure point in the whole stack — check `aws_eks_node_group` events / EC2 console before assuming anything downstream is broken.

## Stage 3 — Install the AWS Load Balancer Controller (cluster infra, its own Helm chart — not `gitops/multi-agent/`)

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

VPC_ID=$(aws eks describe-cluster --name crag-prod-eks --query 'cluster.resourcesVpcConfig.vpcId' --output text)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=crag-prod-eks \
  --set region=us-east-1 \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$(terraform output -raw alb_controller_irsa_role_arn)"

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller   # expect 2 Running
```

## Stage 4 — Build and push the backend image to this stack's own ECR

Same `backend/Dockerfile` every other deploy target uses — its Lambda Web Adapter layer is inert outside Lambda:

```bash
REPO_URI=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$REPO_URI"
docker build -t crag-prod-eks-backend:v1 ../../backend
docker tag crag-prod-eks-backend:v1 "$REPO_URI:v1"
docker push "$REPO_URI:v1"
```

## Stage 5 — Install the app chart

No CSI driver, no `SecretProviderClass`, no synced `Secret` — the backend pod reads SSM directly at runtime (`config.py`'s `bootstrap_env()`) via its IRSA-annotated `ServiceAccount`:

```bash
cd ../../gitops
helm upgrade --install multi-agent multi-agent -n default \
  --set image.repository="$(terraform -chdir=../infra/eks output -raw ecr_repository_url)" \
  --set image.tag=v1 \
  --set serviceAccount.roleArn="$(terraform -chdir=../infra/eks output -raw backend_irsa_role_arn)"
```

Wait for the ALB to actually get provisioned:

```bash
kubectl get pods -n default          # backend pod Running
kubectl get ingress -n default -w    # wait for ADDRESS to populate (~2-3 min) — that's the ALB DNS name
```

## Stage 6 — Terraform again, now for CloudFront + the S3 bucket policy

The `data "aws_lb"` lookup can resolve now that the ALB exists:

```bash
cd ../infra/eks
terraform apply -var="use_localstack=false"
```

## Stage 7 — Build and sync the frontend

**`MSYS_NO_PATHCONV=1` is not optional** — without it, Git Bash mangles `NEXT_PUBLIC_API_BASE_URL=/v1` into a Windows path rooted at the Git install dir, and the deployed app tries to `fetch()` a `file://` URL instead of a real API path (hit and fixed on this exact stack, 2026-07-16 — see `completed.md`'s Phase 20 entry).

```bash
cd ../../frontend
MSYS_NO_PATHCONV=1 NEXT_OUTPUT_MODE=export NEXT_PUBLIC_API_BASE_URL=/v1 npm run build
cd ../infra/eks
./scripts/sync_frontend.sh
DIST_ID=$(terraform state show aws_cloudfront_distribution.this | grep -m1 '^    id ' | awk '{print $3}' | tr -d '"')
aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths "/*"
```

## Stage 8 — Smoke test

```bash
terraform output -raw cloudfront_domain_name
curl -sf "https://$(terraform output -raw cloudfront_domain_name)/health"
```

Then a browser pass: register → login → create session → chat → SSE stream. **Note: the CloudFront domain is not stable across applies** — a `terraform apply` that replaces the distribution mints a new `*.cloudfront.net` domain. Always re-fetch it via `terraform output` rather than trusting a bookmarked URL.

---

## Known open gap: HPA won't report real values

No `metrics-server` is installed, so `kubectl get hpa` shows `cpu: <unknown>/70%` and autoscaling never actually triggers. To make it functional:

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server -n kube-system
```

---

## Teardown order (matters — don't skip)

The ALB was never a Terraform resource (the Load Balancer Controller created it out-of-band from an `Ingress`), so `terraform destroy` has no idea it exists and will not delete it. Deprovision it explicitly first, or it's left orphaned and billing hourly with nothing pointing at it:

```bash
helm uninstall multi-agent -n default          # triggers the controller to deprovision the ALB
# wait until confirmed gone: aws elbv2 describe-load-balancers
helm uninstall aws-load-balancer-controller -n kube-system
terraform destroy -var="use_localstack=false"  # only after the ALB is confirmed gone
```

EKS's control-plane fee (~$0.10/hr, ~$73/month) accrues whether or not anything is running — unlike every other deploy target in this project, `terraform destroy` between sessions isn't just recommended here, it's the only way this stack doesn't quietly cost more than the other two combined.
