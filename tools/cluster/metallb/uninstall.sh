#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="metallb-system"

# Tear down in reverse dependency order. Each step uses --ignore-not-found /
# soft failure so the recipe is safe to re-run when nothing is installed.
kubectl -n "$NS" delete l2advertisement default-l2-adv --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete ipaddresspool   default-pool   --ignore-not-found 2>/dev/null || true
helm uninstall metallb -n "$NS" 2>/dev/null || true
kubectl delete namespace "$NS" --ignore-not-found

echo "==> MetalLB uninstalled"
