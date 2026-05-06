#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${CLUSTER_ISSUER_NAME:?CLUSTER_ISSUER_NAME unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="cert-manager"

# Each step uses --ignore-not-found / soft failure so the recipe is safe to
# re-run when nothing is installed.
kubectl delete clusterissuer "$CLUSTER_ISSUER_NAME" --ignore-not-found
kubectl -n "$NS" delete secret "$CLUSTER_ISSUER_NAME" --ignore-not-found
helm uninstall cert-manager -n "$NS" 2>/dev/null || true
kubectl delete namespace "$NS" --ignore-not-found

echo "==> cert-manager uninstalled"
