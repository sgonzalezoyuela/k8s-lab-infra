#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="newt"

# Order: Deployment, then Secret, then Namespace. --ignore-not-found makes
# every step safe to re-run on an empty cluster.
kubectl -n "$NS" delete deployment newt              --ignore-not-found
kubectl -n "$NS" delete secret     newt-credentials  --ignore-not-found
kubectl delete namespace "$NS"                       --ignore-not-found

echo "==> newt uninstalled"
