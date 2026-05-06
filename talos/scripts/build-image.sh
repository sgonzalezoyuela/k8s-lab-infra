#!/usr/bin/env bash
# Build a Talos Image Factory schematic, download the matching ISO, and upload
# it to Proxmox ISO storage. Idempotent: same schematic -> same id, present
# ISO locally -> skip download, present ISO on Proxmox -> skip upload.
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. env-check (fail fast if any required variable is missing)
# ---------------------------------------------------------------------------
required_vars=(
  PROXMOX_ENDPOINT
  PROXMOX_NODE
  PROXMOX_API_TOKEN_ID
  PROXMOX_API_TOKEN_SECRET
  PROXMOX_ISO_STORAGE
  TALOS_VERSION
)

# Source .env if present so the script also works when invoked outside `just`.
if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi

missing=()
for v in "${required_vars[@]}"; do
  if [ -z "${!v:-}" ]; then
    missing+=("$v")
  fi
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: required env vars unset: ${missing[*]}" >&2
  echo "Run 'just env-check' to validate .env." >&2
  exit 1
fi

PROXMOX_INSECURE="${PROXMOX_INSECURE:-false}"
CURL_INSECURE=()
if [ "$PROXMOX_INSECURE" = "true" ]; then
  CURL_INSECURE+=(--insecure)
fi

OUT_DIR="_out"
mkdir -p "$OUT_DIR"

SCHEMATIC_YAML="talos/schematic.yaml"
SCHEMATIC_JSON="$OUT_DIR/talos-schematic.json"
SCHEMATIC_FINGERPRINT="$OUT_DIR/.talos-schematic.last.json"
SCHEMATIC_ID_FILE="$OUT_DIR/talos-schematic-id"

# ---------------------------------------------------------------------------
# 2. Render schematic YAML -> JSON
# ---------------------------------------------------------------------------
echo "==> rendering schematic JSON from $SCHEMATIC_YAML"
yq -o=json "$SCHEMATIC_YAML" > "$SCHEMATIC_JSON"

# ---------------------------------------------------------------------------
# 3. POST to factory (skip if id already known and content unchanged)
# ---------------------------------------------------------------------------
need_post=true
if [ -f "$SCHEMATIC_ID_FILE" ] && [ -f "$SCHEMATIC_FINGERPRINT" ]; then
  if cmp -s "$SCHEMATIC_JSON" "$SCHEMATIC_FINGERPRINT"; then
    need_post=false
  fi
fi

if [ "$need_post" = "true" ]; then
  echo "==> posting schematic to https://factory.talos.dev/schematics"
  resp="$(curl -fsS -X POST \
    --data-binary "@$SCHEMATIC_JSON" \
    https://factory.talos.dev/schematics)"
  schematic_id="$(printf '%s' "$resp" | jq -r .id)"
  if [ -z "$schematic_id" ] || [ "$schematic_id" = "null" ]; then
    echo "ERROR: factory did not return an id; response: $resp" >&2
    exit 1
  fi
  printf '%s\n' "$schematic_id" > "$SCHEMATIC_ID_FILE"
  cp "$SCHEMATIC_JSON" "$SCHEMATIC_FINGERPRINT"
  echo "    schematic id: $schematic_id"
else
  schematic_id="$(cat "$SCHEMATIC_ID_FILE")"
  echo "==> schematic unchanged, reusing id: $schematic_id"
fi

# ---------------------------------------------------------------------------
# 4. Download ISO if missing locally
# ---------------------------------------------------------------------------
id_short="${schematic_id:0:8}"
iso_basename="talos-${TALOS_VERSION}-${id_short}.iso"
iso_path="$OUT_DIR/$iso_basename"
iso_url="https://factory.talos.dev/image/${schematic_id}/${TALOS_VERSION}/metal-amd64.iso"

if [ -f "$iso_path" ]; then
  echo "==> ISO already present locally at $iso_path"
else
  echo "==> downloading ISO from $iso_url"
  curl -fL -o "$iso_path" "$iso_url"
  echo "    saved to $iso_path"
fi

# ---------------------------------------------------------------------------
# 5. Probe Proxmox for existing remote ISO
# ---------------------------------------------------------------------------
auth_header="Authorization: PVEAPIToken=${PROXMOX_API_TOKEN_ID}=${PROXMOX_API_TOKEN_SECRET}"
probe_url="${PROXMOX_ENDPOINT%/}/nodes/${PROXMOX_NODE}/storage/${PROXMOX_ISO_STORAGE}/content?content=iso"

echo "==> probing Proxmox for existing ISO ($iso_basename)"
probe_resp="$(curl -fsS "${CURL_INSECURE[@]}" \
  -H "$auth_header" \
  "$probe_url")"

if printf '%s' "$probe_resp" \
    | jq -e --arg name "$iso_basename" \
        '.data[] | select(.volid | endswith($name))' \
    >/dev/null 2>&1; then
  echo "    iso already on proxmox, skipping upload"
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Upload via multipart POST
# ---------------------------------------------------------------------------
upload_url="${PROXMOX_ENDPOINT%/}/nodes/${PROXMOX_NODE}/storage/${PROXMOX_ISO_STORAGE}/upload"
echo "==> uploading $iso_basename to Proxmox storage $PROXMOX_ISO_STORAGE on $PROXMOX_NODE"
curl -fsS "${CURL_INSECURE[@]}" \
  -H "$auth_header" \
  -F "content=iso" \
  -F "filename=$iso_basename" \
  -F "file=@$iso_path" \
  "$upload_url" \
  >/dev/null

echo "    upload complete"
