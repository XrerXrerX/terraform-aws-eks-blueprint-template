#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Write secret VALUES into SSM Parameter Store, out-of-band from Terraform.
#
#   scripts/put-secrets.sh <name_prefix> <env-file>
#   e.g. scripts/put-secrets.sh myplatform-prod ./secrets.env
#
# <env-file> holds KEY=VALUE lines (KEY = parameter name, without the path):
#   API_JWT_SECRET=...
#   RAG_LLM_API_KEY=...
#
# - Only keys Terraform already created are written (no typos creating
#   stray parameters); unknown keys are reported and skipped.
# - Values are passed through a temp file, never on the command line, so
#   they do not show up in `ps` or shell history.
# - The env file is git-ignored (*.secrets.env / secrets.env). Delete it
#   after use, or better, pipe values from your password manager.
# ---------------------------------------------------------------------------
set -euo pipefail

prefix="${1:?usage: $0 <name_prefix> <env-file>}"
env_file="${2:?usage: $0 <name_prefix> <env-file>}"
[ -r "$env_file" ] || { echo "cannot read $env_file" >&2; exit 1; }

# Same customer-managed key Terraform created (modules/kms). Without --key-id
# an overwrite silently re-encrypts with the AWS-managed aws/ssm key.
kms_key="alias/${prefix}"

existing="$(aws ssm get-parameters-by-path --path "/${prefix}/" \
  --query 'Parameters[].Name' --output text | tr '\t' '\n')"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
chmod 600 "$tmp"

written=0
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"
  value="${line#*=}"
  name="/${prefix}/${key}"

  if ! grep -Fxq -- "$name" <<<"$existing"; then
    echo "skip  ${key}  (not declared in Terraform — check the name)" >&2
    continue
  fi

  printf '%s' "$value" > "$tmp"
  aws ssm put-parameter --name "$name" --type SecureString --overwrite \
    --key-id "$kms_key" --value "file://${tmp}" >/dev/null
  echo "set   ${key}"
  written=$((written + 1))
done < "$env_file"

echo "done: ${written} parameter(s) written. External Secrets picks them up within its refresh interval."
