#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${METALLB_RANGE:?METALLB_RANGE unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

NAME="mlb-smoke-test"
NS="default"

cleanup() {
  kubectl -n "$NS" delete service "$NAME" --ignore-not-found --wait=false 2>/dev/null || true
}
trap cleanup EXIT

# A LoadBalancer Service with NO selector and NO backend pods is the cheapest
# possible MetalLB exerciser: the controller still allocates an IP from the
# pool and surfaces it on .status.loadBalancer.ingress[0].ip — that's all we
# need to assert the pool + advertisement wiring is correct.
cat <<EOF | kubectl apply --server-side --field-manager=metallb-smoke -f -
apiVersion: v1
kind: Service
metadata:
  name: $NAME
  namespace: $NS
spec:
  type: LoadBalancer
  ports:
    - name: noop
      port: 8080
      targetPort: 8080
EOF

# Wait up to 30s for an IP.
deadline=$(( $(date +%s) + 30 ))
ip=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  ip="$(kubectl -n "$NS" get svc "$NAME" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$ip" ] && break
  sleep 1
done
[ -n "$ip" ] || { echo "ERROR: MetalLB did not assign an IP within 30s" >&2; exit 1; }

# Range check — same arithmetic as install.sh, inlined for self-containment.
ip_to_int() {
  local i="$1" a b c d
  IFS=. read -r a b c d <<<"$i"
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}
range_addr="${METALLB_RANGE%/*}"
range_pref="${METALLB_RANGE#*/}"
mask=$(( 0xFFFFFFFF << (32 - range_pref) & 0xFFFFFFFF ))
range_net=$(( $(ip_to_int "$range_addr") & mask ))
range_bcast=$(( range_net | (~mask & 0xFFFFFFFF) ))
ip_int=$(ip_to_int "$ip")
if [ "$ip_int" -lt "$range_net" ] || [ "$ip_int" -gt "$range_bcast" ]; then
  echo "ERROR: assigned IP $ip is OUTSIDE METALLB_RANGE=$METALLB_RANGE" >&2
  exit 1
fi

echo "==> MetalLB smoke OK (Service/$NAME got $ip from $METALLB_RANGE)"
