# Companion: infra.opentofu.proxmox-vms

## Layout

```
infra/
  providers.tf            # bpg/proxmox provider, pinned version, auth from vars
  variables.tf            # all input vars (no defaults for secrets)
  main.tf                 # two proxmox_virtual_environment_vm resources (cp, wk0)
  outputs.tf              # vm_ids, vm_ips
  cluster.tfvars.tpl      # envsubst template, rendered to cluster.tfvars
  cluster.tfvars.example  # checked-in reference values
```

## providers.tf (sketch)

```hcl
terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_insecure
}
```

## variables.tf — required vars

Static / placement: `proxmox_endpoint`, `proxmox_api_token_id`,
`proxmox_api_token_secret`, `proxmox_insecure`, `proxmox_node`,
`proxmox_storage_pool`, `talos_iso_file_id`, `network_bridge`, `cluster_name`.

**Per-role sizing (separated so CP and WK can scale independently):**
- Control plane: `cp_cores` (default 4), `cp_memory_mb` (4096), `cp_disk_size_gb` (30 — OS).
- Worker: `wk_cores` (8), `wk_memory_mb` (8192), `wk_disk_size_gb` (30 — OS),
  `wk_storage_disk_size_gb` (200 — second disk for Longhorn).

Per-node identity: `cp_hostname`, `cp_ip`, `wk0_hostname`, `wk0_ip`.

No defaults for secrets (`proxmox_api_token_secret`). Sizing vars carry sane
defaults so the example tfvars stays minimal.

## main.tf — VM resource shape

The two resources differ in role-specific sizing and **the worker has a second
disk**. Sketch:

```hcl
resource "proxmox_virtual_environment_vm" "cp" {
  name      = "cp-${var.cluster_name}"
  node_name = var.proxmox_node
  on_boot   = true
  started   = true

  cpu    { cores = var.cp_cores; type = "host" }
  memory { dedicated = var.cp_memory_mb }

  # OS disk only — control plane has no data role.
  disk {
    datastore_id = var.proxmox_storage_pool
    interface    = "scsi0"
    size         = var.cp_disk_size_gb
    file_format  = "raw"
  }

  cdrom { enabled = true; interface = "ide3"; file_id = var.talos_iso_file_id }
  network_device { bridge = var.network_bridge }
  operating_system { type = "l26" }
  agent { enabled = true }
  boot_order = ["ide3", "scsi0"]
}

resource "proxmox_virtual_environment_vm" "wk0" {
  name      = "wk0-${var.cluster_name}"
  node_name = var.proxmox_node
  on_boot   = true
  started   = true

  cpu    { cores = var.wk_cores; type = "host" }
  memory { dedicated = var.wk_memory_mb }

  # OS disk (scsi0 → /dev/sda). Talos installs here.
  disk {
    datastore_id = var.proxmox_storage_pool
    interface    = "scsi0"
    size         = var.wk_disk_size_gb
    file_format  = "raw"
  }

  # Storage disk (scsi1 → /dev/sdb). Reserved for Longhorn; Talos leaves it untouched.
  disk {
    datastore_id = var.proxmox_storage_pool
    interface    = "scsi1"
    size         = var.wk_storage_disk_size_gb
    file_format  = "raw"
  }

  cdrom { enabled = true; interface = "ide3"; file_id = var.talos_iso_file_id }
  network_device { bridge = var.network_bridge }
  operating_system { type = "l26" }
  agent { enabled = true }
  boot_order = ["ide3", "scsi0"]
}
```

**Important**: do NOT pass cloud-init / static IP via Proxmox config. Talos
receives its network config through `talosctl apply-config`, not Proxmox
cloud-init. The VM gets its IP via the Talos machine config (next feature).

## Justfile additions

```just
infra-render: env-check
    ./talos/scripts/render-tfvars.sh

infra-up: infra-render
    cd infra && tofu init -upgrade && tofu apply -auto-approve -var-file=cluster.tfvars

infra-down:
    cd infra && tofu destroy -auto-approve -var-file=cluster.tfvars
```

## `infra/cluster.tfvars.tpl`

Use `envsubst` with an explicit allowlist so we don't accidentally substitute
something inside a string literal.

```
proxmox_endpoint         = "${PROXMOX_ENDPOINT}"
proxmox_api_token_id     = "${PROXMOX_API_TOKEN_ID}"
proxmox_api_token_secret = "${PROXMOX_API_TOKEN_SECRET}"
proxmox_insecure         = ${PROXMOX_INSECURE}
proxmox_node             = "${PROXMOX_NODE}"
proxmox_storage_pool     = "${PROXMOX_STORAGE_POOL}"
talos_iso_file_id        = "${PROXMOX_ISO_STORAGE}:iso/${TALOS_ISO_BASENAME}"
network_bridge           = "${NETWORK_BRIDGE}"
cluster_name             = "${CLUSTER_NAME}"
cp_cores                 = ${CP_CORES}
cp_memory_mb             = ${CP_MEMORY_MB}
cp_disk_size_gb          = ${CP_DISK_SIZE_GB}
wk_cores                 = ${WK_CORES}
wk_memory_mb             = ${WK_MEMORY_MB}
wk_disk_size_gb          = ${WK_DISK_SIZE_GB}
wk_storage_disk_size_gb  = ${WK_STORAGE_DISK_SIZE_GB}
cp_hostname              = "${CP_HOSTNAME}"
cp_ip                    = "${CP_IP}"
wk0_hostname             = "${WK0_HOSTNAME}"
wk0_ip                   = "${WK0_IP}"
```

`TALOS_ISO_BASENAME` is computed by `talos/scripts/render-tfvars.sh` from
`_out/talos-schematic-id` plus `TALOS_VERSION`, e.g. `talos-v1.13.0-abcd1234.iso`.

## State
`infra/.terraform/` and `infra/*.tfstate*` are gitignored by `bootstrap.config-scheme`.
State is local for now; remote backend is out of Phase 1 scope.

## Failure modes
- `tofu init` fails → check provider source/version pin against the registry.
- `tofu apply` 401 → token id/secret mismatch.
- `tofu apply` reports "ISO file not found" → run `just talos-image` first.
- VM created but not booting → check Proxmox UI; usually `boot_order` mismatch
  or ISO not actually mounted.
- Worker can't see the second disk inside Talos → confirm `qm config <vmid>`
  shows `scsi1:` line; the bpg/proxmox provider sometimes silently re-orders
  scsi indices on update — destroy/recreate if needed (Phase 1 is fine since
  no data is on the disk yet).
