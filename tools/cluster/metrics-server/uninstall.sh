#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="kube-system"

# The Helm release owns the Deployment, the Service, the ClusterRole/Binding,
# the APIService, the ServiceAccount, and the AggregatedClusterRole — uninstall
# tears all of those down. We do NOT delete the namespace (kube-system is
# system-managed). 2>/dev/null || true makes this safe to re-run on an empty
# cluster (helm exits non-zero if the release is already gone).
helm uninstall metrics-server -n "$NS" 2>/dev/null || true

echo "==> metrics-server uninstalled"
