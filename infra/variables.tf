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

variable "talos_iso_file_id" {
  description = "Proxmox file id for the Talos ISO, e.g. 'local:iso/talos-v1.8.2-abcd1234.iso'."
  type        = string
}

variable "network_bridge" {
  description = "Proxmox network bridge for the VM NIC, e.g. 'vmbr0'."
  type        = string
}

# ---------------------------------------------------------------------------
# Cluster identity / VM sizing
# ---------------------------------------------------------------------------
variable "cluster_name" {
  description = "Cluster name, used to compose VM names (cp-<name>, wk0-<name>)."
  type        = string
}

variable "vm_cores" {
  description = "vCPU cores per VM."
  type        = number
  default     = 2
}

variable "vm_memory_mb" {
  description = "Memory per VM in megabytes."
  type        = number
  default     = 4096
}

variable "vm_disk_size_gb" {
  description = "Disk size per VM in gigabytes."
  type        = number
  default     = 64
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
