# Triggering CD (`cd.yml`) Against LocalStack — Manual Runbook

Scope: how to manually run `.github/workflows/cd.yml` with `environment: localstack` from a fresh
state — registering the self-hosted runner, applying the shared Terraform state bucket if needed,
dispatching the workflow, verifying the result, and tearing everything back down afterward.
`environment: aws` (real AWS) is out of scope here — see `completed.md`'s Phase 15/16 entries for
why that path isn't ready yet (no OIDC deploy roles, no `vars.AWS_ACCOUNT_ID`, no real-AWS answer
for `var.secrets`).

Repo this targets: `SrikanthArgp/SearchAssistantProduction` (the actual CD/LocalStack push target —
distinct from `origin`, `SrikanthArgp/LangGraph_Multi_Agent`, which this repo's local `main` also
tracks).

---

## Prerequisites (one-time, already done as of 2026-07-12)

- `LOCALSTACK_SECRETS_JSON` repo secret exists on `SearchAssistantProduction` (JSON-encoded map of
  the same 9 keys in `infra/lambda-gate/secrets.auto.tfvars`' `secrets = {...}` block: `REDIS_URL`,
  `GRAFANA_OTLP_TOKEN`, `OPENAI_API_KEY`, `LANGFUSE_PUBLIC_KEY`, `DATABASE_URL`,
  `LANGFUSE_SECRET_KEY`, `TAVILY_API_KEY`, `DATABASE_URL_PSYCOPG`, `JWT_SECRET_KEY`). Only needs
  redoing if the secret is rotated or deleted — see "Re-creating `LOCALSTACK_SECRETS_JSON`" below.
- `C:\gh-runner\` has the GitHub Actions runner package extracted. Only needs redoing if that
  directory is deleted.

---

## Steps

### 1. Confirm LocalStack is up

```bash
curl http://localhost:4566/_localstack/health
```

### 2. Check the shared Terraform state bucket still exists

`infra/bootstrap` is never touched by either CD workflow — it's a manual, one-time prerequisite
(the same convention real usage already follows), and normally survives a stack teardown.

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url=http://localhost:4566 s3 ls
```

If `crag-terraform-state` isn't listed (e.g. LocalStack itself was reset, not just the two
deploy stacks), recreate it once:

```bash
cd infra/bootstrap
terraform apply -auto-approve
```

### 3. Get a runner registration token and register the runner

`config.cmd`/`run.cmd` are Windows scripts — run these in PowerShell, not Git Bash.

```powershell
gh api -X POST repos/SrikanthArgp/SearchAssistantProduction/actions/runners/registration-token --jq '.token'
```

Copy the token, then:

```powershell
cd C:\gh-runner
.\config.cmd --url https://github.com/SrikanthArgp/SearchAssistantProduction --token <PASTE_TOKEN> --name crag-localstack-runner --labels localstack --unattended --replace
```

### 4. Start the runner listener

This has to keep running for the whole duration of the workflow — use a dedicated terminal
window and don't close it.

```powershell
cd C:\gh-runner
.\run.cmd
```

Wait for it to print "Listening for Jobs". Confirm it's actually visible to GitHub before
dispatching anything:

```bash
gh api repos/SrikanthArgp/SearchAssistantProduction/actions/runners --jq '.runners[] | {name, status, busy}'
```

`status` should read `online`.

### 5. Trigger the workflow

Either from the browser — **Actions → CD - Dispatcher → Run workflow**, set `target` to
`lambda`/`fargate`/`both` and `environment` to `localstack` — or from the CLI:

```bash
gh workflow run cd.yml --repo SrikanthArgp/SearchAssistantProduction --ref main -f target=both -f environment=localstack
```

### 6. Watch it

```bash
gh run list --repo SrikanthArgp/SearchAssistantProduction --limit 1
gh run watch <run-id> --repo SrikanthArgp/SearchAssistantProduction --exit-status
```

If this is the first run against a LocalStack instance that has never had these two stacks
applied (or just had them destroyed), expect this to take several minutes — both workflows do a
full `terraform apply` from nothing (Terraform init → ECR repo → image build/push → full
apply → smoke check → frontend build/sync), not just an image swap.

### 7. Verify manually once green

```bash
export MSYS_NO_PATHCONV=1   # avoids Git Bash mangling the leading "/" in --name below
DOMAIN=$(aws --endpoint-url=http://localhost:4566 ssm get-parameter --name /crag/prod/cloudfront_domain --query 'Parameter.Value' --output text)
curl https://$DOMAIN/health
```

Swap `/crag/prod/cloudfront_domain` for `/crag/prod-ecs/cloudfront_domain` to check the Fargate
stack instead. A working response looks like `{"status":"ok","db":true,"redis":true}`. For the
frontend, open `https://<domain>/login.html` in a browser (expect a self-signed-cert warning —
click through it, that's normal for LocalStack).

### 8. Clean up when done

```powershell
cd C:\gh-runner
# Ctrl+C the running .\run.cmd window first
gh api -X POST repos/SrikanthArgp/SearchAssistantProduction/actions/runners/remove-token --jq '.token'
.\config.cmd remove --token <PASTE_REMOVE_TOKEN>
```

```bash
cd infra/lambda-gate && terraform destroy -auto-approve
cd ../fargate && terraform destroy -auto-approve
```

Leave `infra/bootstrap` alone — it's shared and not part of either deploy stack.

---

## Known flakes (already fixed, but worth knowing about if they resurface)

- **A fresh/reset LocalStack instance + a commit that doesn't touch `infra/lambda-gate/**` or
  `infra/fargate/**`** makes both workflows take the "fast path" (assumes existing infra) even
  though there's nothing there — surfaces as `aws ecr get-login-password` failing with
  `list index out of range`. Recovering from this should always go through a real CD run whose
  diff touches the relevant `infra/` directory (so the workflow's own steps rebuild everything),
  **never** by hand-running `infra/*/scripts/*.sh` or ad-hoc `terraform`/`docker` commands outside
  the workflow — see `completed.md`'s Phase 18/19 LocalStack-verification entry for the full
  writeup of why.
- **`deploy-ecs`'s smoke check can fail once on a fast-path (image-only) redeploy** — `aws ecs wait
  services-stable` only confirms the ECS task itself is ready, not that the ALB target group /
  CloudFront's connection to it has caught up. Already mitigated (`cd-ecs.yml`'s smoke check now
  retries 10× at 5s), but if it still happens, retrying the identical `curl` by hand a few seconds
  later is a good first check before assuming something's actually broken.

## Re-creating `LOCALSTACK_SECRETS_JSON` if it's ever rotated or deleted

The value is the JSON form of `infra/lambda-gate/secrets.auto.tfvars`' `secrets = {...}` map.
Don't run `terraform console -var-file=secrets.auto.tfvars` to extract it — `var.secrets` is
`sensitive = true`, so Terraform redacts the result as `(sensitive value)` instead of printing it.
Parse the `.tfvars` file directly (a small regex-based script reading `KEY = "value"` pairs works
fine, since the format is simple and fully under this repo's control) and pipe the result straight
into `gh secret set LOCALSTACK_SECRETS_JSON --repo SrikanthArgp/SearchAssistantProduction`, ideally
without ever writing the plaintext to a location outside a scratch file you delete immediately
after.
