#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

ASSETS="$TOOLS_DIR/cluster/local-path-provisioner"

# --ignore-not-found makes this safe to re-run on an empty cluster. The
# overlay owns: the Namespace local-path-storage (cascades the Deployment,
# ConfigMap, helper RBAC, SA) and the cluster-scoped StorageClass local-path
# (plus the cluster-scoped ClusterRole/ClusterRoleBinding).
#
# We deliberately do NOT remove the host directory /var/local-path-provisioner
# on either node. Pre-existing PV data would orphan, and operator hygiene
# says "don't silently nuke host state". A truly clean slate is a manual
# `talosctl -n <node> shell` + `rm -rf` away.
kubectl delete -k "$ASSETS" --ignore-not-found

echo "==> local-path-provisioner uninstalled (host directories left intact)"
