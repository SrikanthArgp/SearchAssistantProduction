# Case Study: Agentic RAG Platform — From LangGraph Prototype to Multi-Cloud Production System

## Resume bullets

**Agentic AI / LLM systems track**

- Designed and built a Corrective RAG (CRAG) multi-agent pipeline in LangGraph with self-correcting retrieval: a router directs queries to vector search or live web search, a document-relevance grader triggers fallback web retrieval when local context is insufficient, and hallucination/answer-usefulness graders drive bounded retry loops before returning an answer — with graceful degradation instead of hard failure on any LLM or tool error.
- Built a RAGAS + Langfuse evaluation suite with a 25-item baseline run, plus trace-level observability that ties every LLM call to OpenTelemetry request spans via a shared request ID — giving quantitative visibility into groundedness and answer-relevance regressions instead of eyeballing outputs.
- Productionized the agent behind a JWT-authenticated FastAPI service with per-user Redis session and rate-limit state, Postgres-backed LangGraph checkpointing for durable multi-turn conversation state, and SSE streaming to a Next.js frontend (via `fetch`+`ReadableStream`, since `EventSource` can't carry the auth header this design needed).

**Cloud / Platform architecture track**

- Architected and deployed the same agentic system across three parallel AWS compute models — Lambda/API Gateway serverless, ECS Fargate, and EKS with Helm/ArgoCD GitOps — each with independent Terraform, IAM, and networking, enabling a direct cost/operability comparison (~$0 at-rest serverless vs. ~$16–20/mo ALB-based Fargate vs. ~$73/mo+ EKS control plane, documented and budgeted against a fixed credit).
- Built GitHub Actions CI/CD for all three deploy targets using OIDC role assumption (no long-lived AWS credentials in CI), including a GitOps path where the pipeline only commits an image tag and an in-cluster ArgoCD reconciliation loop performs the actual deploy — verified with a deliberate-failure test confirming old pods keep serving traffic while a bad rollout sits `Degraded`.
- Diagnosed and resolved 25+ real infrastructure defects across a LocalStack-then-real-AWS verification pipeline: a CloudFront-Origin-Access-Control-vs-application-JWT conflict fixed at the application layer with a custom auth header, missing IAM/ECR-repository-policy grants, and a GitHub Actions credential bug where `actions/checkout`'s injected auth header silently overrode a purpose-built deploy token across several rounds of "correct" credentials.
- Made and documented cost-driven architecture tradeoffs under a fixed budget — swapping EKS for ECS Fargate to avoid a flat control-plane fee, then deliberately reintroducing EKS as an additive third target to demonstrate Kubernetes/GitOps competency; avoiding NAT Gateway cost entirely by choosing public-subnet Fargate egress + an externally-hosted Redis (Upstash) over a VPC-bound ElastiCache.

---

## One-page narrative

### Context

A Corrective RAG (CRAG) research prototype — a LangGraph agent that grades its own retrieved documents and generated answers, falling back to web search or regenerating when it isn't confident — was taken through a full productionization pass: authentication, persistence, caching, a frontend, an evaluation harness, and then three independent, fully-verified AWS production deployments with CI/CD. The goal was to prove the same design decisions a Principal/Architect role is judged on: correct scoping, tradeoff reasoning under real constraints (cost, time, a single-developer team), and the discipline to verify claims against a real environment rather than a diagram.

### Architecture

```
User → Next.js (S3 + CloudFront) → FastAPI (JWT auth, SSE streaming)
                                        │
                          LangGraph CRAG state machine
              route → retrieve/web-search → grade docs → generate → grade output
                                        │
                    Postgres (checkpoints) · Redis (sessions/cache) · Chroma (vectors)
                                        │
                    Langfuse (LLM trace/eval) · OTel→Grafana (request trace)

Deployed identically behind three independent compute backends:
  Lambda + API Gateway + Function URL (streaming)   — serverless, pay-per-use
  ECS Fargate + ALB                                  — container, always-on
  EKS + Helm + ArgoCD GitOps                          — Kubernetes, learn-K8s target
```

### Key architectural decisions

| Decision | Why | Principal-level signal |
|---|---|---|
| Three independent deploy targets instead of one | Forces the design to be genuinely portable (no hidden Lambda- or ALB-specific coupling) and gives a real cost/ops comparison instead of a hypothetical one | Comparative tradeoff analysis backed by working systems, not slides |
| Lambda Web Adapter over Mangum for streaming | Mangum buffers the full response before returning — incompatible with SSE. The adapter runs the real `uvicorn` process, so zero app code changes were needed | Chose the tool that matched a non-negotiable requirement (streaming) rather than the more common default |
| ECS Fargate chosen over EKS first, EKS added back later | EKS's flat ~$0.10/hr control-plane fee wasn't justified until the goal became "prove Kubernetes/GitOps competency" — at which point it was added *additively*, not as a reversal | Distinguishes cost-optimal from capability-demonstrating architecture, and sequences them deliberately |
| GitOps (ArgoCD) scoped to EKS only, direct GitHub Actions deploys kept for Lambda/Fargate | ArgoCD needs a cluster; standing one up just to run it would have re-opened an already-closed cost decision for the other two targets | Doesn't force one deployment philosophy onto every target — matches the tool to the platform |
| CloudFront-OAC-vs-JWT conflict fixed with a custom header, not by dropping app auth | AWS's Origin Access Control overwrites the `Authorization` header en route to Lambda, which collided with the app's own bearer-token auth | Resolved a genuine architecture conflict between two security mechanisms without weakening either |
| Redis revocation-check fails open, not closed | JWT signature/expiry is the primary control; a transient Redis outage rejecting every authenticated request is worse than a brief best-effort window on logout enforcement | Explicit, written security tradeoff — not an accidental gap |

### Real-world debugging (the part that doesn't show up in a design doc)

- **CloudFront OAC silently overwriting the app's `Authorization` header** — found only once real requests hit a real Lambda; fixed with an application-level `X-Auth-Token`.
- **A GitHub Actions push that kept authenticating as the wrong identity** across several credential changes (fine-grained PAT → +Administration scope → classic full-repo PAT) — root cause was `actions/checkout`'s own injected `http.extraheader`, silently overriding every token tried until it was explicitly cleared.
- **ArgoCD's first sync provisioning a brand-new physical ALB**, leaving CloudFront's cached origin pointed at the old one (502s) until a plain `terraform apply` re-resolved the data source — a GitOps/Terraform interaction bug with no obvious owner.
- **A Terraform `-target` dependency-closure gap**: targeting the EKS node group assumed Terraform would pull in the VPC's IGW/route table automatically; it didn't, so the node got a public IP with no route out, and node creation failed silently for ~25 minutes before being traced through `nodeadm`'s console logs.
- **Windows-specific runtime bugs** (`ProactorEventLoop` vs. async `psycopg`, `passlib`/`bcrypt` version incompatibility, MSYS/Git-Bash path-mangling in frontend builds recurring across three separate deploy phases) — each root-caused and fixed rather than worked around.

### Verification

All three stacks were confirmed working end-to-end on **real AWS**, not just LocalStack — real login/session/chat-history/chat-send flows exercised through a browser against each stack's live CloudFront domain, with LocalStack used first specifically to make real-AWS runs cheap and fast to iterate on rather than as a substitute for real verification.

### Why this maps to an Agentic AI Architect / Principal Architect role

The project demonstrates the two halves those titles actually test: designing the *agent* (retrieval correction, grading loops, evaluation, observability) and designing the *platform* it has to run on for real (auth, cost, multi-target deployment, CI/CD, and the willingness to chase a bug to its real root cause instead of patching the symptom). The gap worth naming honestly in interviews: this was solo work, so it doesn't yet carry evidence of driving architecture consensus across a team or mentoring — the technical depth should carry the conversation, but be ready to talk about how you'd approach *that* part, not just the build.
