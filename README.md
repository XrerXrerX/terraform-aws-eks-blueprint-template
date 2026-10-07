# Production EKS Platform — Terraform template

A production-grade, security-first Terraform template for running **several
applications on Amazon EKS**, plus a **dedicated node for a stateful RAG /
vector-database workload** that is kept out of the general pod pool.

Everything is declared in one root module and driven by data: add an app by
adding a map entry, not by writing new Terraform.

```
                              Internet
                                 │
               ┌─────────── AWS WAF (managed rules + rate limits) ───────────┐
               │                                                             │
        ALB  "public"  (0.0.0.0/0)                         ALB  "admin"  (operator CIDRs only)
        web, api, ...                                       admin, RAG UI/API, ...
               │  TLS 1.2/1.3 (ACM) · HSTS · access logs          │
 ┌─────────────┴───────────── VPC (3 AZs) ────────────────────────┴──────────────┐
 │  public subnets:  ALBs, NAT gateways (one per AZ)                             │
 │                                                                               │
 │  private subnets:                                                             │
 │   ┌─────────────── node pool "general" (autoscaled) ───────┐  ┌── "rag" ───┐  │
 │   │ ns/apps   (Pod Security: restricted, default-deny net)  │  │ 1 node,    │  │
 │   │  web   api   worker   admin    ... (HPA + PDB each)     │  │ tainted,   │  │
 │   │ kube-system: LB controller, external-dns, autoscaler    │  │ NOT auto-  │  │
 │   │ external-secrets, reloader                              │  │ scaled     │  │
 │   └─────────────────────────────────────────────────────────┘  │ ns/rag:    │  │
 │                                                                │ api+Qdrant │  │
 │                                                                │ +worker    │  │
 │                                                                │ 2×EBS(KMS) │  │
 │                                                                └────────────┘  │
 │  isolated subnets: RDS (Multi-AZ, no internet route)                          │
 │  ElastiCache Redis (TLS + AUTH) · VPC endpoints (STS, ECR, SSM, Secrets, Logs)│
 └───────────────────────────────────────────────────────────────────────────────┘
   S3 (SSE-KMS, TLS-only) · ECR (immutable, scanned) · SSM/Secrets Manager · AWS Backup
   CloudWatch alarms → SNS (KMS)  ·  GitHub Actions → OIDC → narrowly-scoped deploy role
```

## What you get

| Area | Included |
|---|---|
| **Network** | 3-tier VPC (public / private / isolated) across 2–4 AZs, NAT per AZ, S3 gateway + interface endpoints, VPC Flow Logs (KMS), locked-down default SG |
| **Cluster** | EKS (pinned version), private + CIDR-limited public endpoint, Access Entries (no `aws-auth`), Secrets envelope encryption (KMS), control-plane audit logs, IMDSv2-only nodes, SSM Session Manager instead of SSH |
| **Node pools** | `general` — autoscaled by Cluster Autoscaler · `rag` — dedicated, tainted, fixed size, AZ-pinned, never autoscaled |
| **Controllers** | AWS Load Balancer Controller, external-dns, Cluster Autoscaler, External Secrets Operator, Reloader, EBS CSI, metrics-server, CloudWatch Container Insights |
| **Apps** | Data-driven: Deployment, Service, HPA, PDB, Ingress, NetworkPolicy, IRSA role, ConfigMap, ExternalSecret per app |
| **RAG** | StatefulSet (API + Qdrant + optional worker + volume-metrics sidecar), 2 encrypted `Retain` volumes, daily AWS Backup, own namespace + NetworkPolicy |
| **Data** | RDS PostgreSQL/MySQL (Multi-AZ, TLS-enforced, RDS-managed password), Redis (TLS, AUTH, failover), S3 buckets |
| **Edge** | One ACM cert, WAF (IP reputation, anonymous IP, OWASP common, bad inputs, SQLi, rate limits), HSTS & security headers, CAA record |
| **Ops** | CloudWatch alarms (pods, crash loops, OOM risk, nodes, RAG node/volumes, RDS, Redis, ALB 5xx/latency) → SNS |
| **CI/CD** | GitHub OIDC (no static keys), deploy role limited to own ECR repos + `patch` on workloads in app namespaces |
| **Quality** | `terraform test` with mocked providers (no credentials needed), tflint, trivy, gitleaks, pre-commit |

## No secrets in git, tfvars, or state

* **Secret values never pass through Terraform.** Terraform creates SSM
  parameters with a placeholder and ignores their value forever; you write real
  values with `scripts/put-secrets.sh`. External Secrets Operator syncs them
  into Kubernetes, and Reloader rolls pods on change.
* **Database password** is generated and held by RDS in Secrets Manager
  (`manage_master_user_password`), so it is not in state either.
* The only generated secret in state is the Redis AUTH token (ElastiCache has
  no managed option) — the state bucket is KMS-encrypted, versioned and can be
  restricted to named roles (`bootstrap/`).
* `.gitignore` excludes `*.tfvars`, `backend.hcl`, state, `.env`, keys and
  kubeconfigs. Only `*.example` files are committed, and they contain only
  placeholders (`example.com`, RFC 5737 IPs, the AWS docs' example account ID).

See [docs/SECURITY.md](docs/SECURITY.md) for the full control list.

## Quick start

Prerequisites: Terraform ≥ 1.10, AWS CLI v2, kubectl, an AWS account, and a
Route53-hosted domain.

```bash
# 0. Remote state (once per account)
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply -var="aws_region=us-east-1" -var="state_bucket_name=<unique-name>"
terraform -chdir=bootstrap output -raw backend_hcl > backend.hcl      # then set `key`

# 1. Configure
cp terraform.tfvars.example terraform.tfvars                          # edit
terraform init -backend-config=backend.hcl

# 2. First deploy is phased (the Kubernetes providers need a live cluster)
scripts/apply.sh first

# 3. Secrets
cp secrets.env.example secrets.env                                    # fill in
scripts/put-secrets.sh <project>-<environment> secrets.env && rm secrets.env

# 4. Point your app repos' CI at the outputs
terraform output ecr_registry github_deploy_role_arn
```

Full walkthrough: [docs/DEPLOY.md](docs/DEPLOY.md).

## Adding an application

```hcl
apps = {
  billing = {
    ecr_repository = "billing"          # also add "billing" to ecr_repositories
    port           = 8080
    exposure       = "public"           # public | admin | internal
    hosts          = ["billing"]        # billing.<root_domain>
    autoscaling    = { min_replicas = 2, max_replicas = 8 }
    database       = true               # DB_* env + credentials injected
    redis          = true               # REDIS_* env + AUTH injected
    s3_buckets     = ["uploads"]        # IRSA access to exactly this bucket
    allow_from     = ["api"]            # only `api` may call it in-cluster
    secrets        = { STRIPE_KEY = "BILLING_STRIPE_KEY" }  # ENV => SSM name
  }
}
```

`terraform apply`, then `scripts/put-secrets.sh` for any new secret name.
All options are documented on `variable "apps"` in [variables.tf](variables.tf).

## Layout

```
.
├── bootstrap/                 remote-state bucket (run once)
├── modules/
│   ├── kms/                   platform KMS key + key policy
│   ├── secrets/               SSM SecureString placeholders
│   ├── network/               VPC, subnets, NAT, endpoints, flow logs
│   ├── eks-cluster/           EKS, node pools (general + rag), add-ons, add-on IRSA
│   ├── eks-platform/          LB controller, external-dns, autoscaler, ESO, Reloader, StorageClasses
│   ├── data-stores/           RDS + ElastiCache
│   ├── storage/               S3 buckets + ALB log bucket
│   ├── dns/                   Route53 zone, ACM certificate, CAA
│   ├── registry/              ECR
│   ├── waf/                   WAFv2 ACL + logging
│   ├── apps/                  generic stateless apps
│   ├── rag/                   dedicated RAG / vector-DB StatefulSet
│   ├── observability/         SNS + CloudWatch alarms
│   ├── backup/                AWS Backup for RAG volumes
│   └── cicd/                  GitHub OIDC deploy role + RBAC
├── tests/                     offline `terraform test` suite (mocked providers)
├── scripts/                   apply.sh (phased first deploy), put-secrets.sh
├── examples/                  app-repo deploy workflow
└── docs/                      ARCHITECTURE, DEPLOY, SECURITY, OPERATIONS
```

## Testing

```bash
terraform init -backend=false
terraform test -var-file=terraform.tfvars.example   # no AWS credentials needed
```

## Cost

The defaults are sized for production (3 NAT gateways, Multi-AZ RDS, Redis
replica, 3 general nodes + 1 RAG node, interface endpoints). For a dev
environment: `single_nat_gateway = true`, `az_count = 2`,
`database.multi_az = false`, `redis.num_cache_clusters = 1`, smaller instance
types, and trim `modules/network` `interface_endpoints`. The `check` blocks
warn you when these are used with `environment = "prod"`.

## License

[MIT](LICENSE)
