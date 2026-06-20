#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="kube-system"

# 1. The DaemonSet exists and every scheduled pod is ready.
kubectl -n "$NS" rollout status daemonset/flannel-vxlan-tx-csum-off --timeout=60s

# 2. The whole point of the fix: the aggregated Metrics API is reachable from
#    the kube-apiserver. This is the exact condition that black-holes when the
#    flannel.1 tx-checksum offload corrupts cross-node TCP. If this passes, the
#    control-plane -> worker-pod TCP path is healthy.
kubectl wait --for=condition=Available --timeout=60s apiservice/v1beta1.metrics.k8s.io

echo "==> flannel-vxlan-offload smoke OK (DaemonSet ready; Metrics API Available)"
