#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${CLUSTER_DOMAIN:?CLUSTER_DOMAIN unset (see .env)}"
: "${CLUSTER_ISSUER_NAME:?CLUSTER_ISSUER_NAME unset (see .env)}"
: "${METALLB_RANGE:?METALLB_RANGE unset (see .env)}"
: "${INGRESS_NGINX_CHART_VERSION:?INGRESS_NGINX_CHART_VERSION unset (see .env)}"
: "${INGRESS_LB_IP:?INGRESS_LB_IP unset (see .env)}"
: "${INGRESS_DEFAULT_TLS_SECRET:?INGRESS_DEFAULT_TLS_SECRET unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

# CIDR sanity: validate INGRESS_LB_IP shape and that it falls inside
# METALLB_RANGE. Pure-bash bitmask arithmetic so we don't depend on python
# in the devShell. Same arithmetic as tools/cluster/metallb/install.sh.
ip_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

if [[ ! "$INGRESS_LB_IP" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "ERROR: INGRESS_LB_IP not a valid IPv4 address: $INGRESS_LB_IP" >&2
  exit 1
fi
IFS=. read -r oa ob oc od <<<"$INGRESS_LB_IP"
for o in "$oa" "$ob" "$oc" "$od"; do
  if [ "$o" -gt 255 ]; then
    echo "ERROR: INGRESS_LB_IP octet out of range: $INGRESS_LB_IP" >&2
    exit 1
  fi
done

range_addr="${METALLB_RANGE%/*}"
range_pref="${METALLB_RANGE#*/}"
if [[ ! "$range_addr" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || \
   [[ ! "$range_pref" =~ ^[0-9]+$ ]] || \
   [ "$range_pref" -gt 32 ]; then
  echo "ERROR: METALLB_RANGE not a valid IPv4 CIDR: $METALLB_RANGE" >&2
  exit 1
fi

mask=$(( 0xFFFFFFFF << (32 - range_pref) & 0xFFFFFFFF ))
range_net=$(( $(ip_to_int "$range_addr") & mask ))
range_bcast=$(( range_net | (~mask & 0xFFFFFFFF) ))
ip_int=$(ip_to_int "$INGRESS_LB_IP")
if [ "$ip_int" -lt "$range_net" ] || [ "$ip_int" -gt "$range_bcast" ]; then
  echo "ERROR: INGRESS_LB_IP=$INGRESS_LB_IP is OUTSIDE METALLB_RANGE=$METALLB_RANGE — pick an IP inside the pool" >&2
  exit 1
fi

NS="ingress-nginx"
ASSETS="$TOOLS_DIR/cluster/ingress-nginx"

# If the operator pinned a different chart version in .env vs the bundled
# default, prefer the .env value but make the drift visible. Same model as
# the other Phase-2 installers (metallb, cert-manager).
pinned_default="$(tr -d '[:space:]' < "$ASSETS/chart-version.txt" 2>/dev/null || echo unknown)"
if [ "$pinned_default" != "unknown" ] && [ "$pinned_default" != "$INGRESS_NGINX_CHART_VERSION" ]; then
  echo "warn: .env INGRESS_NGINX_CHART_VERSION=$INGRESS_NGINX_CHART_VERSION differs from $ASSETS/chart-version.txt=$pinned_default; using .env value" >&2
fi

# Pre-create the namespace with restricted Pod Security Admission labels.
# The controller is fully PSA-restricted-compatible (NET_BIND_SERVICE is the
# one capability restricted PSA still permits, which is exactly what nginx
# needs to bind 80/443 as uid 101). Server-side apply makes this idempotent
# and keeps the labels even if helm later "owns" the namespace.
kubectl apply --server-side --field-manager=ingress-install -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
helm repo update ingress-nginx >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "$NS" \
  --version "$INGRESS_NGINX_CHART_VERSION" \
  -f "$ASSETS/helm-values.yaml" \
  --set "controller.service.loadBalancerIP=$INGRESS_LB_IP" \
  --set "controller.extraArgs.default-ssl-certificate=$NS/$INGRESS_DEFAULT_TLS_SECRET" \
  --wait

# Wildcard *.${CLUSTER_DOMAIN} default-ssl Certificate. Wired into the
# controller via --set controller.extraArgs.default-ssl-certificate above,
# so unmatched-SNI clients still get a valid TLS handshake instead of the
# fake "Kubernetes Ingress Controller Fake Certificate".
export CLUSTER_DOMAIN CLUSTER_ISSUER_NAME INGRESS_DEFAULT_TLS_SECRET
envsubst '$CLUSTER_DOMAIN $CLUSTER_ISSUER_NAME $INGRESS_DEFAULT_TLS_SECRET' \
  < "$ASSETS/default-ssl-cert.yaml.tpl" \
  | kubectl apply --server-side --field-manager=ingress-install -f -

kubectl -n "$NS" wait --for=condition=Ready certificate/"$INGRESS_DEFAULT_TLS_SECRET" --timeout=60s

echo "==> ingress-nginx installed; LB IP=$INGRESS_LB_IP, default cert *.$CLUSTER_DOMAIN signed by $CLUSTER_ISSUER_NAME"
