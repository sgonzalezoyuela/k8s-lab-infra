#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="kube-system"

# Two-step minimal smoke:
#   1. The Helm release is actually deployed in kube-system (catches the
#      "operator forgot to run install" / "operator targeted a different
#      cluster" cases).
#   2. The APIService is Available — that is the contract kubectl top and
#      HPA actually depend on. We deliberately do NOT poll `kubectl top
#      nodes` here; the kubelet scrape window is metric-resolution=15s, so
#      "top nodes" can take 30–60s to surface metrics on a fresh install
#      and is best left to the operator as a manual confirmation.
helm -n "$NS" status metrics-server >/dev/null \
  || { echo "ERROR: helm release metrics-server not deployed in $NS" >&2; exit 1; }

kubectl wait --for=condition=Available --timeout=60s apiservice/v1beta1.metrics.k8s.io

echo "==> metrics-server smoke OK (APIService v1beta1.metrics.k8s.io Available)"
