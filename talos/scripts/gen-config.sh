#!/usr/bin/env bash
# Generate Talos machine configs (controlplane + worker) with per-node patches.
#
# Idempotence guarantees:
#   - _out/secrets.yaml is generated ONCE (first run only). Subsequent runs
#     reuse it, so cluster PKI is preserved across .env edits.
#   - Base configs (_out/{controlplane,worker,talosconfig}.yaml) are always
#     re-rendered via `--with-secrets _out/secrets.yaml --force`, picking up
#     the (possibly updated) CP_IP for the cluster endpoint URL while keeping
#     the existing PKI.
#   - Per-node patches and final per-node configs are always re-rendered.
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Source .env (so the script works when invoked outside `just`).
# ---------------------------------------------------------------------------
if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi

# ---------------------------------------------------------------------------
# 2. Assert required environment variables.
# ---------------------------------------------------------------------------
required_vars=(
  CLUSTER_NAME
  CP_IP
  WK0_IP
  CP_HOSTNAME
  WK0_HOSTNAME
  NETWORK_CIDR
  NETWORK_GATEWAY
  NETWORK_DNS
)

missing=()
for v in "${required_vars[@]}"; do
  if [ -z "${!v:-}" ]; then
    missing+=("$v")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "gen-config.sh: missing required env vars: ${missing[*]}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Prepare output dirs.
# ---------------------------------------------------------------------------
mkdir -p _out _out/patches

# ---------------------------------------------------------------------------
# 4. Generate cluster secrets ONCE (PKI must be stable across reruns).
# ---------------------------------------------------------------------------
if [ ! -f _out/secrets.yaml ]; then
  echo "==> generating cluster secrets (one-time): _out/secrets.yaml"
  talosctl gen secrets -o _out/secrets.yaml
  chmod 600 _out/secrets.yaml
else
  echo "==> reusing existing _out/secrets.yaml"
fi

# ---------------------------------------------------------------------------
# 5. (Re)render base configs from existing secrets.
#    --force overwrites controlplane.yaml/worker.yaml/talosconfig but
#    --with-secrets ensures the EXISTING PKI is reused.
# ---------------------------------------------------------------------------
echo "==> rendering base configs from secrets"
talosctl gen config "${CLUSTER_NAME}" "https://${CP_IP}:6443" \
  --output-dir _out \
  --with-secrets _out/secrets.yaml \
  --force
chmod 600 _out/talosconfig

# ---------------------------------------------------------------------------
# 6. Render per-node patches (explicit envsubst allowlist).
# ---------------------------------------------------------------------------
echo "==> rendering per-node patches"
allowlist='${CP_HOSTNAME} ${CP_IP} ${WK0_HOSTNAME} ${WK0_IP} ${NETWORK_CIDR} ${NETWORK_GATEWAY} ${NETWORK_DNS}'
envsubst "$allowlist" < talos/patches/cp.yaml.tpl  > _out/patches/cp.yaml
envsubst "$allowlist" < talos/patches/wk0.yaml.tpl > _out/patches/wk0.yaml

# The base controlplane.yaml/worker.yaml ship with a `HostnameConfig` doc
# (auto: stable) that *conflicts* with `machine.network.hostname` set in the
# v1alpha1 doc above (validator: "static hostname is already set in v1alpha1
# config"). Append a strategic-merge "$patch: delete" doc to drop that
# HostnameConfig so v1alpha1's static hostname is the single source of truth.
# We append literally here (rather than in the template) because envsubst
# would otherwise consume the leading `$` of `$patch`.
for node in cp wk0; do
  cat >> "_out/patches/${node}.yaml" <<'EOF'
---
apiVersion: v1alpha1
kind: HostnameConfig
$patch: delete
EOF
done

# ---------------------------------------------------------------------------
# 7. Apply patches to base configs to produce final per-node machine configs.
# ---------------------------------------------------------------------------
echo "==> applying patches"
talosctl machineconfig patch _out/controlplane.yaml \
  --patch @_out/patches/cp.yaml -o _out/cp.yaml
talosctl machineconfig patch _out/worker.yaml \
  --patch @_out/patches/wk0.yaml -o _out/wk0.yaml

# ---------------------------------------------------------------------------
# 8. Validate final configs against the metal install mode.
# ---------------------------------------------------------------------------
echo "==> validating"
talosctl validate --config _out/cp.yaml  --mode metal
talosctl validate --config _out/wk0.yaml --mode metal

# ---------------------------------------------------------------------------
# 9. Patch talosconfig with endpoints (CP only) and nodes (CP + WK0).
# ---------------------------------------------------------------------------
echo "==> patching talosconfig with endpoints/nodes"
talosctl --talosconfig _out/talosconfig config endpoint "${CP_IP}"
talosctl --talosconfig _out/talosconfig config node     "${CP_IP}" "${WK0_IP}"

echo "==> done. Outputs in _out/"
