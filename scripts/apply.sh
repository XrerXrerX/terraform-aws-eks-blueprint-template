#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Phased apply for a FROM-SCRATCH deploy (docs/DEPLOY.md explains why).
#
#   scripts/apply.sh plan      # full plan (only works once the cluster exists)
#   scripts/apply.sh first     # phases 1-3 for a brand-new environment
#   scripts/apply.sh           # normal day-2 apply
#
# Extra args are passed to terraform, e.g. -var-file=prod.tfvars
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-apply}"
shift || true

tf() { terraform "$@"; }

case "$mode" in
  first)
    echo "==> Phase 1/3: network, KMS, EKS cluster + node pools"
    tf apply -target=module.eks_cluster "$@"

    echo "==> Phase 2/3: cluster controllers (LBC, external-dns, autoscaler, External Secrets)"
    tf apply -target=module.eks_platform "$@"

    echo "==> Phase 3/3: everything else (apps, RAG, data stores, alarms, CI/CD)"
    tf apply "$@"

    cat <<'EOF'

Next:
  1. Fill secret values:   scripts/put-secrets.sh <name_prefix> ./secrets.env
  2. Push images (or let CI do it), then check: kubectl get pods -A
  3. Once the ALBs exist, set enable_alb_alarms = true and apply again.
EOF
    ;;
  plan)
    tf plan "$@"
    ;;
  apply)
    tf apply "$@"
    ;;
  *)
    echo "usage: $0 [first|plan|apply] [terraform args...]" >&2
    exit 1
    ;;
esac
