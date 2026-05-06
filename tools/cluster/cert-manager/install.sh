#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${CA_CERT_PATH:?CA_CERT_PATH unset (see .env)}"
: "${CA_KEY_PATH:?CA_KEY_PATH unset (see .env)}"
: "${CLUSTER_ISSUER_NAME:?CLUSTER_ISSUER_NAME unset (see .env)}"
: "${CERT_MANAGER_CHART_VERSION:?CERT_MANAGER_CHART_VERSION unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

[ -r "$CA_CERT_PATH" ] || { echo "ERROR: cannot read $CA_CERT_PATH" >&2; exit 1; }
[ -r "$CA_KEY_PATH"  ] || { echo "ERROR: cannot read $CA_KEY_PATH"  >&2; exit 1; }

# Cert/key match: compare the public key hash (works for RSA, EC, ed25519).
# We extract the SubjectPublicKeyInfo from both sides and md5 it.
crt_pub="$(openssl x509 -in "$CA_CERT_PATH" -noout -pubkey 2>/dev/null | openssl md5)"
key_pub="$(openssl pkey -in "$CA_KEY_PATH"  -pubout 2>/dev/null | openssl md5)"
if [ -z "$crt_pub" ] || [ -z "$key_pub" ] || [ "$crt_pub" != "$key_pub" ]; then
  echo "ERROR: $CA_CERT_PATH and $CA_KEY_PATH do not match (pubkey hash mismatch)" >&2
  exit 1
fi

# 60-day expiry warning. days_left is computed from openssl x509 -enddate.
expiry_str="$(openssl x509 -in "$CA_CERT_PATH" -noout -enddate | cut -d= -f2)"
expiry_epoch="$(date -d "$expiry_str" +%s)"
now_epoch="$(date +%s)"
days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
if [ "$days_left" -lt 60 ]; then
  echo "warn: $CA_CERT_PATH expires in $days_left days ($expiry_str)" >&2
fi

NS="cert-manager"
ASSETS="$TOOLS_DIR/cluster/cert-manager"

# If the operator pinned a different chart version in .env vs the bundled
# default, prefer the .env value but make the drift visible.
pinned_default="$(tr -d '[:space:]' < "$ASSETS/chart-version.txt" 2>/dev/null || echo unknown)"
if [ "$pinned_default" != "unknown" ] && [ "$pinned_default" != "$CERT_MANAGER_CHART_VERSION" ]; then
  echo "warn: .env CERT_MANAGER_CHART_VERSION=$CERT_MANAGER_CHART_VERSION differs from $ASSETS/chart-version.txt=$pinned_default; using .env value" >&2
fi

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "$NS" --create-namespace \
  --version "$CERT_MANAGER_CHART_VERSION" \
  -f "$ASSETS/helm-values.yaml" \
  --wait

# TLS Secret carrying the CA. Server-side apply for clean idempotence.
kubectl create secret tls "$CLUSTER_ISSUER_NAME" \
  --cert="$CA_CERT_PATH" --key="$CA_KEY_PATH" \
  -n "$NS" --dry-run=client -o yaml \
  | kubectl apply --server-side --field-manager=cert-manager-install -f -

# ClusterIssuer rendered from template.
envsubst '$CLUSTER_ISSUER_NAME' \
  < "$ASSETS/cluster-issuer.yaml.tpl" \
  | kubectl apply --server-side --field-manager=cert-manager-install -f -

cmctl check api --wait=2m

echo "==> cert-manager installed; ClusterIssuer/$CLUSTER_ISSUER_NAME ready"
