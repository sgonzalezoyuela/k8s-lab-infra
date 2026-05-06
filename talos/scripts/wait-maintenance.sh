#!/usr/bin/env bash
# Poll both ${CP_IP} and ${WK0_IP} for the Talos maintenance-mode API
# (insecure, port 50000) until each responds. Per-node timeout: 5 min.
#
# After `infra-up`, Talos boots from the Image Factory ISO into maintenance
# mode and exposes an unauthenticated API. We need to wait until both nodes
# answer before we can `talosctl apply-config --insecure`.
set -euo pipefail

: "${CP_IP:?CP_IP must be set (provided by .env via dotenv-load / flake exports)}"
: "${WK0_IP:?WK0_IP must be set}"

PER_NODE_TIMEOUT="${PER_NODE_TIMEOUT:-300}"   # seconds
POLL_INTERVAL="${POLL_INTERVAL:-7}"           # seconds

wait_for_node() {
  local ip="$1"
  local label="$2"
  local deadline=$(( $(date +%s) + PER_NODE_TIMEOUT ))
  local attempt=0

  echo ">>> waiting for Talos maintenance API on ${label} (${ip}) — timeout ${PER_NODE_TIMEOUT}s"
  while :; do
    attempt=$(( attempt + 1 ))
    if talosctl --insecure -n "${ip}" version >/dev/null 2>&1; then
      echo ">>> ${label} (${ip}) is in maintenance mode (attempt ${attempt})"
      return 0
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      echo "!!! timed out after ${PER_NODE_TIMEOUT}s waiting for ${label} (${ip}) maintenance API" >&2
      return 1
    fi
    echo "    ${label} (${ip}) not ready yet, retrying in ${POLL_INTERVAL}s (attempt ${attempt})"
    sleep "${POLL_INTERVAL}"
  done
}

wait_for_node "${CP_IP}"  "cp"
wait_for_node "${WK0_IP}" "wk0"

echo ">>> both nodes are in maintenance mode — ready for apply-config"
