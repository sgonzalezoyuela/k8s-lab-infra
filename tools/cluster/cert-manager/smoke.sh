#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${CLUSTER_ISSUER_NAME:?CLUSTER_ISSUER_NAME unset (see .env)}"
: "${CLUSTER_DOMAIN:?CLUSTER_DOMAIN unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NAME="cm-smoke-test"
NS="default"

cleanup() {
  kubectl -n "$NS" delete certificate "$NAME"     --ignore-not-found --wait=false || true
  kubectl -n "$NS" delete secret      "$NAME-tls" --ignore-not-found --wait=false || true
}
trap cleanup EXIT

cat <<EOF | kubectl apply --server-side --field-manager=cert-manager-smoke -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $NAME
  namespace: $NS
spec:
  secretName: $NAME-tls
  duration: 24h
  issuerRef:
    name: $CLUSTER_ISSUER_NAME
    kind: ClusterIssuer
  dnsNames:
    - smoke.$CLUSTER_DOMAIN
EOF

kubectl -n "$NS" wait --for=condition=Ready certificate/"$NAME" --timeout=60s
echo "==> cert-manager smoke OK (Certificate/$NAME signed by $CLUSTER_ISSUER_NAME)"
