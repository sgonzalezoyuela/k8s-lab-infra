#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

# kube-system is the canonical home for node-level system DaemonSets (kube-proxy,
# flannel itself). It is PSA-exempt on Talos, which is what lets this hostNetwork
# + NET_ADMIN helper run. See daemonset.yaml header for the full rationale.
NS="kube-system"
ASSETS="$TOOLS_DIR/cluster/flannel-vxlan-offload"

kubectl apply --server-side --field-manager=flannel-vxlan-offload-install \
  -f "$ASSETS/daemonset.yaml"

# Block until every node has the helper running, so the caller has an observable
# success contract (the offload knob is re-applied within INTERVAL seconds after
# flannel.1 (re)appears).
kubectl -n "$NS" rollout status daemonset/flannel-vxlan-tx-csum-off --timeout=2m

echo "==> flannel-vxlan-offload installed; tx-checksum-ip-generic kept off on flannel.1"
