# ---------------------------------------------------------------------------
# Proxmox endpoint / auth
# ---------------------------------------------------------------------------
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, e.g. https://pve.example.com:8006/api2/json"
  type        = string
}

variable "proxmox_api_token_id" {
  description = "Proxmox API token id, e.g. 'root@pam!terraform'"
  type        = string
}

variable "proxmox_api_token_secret" {
  description = "Proxmox API token secret (UUID). REQUIRED, no default."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification when talking to the Proxmox API."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Proxmox placement
# ---------------------------------------------------------------------------
variable "proxmox_node" {
  description = "Target Proxmox node name."
  type        = string
}

variable "proxmox_storage_pool" {
  description = "Datastore (storage pool) for VM disks."
  type        = string
}

variable "proxmox_snippet_storage" {
  description = "Datastore that supports Proxmox snippets content for NoCloud user-data."
  type        = string
}

variable "talos_iso_file_id" {
  description = "Proxmox file id for the Talos ISO, e.g. 'local:iso/talos-v1.13.0-abcd1234.iso'."
  type        = string
}

variable "network_bridge" {
  description = "Proxmox network bridge for the VM NIC, e.g. 'vmbr0'."
  type        = string
}

# NOTE: network_cidr / network_gateway / network_dns are intentionally NOT
# OpenTofu variables. We deliberately do NOT pass static IP / gateway / DNS
# through Proxmox cloud-init (no `ip_config` / `dns` blocks in main.tf),
# because that creates a cloud-init network-config that competes with the
# Talos machine config's `machine.network` and breaks default-route install
# on off-link gateways. Talos reads its own `machine.network` from user-data
# and configures everything itself. The values still live in `.env` and are
# consumed by gen-config.sh + talos/patches/*.tpl when rendering snippets.

# NOTE: The control-plane and worker Talos machine configs (_out/cp.yaml,
# _out/wk0.yaml) are NOT consumed as variables here. The Proxmox API does
# not support uploading snippets, so we reference each VM's user-data by
# snippet volume id (see local.* in main.tf) instead of passing a local path
# to a `proxmox_virtual_environment_file` resource. The operator copies the
# files onto the Proxmox host manually using the scp commands printed by
# `talos/scripts/print-snippet-upload-cmd.sh`.

# ---------------------------------------------------------------------------
# Cluster identity
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "Cluster name, used to compose VM names (cp-<name>, wk0-<name>)."
  type        = string
}

# ---------------------------------------------------------------------------
# Control-plane VM sizing
# ---------------------------------------------------------------------------
variable "cp_cores" {
  description = "vCPU cores per control-plane VM."
  type        = number
  default     = 4
}

variable "cp_memory_mb" {
  description = "Memory per control-plane VM in megabytes."
  type        = number
  default     = 4096
}

variable "cp_disk_size_gb" {
  description = "OS disk size per control-plane VM in gigabytes."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Worker VM sizing
# ---------------------------------------------------------------------------
variable "wk_cores" {
  description = "vCPU cores per worker VM."
  type        = number
  default     = 8
}

variable "wk_memory_mb" {
  description = "Memory per worker VM in megabytes."
  type        = number
  default     = 8192
}

variable "wk_disk_size_gb" {
  description = "OS disk size per worker VM in gigabytes."
  type        = number
  default     = 30
}

variable "wk_storage_disk_size_gb" {
  description = "Second disk size per worker VM in gigabytes (consumed by Longhorn)."
  type        = number
  default     = 200
}

# ---------------------------------------------------------------------------
# Per-node identity (used by outputs / downstream features)
# ---------------------------------------------------------------------------
variable "cp_hostname" {
  description = "Control-plane node FQDN."
  type        = string
}

variable "cp_ip" {
  description = "Control-plane node IPv4 address."
  type        = string
}

variable "wk0_hostname" {
  description = "Worker-0 node FQDN."
  type        = string
}

variable "wk0_ip" {
  description = "Worker-0 node IPv4 address."
  type        = string
}
