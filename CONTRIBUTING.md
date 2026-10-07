# Contributing

1. `pre-commit install` (fmt, validate, tflint, gitleaks run on commit).
2. Keep changes generic: no real domains, account IDs, IPs, org names or
   emails. Use `example.com`, RFC 5737 ranges (`192.0.2.0/24`,
   `198.51.100.0/24`, `203.0.113.0/24`) and `111111111111`.
3. Run the offline test suite before opening a PR:

   ```bash
   terraform init -backend=false
   terraform test -var-file=terraform.tfvars.example
   ```

4. New behaviour that can be misconfigured gets a variable validation, a
   `validate.tf` precondition, or a test in `tests/`.
5. Explain *why* in comments, especially for anything security-relevant or
   surprising. Follow the style of the surrounding code.
