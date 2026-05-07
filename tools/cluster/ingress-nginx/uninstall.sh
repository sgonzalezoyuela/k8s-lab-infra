#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${INGRESS_DEFAULT_TLS_SECRET:?INGRESS_DEFAULT_TLS_SECRET unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="ingress-nginx"

# Tear down in reverse dependency order. Each step uses --ignore-not-found /
# soft failure so the recipe is safe to re-run when nothing is installed.
kubectl -n "$NS" delete certificate "$INGRESS_DEFAULT_TLS_SECRET" --ignore-not-found 2>/dev/null || true
kubectl -n "$NS" delete secret "$INGRESS_DEFAULT_TLS_SECRET" --ignore-not-found 2>/dev/null || true
helm uninstall ingress-nginx -n "$NS" 2>/dev/null || true
kubectl delete namespace "$NS" --ignore-not-found

echo "==> ingress-nginx uninstalled"
