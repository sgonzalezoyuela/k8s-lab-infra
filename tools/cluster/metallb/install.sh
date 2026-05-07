#!/usr/bin/env bash
set -euo pipefail
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

[ -f .env ] && { set -a; . ./.env; set +a; }

: "${METALLB_RANGE:?METALLB_RANGE unset (see .env)}"
: "${METALLB_CHART_VERSION:?METALLB_CHART_VERSION unset (see .env)}"
: "${CP_IP:?CP_IP unset (see .env)}"
: "${WK0_IP:?WK0_IP unset (see .env)}"
: "${KUBECONFIG:?KUBECONFIG unset; run just kubeconfig first}"

# CIDR sanity: validate METALLB_RANGE shape, then make sure neither node IP is
# inside it. Pure-bash so we don't depend on python being in the devShell.
ip_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

range_addr="${METALLB_RANGE%/*}"
range_pref="${METALLB_RANGE#*/}"
if [[ ! "$range_addr" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || \
   [[ ! "$range_pref" =~ ^[0-9]+$ ]] || \
   [ "$range_pref" -gt 32 ]; then
  echo "ERROR: METALLB_RANGE not a valid IPv4 CIDR: $METALLB_RANGE" >&2
  exit 1
fi

# Octet range check — IPv4 each byte 0..255.
IFS=. read -r oa ob oc od <<<"$range_addr"
for o in "$oa" "$ob" "$oc" "$od"; do
  if [ "$o" -gt 255 ]; then
    echo "ERROR: METALLB_RANGE octet out of range: $METALLB_RANGE" >&2
    exit 1
  fi
done

mask=$(( 0xFFFFFFFF << (32 - range_pref) & 0xFFFFFFFF ))
range_int=$(ip_to_int "$range_addr")
range_net=$(( range_int & mask ))
range_bcast=$(( range_net | (~mask & 0xFFFFFFFF) ))

for label in CP_IP WK0_IP; do
  ip="${!label}"
  ip_int=$(ip_to_int "$ip")
  if [ "$ip_int" -ge "$range_net" ] && [ "$ip_int" -le "$range_bcast" ]; then
    echo "ERROR: $label=$ip is inside METALLB_RANGE=$METALLB_RANGE — pick a non-overlapping pool" >&2
    exit 1
  fi
done

NS="metallb-system"
ASSETS="$TOOLS_DIR/cluster/metallb"

# If the operator pinned a different chart version in .env vs the bundled
# default, prefer the .env value but make the drift visible.
pinned_default="$(tr -d '[:space:]' < "$ASSETS/chart-version.txt" 2>/dev/null || echo unknown)"
if [ "$pinned_default" != "unknown" ] && [ "$pinned_default" != "$METALLB_CHART_VERSION" ]; then
  echo "warn: .env METALLB_CHART_VERSION=$METALLB_CHART_VERSION differs from $ASSETS/chart-version.txt=$pinned_default; using .env value" >&2
fi

helm repo add metallb https://metallb.github.io/metallb --force-update >/dev/null
helm repo update metallb >/dev/null
helm upgrade --install metallb metallb/metallb \
  --namespace "$NS" --create-namespace \
  --version "$METALLB_CHART_VERSION" \
  -f "$ASSETS/helm-values.yaml" \
  --wait

# Speaker DaemonSet must be Ready on every node before pool config is useful.
kubectl -n "$NS" rollout status daemonset/metallb-speaker --timeout=2m

# Pool first, then advertisement that references it. Server-side apply for clean idempotence.
export METALLB_RANGE
envsubst '$METALLB_RANGE' < "$ASSETS/ip-address-pool.yaml.tpl" \
  | kubectl apply --server-side --field-manager=metallb-install -f -
kubectl apply --server-side --field-manager=metallb-install -f "$ASSETS/l2-advertisement.yaml.tpl"

echo "==> MetalLB installed; IPAddressPool/default-pool=${METALLB_RANGE}, L2Advertisement/default-l2-adv ready"
