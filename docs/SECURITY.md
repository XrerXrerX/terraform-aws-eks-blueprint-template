# Security controls

What the template enforces, and where. "Module" paths are under `modules/`.

## Identity & access

| Control | Where |
|---|---|
| No static AWS keys anywhere: pods use IRSA, CI uses GitHub OIDC | `apps/iam.tf`, `rag/main.tf`, `cicd/` |
| One IAM role per app / controller, trusting exactly one ServiceAccount | `apps/iam.tf`, `eks-platform/irsa.tf`, `eks-cluster/irsa.tf` |
| Apps with no AWS needs still get an explicit empty role | `apps/iam.tf` |
| S3 access scoped to the buckets an app lists | `apps/iam.tf` |
| EKS Access Entries (no `aws-auth` ConfigMap); admin via named principals | `eks-cluster/main.tf` |
| CI can only `patch` Deployments/StatefulSets in app namespaces — no create, delete, exec or Secret reads | `cicd/rbac.tf` |
| CI trust pinned to org/repo **and** one branch | `cicd/main.tf` |
| Cluster Autoscaler can only resize ASGs tagged `owned` (never the RAG pool) | `eks-platform/irsa.tf` |
| external-dns can only write to this stack's zones | `eks-platform/irsa.tf` |
| External Secrets: read-only, own SSM path + listed secrets only | `eks-platform/irsa.tf` |
| `allowed_account_ids` stops applies against the wrong account | `providers.tf` |
| Pod ServiceAccount tokens not mounted | `apps/iam.tf`, `apps/workloads.tf`, `rag/` |

## Network

| Control | Where |
|---|---|
| Nodes/pods in private subnets; RDS in isolated subnets (no internet route) | `network/` |
| RDS and Redis accept traffic only from the node security group | `data-stores/` |
| Default VPC security group stripped of all rules | `network/main.tf` |
| VPC Flow Logs (all traffic, KMS-encrypted) | `network/main.tf` |
| AWS API traffic through VPC endpoints instead of NAT | `network/main.tf` |
| Kubernetes API: private endpoint always, public endpoint CIDR-limited (warning if 0.0.0.0/0) | `eks-cluster/`, `validate.tf` |
| NetworkPolicy default-deny ingress per namespace; ALB only onto exposed ports; east-west only for declared pairs | `apps/network_policy.tf`, `rag/network.tf` |
| Vector DB port reachable from inside its own pod only | `rag/network.tf` |
| Admin surfaces on a separate ALB restricted to `admin_allowed_cidrs`; 0.0.0.0/0 rejected in prod | `locals.tf`, `validate.tf` |
| Internal apps have no Ingress and no DNS name | `apps/ingress.tf` |

## Edge

| Control | Where |
|---|---|
| TLS 1.2/1.3 only (`ELBSecurityPolicy-TLS13-1-2-2021-06`), HTTP → HTTPS redirect | `locals.tf` |
| HSTS, `X-Content-Type-Options`, `X-Frame-Options` on every response | `locals.tf` |
| Invalid header fields dropped | `locals.tf` |
| WAF: IP reputation, anonymous IPs, OWASP common rules, known bad inputs, SQLi, per-IP rate limits; blocked requests logged | `waf/` |
| ALB access logs to S3 | `storage/`, `locals.tf` |
| CAA record limits which CAs may issue for the domain | `dns/main.tf` |

## Workloads

| Control | Where |
|---|---|
| Pod Security Admission `restricted` enforced on app and RAG namespaces | `apps/namespace.tf`, `rag/main.tf` |
| Non-root UID/GID, no privilege escalation, all capabilities dropped, seccomp `RuntimeDefault` | `apps/workloads.tf`, `rag/statefulset.tf` |
| Read-only root filesystem by default (explicit emptyDir for writable paths) | `apps/workloads.tf` |
| Memory limits on every container; LimitRange defaults; optional ResourceQuota | `apps/` |
| Nodes: IMDSv2 required, configurable hop limit; encrypted gp3 root volumes; SSM Session Manager instead of SSH | `eks-cluster/main.tf` |
| ECR: immutable tags, scan on push, KMS | `registry/` |

## Data protection

| Control | Where |
|---|---|
| One customer-managed KMS key with rotation; explicit key policy for CloudWatch Logs / alarms | `kms/` |
| Kubernetes Secrets envelope-encrypted in etcd | `eks-cluster/main.tf` |
| RDS: encrypted, TLS enforced (`rds.force_ssl` / `require_secure_transport`), Multi-AZ, PITR backups, deletion protection, final snapshot, IAM auth enabled | `data-stores/rds.tf` |
| RDS master password managed by RDS in Secrets Manager — never in state | `data-stores/rds.tf` |
| Redis: encryption at rest (KMS) + in transit (TLS required) + AUTH | `data-stores/redis.tf` |
| S3: SSE-KMS, public access blocked, ACLs disabled, TLS-only bucket policy | `storage/` |
| EBS volumes encrypted with the platform key; RAG volumes `Retain` + daily AWS Backup | `eks-platform/storage_class.tf`, `backup/` |
| Terraform state: KMS-encrypted, versioned, TLS-only, optionally restricted to named roles | `bootstrap/` |

## Secrets hygiene

* Secret values never pass through Terraform (placeholders + `ignore_changes`).
* `scripts/put-secrets.sh` writes through a temp file (not argv / history)
  and only to parameters Terraform declared, encrypted with the platform key.
* `.gitignore` excludes tfvars, backend config, state, env files, keys,
  kubeconfigs. The pre-commit hooks run gitleaks before every commit.

## Known trade-offs (read these)

* **Redis AUTH token is in Terraform state** — ElastiCache has no managed
  secret. Protect the state bucket accordingly.
* **Egress is open** from pods (they need RDS, Redis, AWS and third-party
  APIs). Add egress NetworkPolicies or an egress proxy if your threat model
  requires it.
* **Apps share the RDS master user** out of the box. Create a least-privilege
  user per app (see OPERATIONS.md) before handling real data.
* **External Secrets uses one controller identity** for all namespaces: any
  namespace that can create a SecretStore can read this stack's SSM path.
  Restrict who can create SecretStores (RBAC) if you have untrusted tenants.
* **IMDS hop limit 2** (default) lets non-hostNetwork pods reach node IMDS;
  needed by the CloudWatch agent. Set `node_imds_hop_limit = 1` if you
  disable Container Insights.
* **WAF `SizeRestrictions_BODY` counts instead of blocking** to allow larger
  JSON bodies.
