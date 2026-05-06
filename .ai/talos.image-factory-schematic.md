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
  - `_out/talos-<version>-<id-short>.iso` — downloaded ISO.

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
3. Compute local ISO path: `_out/talos-${TALOS_VERSION}-${id:0:8}.iso`.
   If missing, download:
   `curl -fL -o <path> https://factory.talos.dev/image/<id>/${TALOS_VERSION}/metal-amd64.iso`
4. Check Proxmox for existing ISO via
   `GET /nodes/${PROXMOX_NODE}/storage/${PROXMOX_ISO_STORAGE}/content?content=iso`
   and look for the basename. If absent, upload via
   `POST /nodes/${PROXMOX_NODE}/storage/${PROXMOX_ISO_STORAGE}/upload`
   (multipart form-data: `content=iso`, `filename=<basename>`, `file=@<path>`).

## Auth
All Proxmox API calls send:

```
Authorization: PVEAPIToken=${PROXMOX_API_TOKEN_ID}=${PROXMOX_API_TOKEN_SECRET}
```

Use `curl --insecure` only when `PROXMOX_INSECURE=true`.

## Justfile recipe

```just
talos-image: env-check
    ./talos/scripts/build-image.sh
```

## Idempotence
- Same `talos/schematic.yaml` → same id → no-op (factory dedupes by content hash).
- ISO present locally → skip download.
- ISO present on Proxmox → skip upload.

## Failure modes
- Factory returns 4xx → check schematic.yaml syntax (must be valid YAML, only
  `officialExtensions` under `customization.systemExtensions`).
- Proxmox upload 4xx → most likely cause is wrong `content` field on storage
  (check that `${PROXMOX_ISO_STORAGE}` actually has `iso` in its content types).
- Slow upload → ISO is ~80MB; on a fast LAN should be <30s.
