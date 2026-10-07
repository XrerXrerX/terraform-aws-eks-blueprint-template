# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's
private vulnerability reporting ("Security" tab → "Report a vulnerability")
on this repository. Include the affected module, the configuration needed to
reproduce, and the impact you expect.

We aim to acknowledge reports within 3 business days.

## Scope

In scope: insecure defaults, missing or broken controls, privilege
escalation paths in the IAM / RBAC this template creates, and anything that
could cause secrets to be written to git, plan output or Terraform state.

Out of scope: vulnerabilities in AWS services, upstream Terraform modules,
Helm charts or container images (report those upstream), and deployments
that changed the defaults documented in [docs/SECURITY.md](docs/SECURITY.md).

## Using this template safely

* Never commit `terraform.tfvars`, `backend.hcl`, `secrets.env`, state files
  or kubeconfigs — `.gitignore` covers them; keep it that way.
* Run `pre-commit install` so gitleaks runs before every commit.
* Read the "Known trade-offs" section of [docs/SECURITY.md](docs/SECURITY.md).
