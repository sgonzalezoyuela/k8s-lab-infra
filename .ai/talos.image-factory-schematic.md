# Companion: talos.image-factory-schematic

## Why
Talos is immutable. To get Longhorn (iSCSI) and qemu-guest-agent on the cluster
nodes we MUST bake them into the image via the Talos Image Factory before VMs boot.

## Files
- `talos/schematic.yaml` — declarative input describing the desired extensions.
- `talos/scripts/build-image.sh` — invoked by `just talos-image`; wraps the steps below.
- Outputs in `_out/`:
  - `_out/talos-schematic.json` — exact JSON POSTed to the factory.
  - `_out/talos-schematic-id` — id returned by the factory (sha256-ish).
  - `_out/talos-<version>-<id-short>.iso` — local copy of the ISO (kept for debugging; not the source of truth on the Proxmox side).

## `talos/schematic.yaml`

```yaml
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
```

## Build sequence (`talos/scripts/build-image.sh`)

1. Render JSON: `yq -o=json talos/schematic.yaml > _out/talos-schematic.json`
2. POST to factory:
   `curl -fsS -X POST --data-binary @_out/talos-schematic.json https://factory.talos.dev/schematics`
   parse `.id` from the response, write to `_out/talos-schematic-id`.
   Skip the POST when the rendered JSON matches a fingerprint stashed at
   `_out/.talos-schematic.last.json` (idempotent).
3. Compute local ISO path: `_out/talos-${TALOS_VERSION}-${id:0:8}.iso`.
   If the file is missing locally, download via:
   `curl -fL -o <path> https://factory.talos.dev/image/<id>/${TALOS_VERSION}/metal-amd64.iso`
4. Probe Proxmox for the ISO's existence under `${PROXMOX_ISO_STORAGE}` via
   `GET /nodes/${PROXMOX_NODE}/storage/${PROXMOX_ISO_STORAGE}/content?content=iso`
   and `jq` for a volid that endswith the basename. If found, exit 0.
5. **Tell Proxmox to download from the factory directly** via the `download-url`
   endpoint — NOT a multipart upload from the operator's machine:
   `POST /nodes/${PROXMOX_NODE}/storage/${PROXMOX_ISO_STORAGE}/download-url`
   form-encoded with `url=<factory-iso-url>`, `content=iso`, `filename=<basename>`,
   `verify-certificates=1`. Returns a UPID (task id).
6. Poll `GET /nodes/${PROXMOX_NODE}/tasks/${UPID}/status` until `data.status` is
   `stopped`. On `data.exitstatus = "OK"` the download succeeded; otherwise dump
   the task log via `GET /tasks/${UPID}/log` and exit 1.

## Why download-url instead of POST upload

The classic upload endpoint (`POST /storage/<storage>/upload` with multipart body)
hits the API daemon's connection-close timeout for ~320MB ISOs, surfacing as
`curl: (52) Empty reply from server`. The download-url endpoint sidesteps the
problem entirely:

- Server-to-server transfer (Proxmox host → factory.talos.dev).
- No client-side network bottleneck or proxy timeout.
- Asynchronous task, polled via the standard tasks API.
- The Talos factory serves over HTTPS with a valid cert, so we keep
  `verify-certificates=1`.

The local ISO copy under `_out/` is kept anyway — useful for offline debugging,
sanity-checking the schematic, or fallback if you ever need to do a manual
upload.

## Auth
All Proxmox API calls send:

```
Authorization: PVEAPIToken=${PROXMOX_API_TOKEN_ID}=${PROXMOX_API_TOKEN_SECRET}
```

`curl --insecure` is added only when `PROXMOX_INSECURE=true`.

## Justfile recipe

```just
talos-image: env-check
    ./talos/scripts/build-image.sh
```

## Idempotence
- Same `talos/schematic.yaml` → same id → no POST.
- ISO present locally → skip local download.
- ISO present on Proxmox → skip download-url request.

## Failure modes
- Factory returns 4xx → check schematic.yaml syntax (must be valid YAML, only
  `officialExtensions` under `customization.systemExtensions`).
- Proxmox 401 → `PROXMOX_API_TOKEN_ID` / `PROXMOX_API_TOKEN_SECRET` mismatch.
  Check Datacenter → Permissions → API Tokens; the secret is shown once at
  creation and must be regenerated if lost.
- Proxmox 403 → token authenticated but lacks privilege on the storage. Either
  set Privilege Separation = false on the token, or grant explicit ACL on the
  storage path.
- `download-url` fails with `wrong filename extension` or similar → confirm
  `${PROXMOX_ISO_STORAGE}` actually has `iso` enabled in its content types
  (`pvesm status` from the Proxmox shell shows the configured types).
- Download task ends with `exitstatus != OK` → the script fetches and prints
  the last 20 lines of the task log; usually a network or DNS issue between
  the Proxmox host and `factory.talos.dev`.
