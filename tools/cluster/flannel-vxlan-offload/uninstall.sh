#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="kube-system"
ASSETS="$TOOLS_DIR/cluster/flannel-vxlan-offload"

# Note: deleting the DaemonSet does NOT re-enable the offload on the running
# flannel.1 interfaces (the kernel keeps the last-set value until flannel.1 is
# re-created). If you want to fully revert, also run on each node:
#   ethtool -K flannel.1 tx-checksum-ip-generic on
kubectl delete --ignore-not-found -f "$ASSETS/daemonset.yaml"

echo "==> flannel-vxlan-offload uninstalled (DaemonSet removed)"
