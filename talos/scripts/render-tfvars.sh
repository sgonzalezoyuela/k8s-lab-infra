#!/usr/bin/env bash
# Render infra/cluster.tfvars from infra/cluster.tfvars.tpl using envsubst.
#
# Computes TALOS_ISO_BASENAME from `_out/talos-schematic-id` + `TALOS_VERSION`
# (matching the basename produced by talos/scripts/build-image.sh) and uses an
# explicit envsubst allowlist so we never substitute `$something` that happens
# to appear inside a string literal.
set -euo pipefail

# Source .env if present so the script also works when invoked outside `just`.
if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi

TPL="infra/cluster.tfvars.tpl"
OUT="infra/cluster.tfvars"
SCHEMATIC_ID_FILE="_out/talos-schematic-id"

if [ ! -f "$TPL" ]; then
  echo "ERROR: template not found: $TPL" >&2
  exit 1
fi

if [ ! -f "$SCHEMATIC_ID_FILE" ]; then
  echo "ERROR: $SCHEMATIC_ID_FILE not found." >&2
  echo "Run 'just talos-image' first to build the Talos schematic and ISO." >&2
  exit 1
fi

if [ -z "${TALOS_VERSION:-}" ]; then
  echo "ERROR: TALOS_VERSION unset (check .env / 'just env-check')." >&2
  exit 1
fi

TALOS_IMAGE_PLATFORM="${TALOS_IMAGE_PLATFORM:-nocloud}"
if [ "$TALOS_IMAGE_PLATFORM" != "nocloud" ]; then
  echo "ERROR: TALOS_IMAGE_PLATFORM must be 'nocloud' for Talos NoCloud datasource support." >&2
  exit 1
fi

schematic_id="$(tr -d '[:space:]' < "$SCHEMATIC_ID_FILE")"
if [ -z "$schematic_id" ]; then
  echo "ERROR: $SCHEMATIC_ID_FILE is empty." >&2
  exit 1
fi
id_short="${schematic_id:0:8}"

export TALOS_ISO_BASENAME="talos-${TALOS_VERSION}-${id_short}-${TALOS_IMAGE_PLATFORM}.iso"

# Explicit allowlist so envsubst never touches anything else.
vars='$PROXMOX_ENDPOINT $PROXMOX_API_TOKEN_ID $PROXMOX_API_TOKEN_SECRET'
vars="$vars "'$PROXMOX_INSECURE $PROXMOX_NODE $PROXMOX_STORAGE_POOL $PROXMOX_SNIPPET_STORAGE'
vars="$vars "'$PROXMOX_ISO_STORAGE $TALOS_ISO_BASENAME $NETWORK_BRIDGE'
vars="$vars "'$CLUSTER_NAME'
vars="$vars "'$CP_CORES $CP_MEMORY_MB $CP_DISK_SIZE_GB'
vars="$vars "'$WK_CORES $WK_MEMORY_MB $WK_DISK_SIZE_GB $WK_STORAGE_DISK_SIZE_GB'
vars="$vars "'$CP_HOSTNAME $CP_IP $WK0_HOSTNAME $WK0_IP $NETWORK_CIDR $NETWORK_GATEWAY $NETWORK_DNS'

mkdir -p "$(dirname "$OUT")"
envsubst "$vars" < "$TPL" > "$OUT"

echo "==> rendered $OUT (talos iso: $TALOS_ISO_BASENAME)"
