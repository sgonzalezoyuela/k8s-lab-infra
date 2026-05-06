#!/usr/bin/env bash
# Build a Talos Image Factory schematic, download the matching NoCloud ISO, and upload
# it to Proxmox ISO storage. Idempotent: same schematic -> same id, present
# ISO locally -> skip download, present ISO on Proxmox -> skip upload.
set -euo pipefail

# Mandatory: must be running inside the cluster nix develop shell so
# $TOOLS_DIR points at the shared library and $PWD is the cluster directory.
: "${TOOLS_DIR:?TOOLS_DIR not set; run inside the cluster nix develop shell}"

# Resolve all input asset paths via $TOOLS_DIR so the script behaves the same
# whether invoked from clusters/<name>/ or from a test fixture's tmpdir that
# exports its own TOOLS_DIR.
SCHEMATIC_YAML="$TOOLS_DIR/talos/schematic.yaml"

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
TALOS_IMAGE_PLATFORM="${TALOS_IMAGE_PLATFORM:-nocloud}"
if [ "$TALOS_IMAGE_PLATFORM" != "nocloud" ]; then
  echo "ERROR: TALOS_IMAGE_PLATFORM must be 'nocloud' so Talos can parse Proxmox NoCloud data." >&2
  exit 1
fi
CURL_INSECURE=()
if [ "$PROXMOX_INSECURE" = "true" ]; then
  CURL_INSECURE+=(--insecure)
fi

OUT_DIR="$PWD/_out"
mkdir -p "$OUT_DIR"

# (SCHEMATIC_YAML resolved via $TOOLS_DIR at the top of the script.)
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
iso_basename="talos-${TALOS_VERSION}-${id_short}-${TALOS_IMAGE_PLATFORM}.iso"
iso_path="$OUT_DIR/$iso_basename"
iso_url="https://factory.talos.dev/image/${schematic_id}/${TALOS_VERSION}/${TALOS_IMAGE_PLATFORM}-amd64.iso"

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

# Helper: run curl, echo the URL on failure and dump response body so the
# operator sees Proxmox's actual error message instead of just "exit code 22".
proxmox_curl() {
  local label="$1"; shift
  local body status
  body="$(curl -sS -w $'\n__HTTP_STATUS__:%{http_code}' "${CURL_INSECURE[@]}" -H "$auth_header" "$@")" || {
    echo "ERROR: curl failed for ${label}" >&2
    echo "$body" >&2
    return 1
  }
  status="${body##*__HTTP_STATUS__:}"
  body="${body%$'\n__HTTP_STATUS__:'*}"
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "ERROR: ${label} returned HTTP $status" >&2
    echo "       URL: $1" >&2
    echo "       Response body:" >&2
    printf '         %s\n' "$body" | head -10 >&2
    if [ "$status" = "401" ]; then
      echo "       Hint: 401 = Proxmox rejected the token. Check that PROXMOX_API_TOKEN_ID" >&2
      echo "             and PROXMOX_API_TOKEN_SECRET in .env match an existing token in" >&2
      echo "             Datacenter → Permissions → API Tokens. The secret is shown only once" >&2
      echo "             at creation; regenerate it if you did not save it." >&2
    elif [ "$status" = "403" ]; then
      echo "       Hint: 403 = token authenticated but lacks privilege on this resource." >&2
      echo "             For privsep tokens, grant ACLs explicitly; or set Privilege" >&2
      echo "             Separation = false on the token to inherit from the user." >&2
    fi
    return 1
  fi
  printf '%s' "$body"
}

echo "==> probing Proxmox for existing ISO ($iso_basename)"
probe_resp="$(proxmox_curl "GET storage content" "$probe_url")"

if printf '%s' "$probe_resp" \
    | jq -e --arg name "$iso_basename" \
        '.data[] | select(.volid | endswith($name))' \
    >/dev/null 2>&1; then
  echo "    iso already on proxmox, skipping upload"
  exit 0
fi

# ---------------------------------------------------------------------------
# 6. Tell Proxmox to download the ISO from the Talos Image Factory directly.
#
# We use the `download-url` endpoint instead of the multipart `upload` endpoint.
# Reasons:
#   - The multipart upload of a ~320MB ISO often hits the API daemon's
#     connection-close timeout, surfacing as `curl: (52) Empty reply from server`.
#   - `download-url` is server-to-server (Proxmox host -> factory.talos.dev),
#     usually faster than client-server upload and not subject to client-side
#     network or timeout issues.
#   - The Talos factory serves over HTTPS with a valid cert, so we can leave
#     verify-certificates=1.
# Reference: PUT /nodes/{node}/storage/{storage}/download-url
# ---------------------------------------------------------------------------
download_url_endpoint="${PROXMOX_ENDPOINT%/}/nodes/${PROXMOX_NODE}/storage/${PROXMOX_ISO_STORAGE}/download-url"

echo "==> asking Proxmox to download $iso_basename from $iso_url"
upid_resp="$(proxmox_curl "POST download-url" \
  -X POST \
  --data-urlencode "url=${iso_url}" \
  --data-urlencode "content=iso" \
  --data-urlencode "filename=${iso_basename}" \
  --data-urlencode "verify-certificates=1" \
  "$download_url_endpoint")"

upid="$(printf '%s' "$upid_resp" | jq -r .data)"
if [ -z "$upid" ] || [ "$upid" = "null" ]; then
  echo "ERROR: download-url did not return a task UPID; response: $upid_resp" >&2
  exit 1
fi
echo "    Proxmox download task: $upid"

# Poll task status until stopped, with a hard timeout.
status_url="${PROXMOX_ENDPOINT%/}/nodes/${PROXMOX_NODE}/tasks/${upid}/status"
deadline=$(( $(date +%s) + 600 ))   # 10 minutes
while :; do
  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "ERROR: timed out waiting for Proxmox download task $upid" >&2
    exit 1
  fi
  status_resp="$(proxmox_curl "GET task status" "$status_url")"
  status="$(printf '%s' "$status_resp" | jq -r .data.status)"
  if [ "$status" = "stopped" ]; then
    exit_status="$(printf '%s' "$status_resp" | jq -r .data.exitstatus)"
    if [ "$exit_status" = "OK" ]; then
      echo "    download complete"
      break
    else
      echo "ERROR: Proxmox download task ended with status: $exit_status" >&2
      log_url="${PROXMOX_ENDPOINT%/}/nodes/${PROXMOX_NODE}/tasks/${upid}/log"
      log_resp="$(proxmox_curl "GET task log" "$log_url" || true)"
      printf '%s' "$log_resp" | jq -r '.data[]?.t' 2>/dev/null | tail -20 >&2 || true
      exit 1
    fi
  fi
  sleep 3
done
