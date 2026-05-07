#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${INGRESS_LB_IP:?INGRESS_LB_IP unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NS="ingress-nginx"

# 1. Helm release present in the namespace.
helm -n "$NS" status ingress-nginx >/dev/null \
  || { echo "ERROR: helm release ingress-nginx not deployed in $NS" >&2; exit 1; }

# 2. Controller Deployment is rolled out and Ready.
kubectl -n "$NS" rollout status deployment/ingress-nginx-controller --timeout=60s

# 3. MetalLB allocated the *pinned* IP. This is the silent failure we
#    actually care about: if INGRESS_LB_IP is already taken by something
#    else in the pool, MetalLB falls back to the first free IP in the
#    range and the controller comes up with the wrong address. Compare
#    against the operator-configured value, not just "any IP in range".
got_ip="$(kubectl -n "$NS" get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")"
if [ "$got_ip" != "$INGRESS_LB_IP" ]; then
  echo "ERROR: ingress-nginx-controller LB IP is '$got_ip' but INGRESS_LB_IP=$INGRESS_LB_IP" >&2
  echo "       Check MetalLB pool, IP conflicts (kubectl get svc -A | grep $INGRESS_LB_IP), and svc.spec.loadBalancerIP" >&2
  exit 1
fi

echo "==> ingress-nginx smoke OK (controller Ready; LB IP=$INGRESS_LB_IP)"
