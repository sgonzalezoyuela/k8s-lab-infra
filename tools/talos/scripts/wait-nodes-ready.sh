#!/usr/bin/env bash
# Wait for both Kubernetes nodes (cp + wk0) to report Ready=True. Timeout 5 min.
#
# Uses `kubectl get nodes -o jsonpath` to extract the Ready condition status
# for each node. We expect exactly two nodes; both must show "True".
set -euo pipefail

: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"
: "${KUBECONFIG:?KUBECONFIG must be set (provided by the flake)}"

TIMEOUT="${TIMEOUT:-300}"           # seconds
POLL_INTERVAL="${POLL_INTERVAL:-7}"  # seconds
EXPECTED_NODES="${EXPECTED_NODES:-2}"

if [ ! -f "${KUBECONFIG}" ]; then
  echo "!!! ${KUBECONFIG} not found — run \`just kubeconfig\` first" >&2
  exit 1
fi

deadline=$(( $(date +%s) + TIMEOUT ))
attempt=0

echo ">>> waiting for ${EXPECTED_NODES} nodes to be Ready — timeout ${TIMEOUT}s"
while :; do
  attempt=$(( attempt + 1 ))
  # jsonpath: one "True"/"False"/"Unknown" per node, space-separated.
  statuses=$(kubectl --kubeconfig "${KUBECONFIG}" get nodes \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || true)

  if [ -n "${statuses}" ]; then
    # Count True tokens.
    ready_count=$(printf '%s\n' ${statuses} | grep -c '^True$' || true)
    total_count=$(printf '%s\n' ${statuses} | wc -w | tr -d ' ')
    if [ "${ready_count}" -ge "${EXPECTED_NODES}" ] \
       && [ "${total_count}" -ge "${EXPECTED_NODES}" ]; then
      echo ">>> ${ready_count}/${total_count} nodes Ready (attempt ${attempt})"
      kubectl --kubeconfig "${KUBECONFIG}" get nodes -o wide || true
      exit 0
    fi
    echo "    ${ready_count}/${total_count} nodes Ready, retrying in ${POLL_INTERVAL}s (attempt ${attempt})"
  else
    echo "    kubectl returned no nodes yet, retrying in ${POLL_INTERVAL}s (attempt ${attempt})"
  fi

  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "!!! timed out after ${TIMEOUT}s waiting for nodes Ready" >&2
    kubectl --kubeconfig "${KUBECONFIG}" get nodes -o wide >&2 || true
    exit 1
  fi

  sleep "${POLL_INTERVAL}"
done
