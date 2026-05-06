#!/usr/bin/env bash
# Run `talosctl bootstrap` against the control plane exactly once (idempotent).
#
# - Exit 0 on success.
# - If the bootstrap call fails because etcd is already bootstrapped, the
#   server returns an "AlreadyExists" error. We treat that as success so the
#   recipe is safely re-runnable.
# - All other errors propagate.
set -uo pipefail

: "${CP_IP:?CP_IP must be set}"

TALOSCONFIG_PATH="${TALOSCONFIG_PATH:-_out/talosconfig}"

if [ ! -f "${TALOSCONFIG_PATH}" ]; then
  echo "!!! ${TALOSCONFIG_PATH} not found — run \`just talos-config\` first" >&2
  exit 1
fi

echo ">>> bootstrapping etcd on cp (${CP_IP})"

set +e
out=$(talosctl bootstrap -n "${CP_IP}" --talosconfig "${TALOSCONFIG_PATH}" 2>&1)
rc=$?
set -e

if [ "${rc}" -eq 0 ]; then
  echo ">>> bootstrap succeeded"
  [ -n "${out}" ] && echo "${out}"
  exit 0
fi

# Re-run case: server returns "AlreadyExists" (or wording variants).
if echo "${out}" | grep -qiE 'already.?exists|already.?bootstrap'; then
  echo ">>> etcd already bootstrapped, skipping"
  exit 0
fi

echo "!!! bootstrap failed (rc=${rc})" >&2
echo "${out}" >&2
exit "${rc}"
