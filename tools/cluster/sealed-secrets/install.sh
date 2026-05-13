#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${SEALED_SECRETS_CHART_VERSION:?SEALED_SECRETS_CHART_VERSION unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

# Dedicated namespace under restricted PSA. We pre-create it with the label
# set so the controller Pod (which is restricted-grade) admits cleanly on the
# very first install — Helm would create the ns lazily but without the PSA
# label, leaving an admission-policy gap on first apply. Server-side apply
# means the label sticks if Helm later "owns" the ns object: the
# pod-security.kubernetes.io/enforce field's manager is our kubectl apply,
# not Helm, so a `helm upgrade` won't strip it.
NS="sealed-secrets"
ASSETS="$TOOLS_DIR/cluster/sealed-secrets"

# If the operator pinned a different chart version in .env vs the bundled
# default, prefer the .env value but make the drift visible. Same model as
# the other Phase-2 installers (metallb, cert-manager, ingress-nginx,
# metrics-server, local-path-provisioner).
pinned_default="$(tr -d '[:space:]' < "$ASSETS/chart-version.txt" 2>/dev/null || echo unknown)"
if [ "$pinned_default" != "unknown" ] && [ "$pinned_default" != "$SEALED_SECRETS_CHART_VERSION" ]; then
  echo "warn: .env SEALED_SECRETS_CHART_VERSION=$SEALED_SECRETS_CHART_VERSION differs from $ASSETS/chart-version.txt=$pinned_default; using .env value" >&2
fi

kubectl apply --server-side -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF

# Upstream repo (bitnami-labs/sealed-secrets — the maintainers' org; the
# bitnami-charts mirror exists but lags). --force-update keeps the index
# current across re-runs.
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets --force-update >/dev/null
helm repo update sealed-secrets >/dev/null

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace "$NS" \
  --version "$SEALED_SECRETS_CHART_VERSION" \
  -f "$ASSETS/helm-values.yaml" \
  --wait

echo "==> sealed-secrets installed in namespace $NS (chart $SEALED_SECRETS_CHART_VERSION)"
