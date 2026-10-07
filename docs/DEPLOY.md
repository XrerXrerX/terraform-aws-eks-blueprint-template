# Deploying from scratch

## 0. Prerequisites

* Terraform ≥ 1.10, AWS CLI v2, kubectl.
* AWS credentials for an admin-level role in the target account.
* A domain. Either an existing public Route53 hosted zone
  (`create_route53_zone = false`) or let Terraform create it and delegate the
  NS records at your registrar (`terraform output route53_name_servers`).

## 1. Remote state (once per account)

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply \
  -var="aws_region=us-east-1" \
  -var="state_bucket_name=<org>-<project>-tfstate" \
  -var='state_admin_role_arns=["arn:aws:iam::<acct>:role/<your-admin-role>"]'

terraform -chdir=bootstrap output -raw backend_hcl > backend.hcl
# edit `key` in backend.hcl, e.g. prod/terraform.tfstate
```

`backend.hcl` is git-ignored. The bootstrap's own state is local — keep it
somewhere safe, or migrate it into the bucket afterwards.

## 2. Configure

```bash
cp terraform.tfvars.example terraform.tfvars
```

At minimum set: `project`, `environment`, `aws_region`,
`allowed_account_ids`, `root_domain`, `admin_allowed_cidrs`, `apps`, `rag`,
`alert_emails`, and the GitHub settings (or `github_org = ""` to skip CI/CD).

```bash
terraform init -backend-config=backend.hcl
terraform test -var-file=terraform.tfvars   # optional, offline sanity check
```

## 3. First apply — phased

The kubernetes/helm providers cannot authenticate to a cluster that does not
exist, and ExternalSecret objects cannot be planned before the CRDs exist. So
a brand-new environment is applied in three steps (`scripts/apply.sh first`
does exactly this):

```bash
terraform apply -target=module.eks_cluster    # VPC, NAT, KMS, EKS, node pools (~15-20 min)
terraform apply -target=module.eks_platform   # controllers, ESO CRDs, StorageClasses, RDS
terraform apply                               # apps, RAG, alarms, WAF, CI/CD, ...
```

Every later change is a single `terraform apply`.

## 4. Secrets

```bash
terraform output secret_parameters              # what needs a value
cp secrets.env.example secrets.env              # one KEY=VALUE per parameter
scripts/put-secrets.sh <project>-<environment> secrets.env
rm secrets.env
```

External Secrets picks the values up within its refresh interval (default 1h —
force it with `kubectl annotate externalsecret <name> -n <ns>
force-sync=$(date +%s) --overwrite`), and Reloader restarts the pods.

## 5. Images

Push an image for every ECR repository (normally CI does this — see
[examples/deploy-workflow.yml](../examples/deploy-workflow.yml)):

```bash
terraform output ecr_registry
terraform output github_deploy_role_arn   # AWS_DEPLOY_ROLE_ARN in each repo
```

Until images exist, pods sit in `ImagePullBackOff`; that is expected.

## 6. Verify

```bash
$(terraform output -raw update_kubeconfig_command)
kubectl get nodes -L role                      # general nodes + 1 rag node
kubectl get pods -A
kubectl get externalsecrets -A                 # STATUS should be SecretSynced
kubectl get ingress -A                         # ADDRESS appears after a few minutes
```

## 7. Turn on ALB alarms

Once both ALBs have an address:

```hcl
enable_alb_alarms = true
```

`terraform apply`. (Before the ALBs exist, their data sources cannot resolve.)

## 8. Confirm alert subscriptions

Every address in `alert_emails` receives an SNS confirmation email. Alarms are
silent until it is confirmed.

## Tearing down

`database.deletion_protection` and the RAG volumes' `Retain` policy exist to
make this deliberate:

1. set `database.deletion_protection = false`, apply;
2. `terraform destroy`;
3. delete the retained EBS volumes (tag `backup-plan=<prefix>-rag`) and the
   final RDS snapshot yourself, once you are sure.
