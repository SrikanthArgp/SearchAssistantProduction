---
name: cloudfront-refresh
description: Re-fetch the current, live CloudFront domain(s) for this project's real-AWS stacks (Lambda, Fargate, EKS) via SSM before reporting or using any CloudFront URL. Use any time a CloudFront URL is about to be given to the user or used in a verification step, especially after any CD dispatch that could have touched cloudfront.tf.
---

# CloudFront Refresh

Implements the standing rule from this project's real incident (2026-07-14): a
`terraform apply` that touches `cloudfront.tf`'s origin config or OAC/OAI can
force-replace the `aws_cloudfront_distribution` resource, minting a brand-new
`*.cloudfront.net` domain. Nothing in the CD pipeline surfaces this — the
in-workflow smoke check queries the *current* SSM value, so it always passes
even right after a rotation. A bookmarked or remembered domain is never
trustworthy after any infra-changing apply.

## Steps

1. Never state a CloudFront domain from memory, from an earlier message in the
   conversation, or from a memory file — always re-fetch it live first.
2. On Windows Git Bash, remember the leading `/` in `--name /crag/...` is
   subject to the same MSYS path-mangling as the frontend build bug — set
   `MSYS_NO_PATHCONV=1` for the fetch command too:
   ```bash
   export MSYS_NO_PATHCONV=1
   aws ssm get-parameter --profile crag-real-aws --name /crag/prod/cloudfront_domain --query 'Parameter.Value' --output text          # Lambda
   aws ssm get-parameter --profile crag-real-aws --name /crag/prod-ecs/cloudfront_domain --query 'Parameter.Value' --output text      # Fargate
   ```
   (EKS stores its CloudFront domain the same way under its own SSM path if a
   pinned parameter name has been established for it — check `infra/eks/` for
   the exact key before assuming the same `/crag/prod*` pattern applies.)
3. If a `curl`/browser check against a previously-known domain returns "Could
   not resolve host" / DNS failure right after a green CD run, treat that as
   the signature of a domain rotation, not a real outage — re-run step 2 before
   escalating.
4. Report the freshly-fetched domain, not the one from context, even if it's
   identical to what's already been said this session.
