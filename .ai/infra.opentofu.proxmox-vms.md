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

`proxmox_endpoint`, `proxmox_api_token_id`, `proxmox_api_token_secret`,
`proxmox_insecure`, `proxmox_node`, `proxmox_storage_pool`, `talos_iso_file_id`,
`network_bridge`, `cluster_name`, `vm_cores`, `vm_memory_mb`, `vm_disk_size_gb`,
`cp_hostname`, `cp_ip`, `wk0_hostname`, `wk0_ip`.

No defaults for secrets (`proxmox_api_token_secret`). Other vars may have safe
defaults to keep the example minimal.

## main.tf — VM resource shape

```hcl
resource "proxmox_virtual_environment_vm" "cp" {
  name      = "cp-${var.cluster_name}"
  node_name = var.proxmox_node
  on_boot   = true
  started   = true

  cpu {
    cores = var.vm_cores
    type  = "host"
  }
  memory {
    dedicated = var.vm_memory_mb
  }

  disk {
    datastore_id = var.proxmox_storage_pool
    interface    = "scsi0"
    size         = var.vm_disk_size_gb
    file_format  = "raw"
  }

  cdrom {
    enabled = true
    file_id = var.talos_iso_file_id   # e.g. "local:iso/talos-v1.8.2-abcd1234.iso"
  }

  network_device {
    bridge = var.network_bridge
  }

  operating_system {
    type = "l26"
  }
  agent {
    enabled = true   # qemu-guest-agent extension is in the image
  }
  boot_order = ["ide3", "scsi0"]
}

# wk0 mirrors cp with overridden name; the only differences are name/hostname.
```

**Important**: do NOT pass cloud-init / static IP via Proxmox config. Talos
receives its network config through `talosctl apply-config`, not Proxmox
cloud-init. The VM gets its IP via the Talos machine config (next feature).

## Justfile additions

```just
infra-render: env-check
    envsubst < infra/cluster.tfvars.tpl > infra/cluster.tfvars

infra-up: infra-render
    cd infra && tofu init -upgrade && tofu apply -auto-approve -var-file=cluster.tfvars

infra-down:
    cd infra && tofu destroy -auto-approve -var-file=cluster.tfvars
```

## `infra/cluster.tfvars.tpl`

Use `envsubst` with explicit variable names so we don't accidentally substitute
something inside a string literal. Example:

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
vm_cores                 = ${VM_CORES}
vm_memory_mb             = ${VM_MEMORY_MB}
vm_disk_size_gb          = ${VM_DISK_SIZE_GB}
cp_hostname              = "${CP_HOSTNAME}"
cp_ip                    = "${CP_IP}"
wk0_hostname             = "${WK0_HOSTNAME}"
wk0_ip                   = "${WK0_IP}"
```

`TALOS_ISO_BASENAME` is computed by `infra-render` from `_out/talos-schematic-id`
plus `TALOS_VERSION`, e.g. `talos-v1.8.2-abcd1234.iso`.

## State
`infra/.terraform/` and `infra/*.tfstate*` are gitignored by `bootstrap.config-scheme`.
State is local for now; remote backend is out of Phase 1 scope.

## Failure modes
- `tofu init` fails → check provider source/version pin against the registry.
- `tofu apply` 401 → token id/secret mismatch.
- `tofu apply` reports "ISO file not found" → run `just talos-image` first.
- VM created but not booting → check Proxmox UI; usually `boot_order` mismatch
  or ISO not actually mounted.
