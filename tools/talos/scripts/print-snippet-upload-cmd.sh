#!/usr/bin/env bash
# Print the exact scp commands the operator must run to place the per-node
# Talos NoCloud user-data snippets onto the Proxmox host's snippet storage.
#
# Why this script exists:
#   The Proxmox API has no endpoint for uploading `snippets` content. The
#   bpg/proxmox provider can only do it over SSH+SCP, which we deliberately
#   avoid (we don't want OpenTofu to require SSH credentials in addition to
#   the API token). Instead OpenTofu references the snippet by its volume
#   id, e.g. `local:snippets/talos-<cluster>-cp.yaml`, and trusts that the
#   file is already in place. This script tells the operator how to put it
#   there.
#
# Always exits 0. Designed to be safe to call from `render-tfvars.sh` even in
# the structural test fixture; if a value is missing we print a placeholder
# rather than failing.

set -u

: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi

ssh_user="${PROXMOX_SSH_USER:-root}"
ssh_host="${PROXMOX_SSH_HOST:-<PROXMOX_SSH_HOST unset>}"
snippets_dir="${PROXMOX_SNIPPETS_DIR:-/var/lib/vz/snippets}"
snippet_storage="${PROXMOX_SNIPPET_STORAGE:-local}"
cluster_name="${CLUSTER_NAME:-<CLUSTER_NAME unset>}"

cp_local="$PWD/_out/cp.yaml"
wk0_local="$PWD/_out/wk0.yaml"
cp_remote_name="talos-${cluster_name}-cp.yaml"
wk0_remote_name="talos-${cluster_name}-wk0.yaml"

cat <<EOF

==> SNIPPET UPLOAD REQUIRED (manual step)

The Proxmox API does not expose a snippet-upload endpoint, so OpenTofu will
NOT push the Talos NoCloud user-data files for you. Copy them onto the
Proxmox host BEFORE running 'just infra-up' (or 'tofu apply'):

  scp ${cp_local}  ${ssh_user}@${ssh_host}:${snippets_dir}/${cp_remote_name}
  scp ${wk0_local} ${ssh_user}@${ssh_host}:${snippets_dir}/${wk0_remote_name}

Verify Proxmox sees them under storage '${snippet_storage}':

  ssh ${ssh_user}@${ssh_host} "ls -la ${snippets_dir}/"
  ssh ${ssh_user}@${ssh_host} "pvesm list ${snippet_storage} | grep snippets"

OpenTofu will reference these files as:

  ${snippet_storage}:snippets/${cp_remote_name}
  ${snippet_storage}:snippets/${wk0_remote_name}

If the files are already present and unchanged, this step is a no-op.
Re-run with 'just snippets-cmd' any time you want to see this again.

EOF

exit 0
