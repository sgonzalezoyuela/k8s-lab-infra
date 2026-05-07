#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${METRICS_SERVER_CHART_VERSION:?METRICS_SERVER_CHART_VERSION unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

# kube-system is the canonical home for cluster-add-on system controllers
# (kube-dns/CoreDNS, kube-proxy, the cloud-controller-manager — and on every
# managed control plane we know of, metrics-server). We deliberately do NOT
# create or label the namespace: kube-system is owned by the cluster, has no
# Pod Security Admission labels by default (controller-runtime treats it as
# privileged), and shipping our own enforce label here would race with Talos's
# system-namespaces controller. The pod is restricted-grade through its
# containerSecurityContext (helm-values.yaml), which is the layer that matters
# for a pod sitting in an unlabelled namespace.
NS="kube-system"
ASSETS="$TOOLS_DIR/cluster/metrics-server"

# If the operator pinned a different chart version in .env vs the bundled
# default, prefer the .env value but make the drift visible. Same model as
# the other Phase-2 installers (metallb, cert-manager, ingress-nginx).
pinned_default="$(tr -d '[:space:]' < "$ASSETS/chart-version.txt" 2>/dev/null || echo unknown)"
if [ "$pinned_default" != "unknown" ] && [ "$pinned_default" != "$METRICS_SERVER_CHART_VERSION" ]; then
  echo "warn: .env METRICS_SERVER_CHART_VERSION=$METRICS_SERVER_CHART_VERSION differs from $ASSETS/chart-version.txt=$pinned_default; using .env value" >&2
fi

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo update metrics-server >/dev/null
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace "$NS" \
  --version "$METRICS_SERVER_CHART_VERSION" \
  -f "$ASSETS/helm-values.yaml" \
  --wait

# The Helm chart creates the APIService v1beta1.metrics.k8s.io (apiService.create=true
# in helm-values.yaml) but does not block on it becoming Available. The
# Available condition is what kubectl top / HPA actually consume — wait for
# it explicitly so install.sh has a tight, observable success contract.
kubectl wait --for=condition=Available --timeout=60s apiservice/v1beta1.metrics.k8s.io

echo "==> metrics-server installed; APIService v1beta1.metrics.k8s.io Available"
