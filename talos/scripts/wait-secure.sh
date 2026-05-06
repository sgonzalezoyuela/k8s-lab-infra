#!/usr/bin/env bash
# Poll ${CP_IP} for the Talos secure API (PKI from _out/talosconfig) until it
# responds. Timeout: 5 min.
#
# After `talos-apply`, Talos installs to disk, reboots, and comes up in secure
# mode. We must wait for the authenticated API on the control plane before we
# can call `talosctl bootstrap`.
set -euo pipefail

: "${CP_IP:?CP_IP must be set}"

TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-_out/talosconfig}"
TIMEOUT="${TIMEOUT:-300}"           # seconds
POLL_INTERVAL="${POLL_INTERVAL:-7}"  # seconds

if [ ! -f "${TALOSCONFIG_PATH}" ]; then
  echo "!!! ${TALOSCONFIG_PATH} not found — run \`just talos-config\` first" >&2
  exit 1
fi

deadline=$(( $(date +%s) + TIMEOUT ))
attempt=0

echo ">>> waiting for Talos secure API on cp (${CP_IP}) — timeout ${TIMEOUT}s"
while :; do
  attempt=$(( attempt + 1 ))
  # NOTE: --talosconfig (NOT --insecure). Once apply-config has run and the
  # node has rebooted into secure mode, the insecure listener is gone.
  if talosctl --talosconfig "${TALOSCONFIG_PATH}" -n "${CP_IP}" version >/dev/null 2>&1; then
    echo ">>> cp (${CP_IP}) secure API is up (attempt ${attempt})"
    exit 0
  fi
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "!!! timed out after ${TIMEOUT}s waiting for cp (${CP_IP}) secure API" >&2
    exit 1
  fi
  echo "    cp (${CP_IP}) secure API not ready yet, retrying in ${POLL_INTERVAL}s (attempt ${attempt})"
  sleep "${POLL_INTERVAL}"
done
