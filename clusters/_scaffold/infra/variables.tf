# Wrapper variables for the __CLUSTER_NAME__ cluster. Mirrors
# tools/infra/variables.tf so `cluster.tfvars` can be applied at this layer
# and forwarded into the module.

variable "proxmox_endpoint" {
  type = string
}

variable "proxmox_api_token_id" {
  type = string
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_insecure" {
  type    = bool
  default = false
}

variable "proxmox_node" {
  type = string
}

variable "proxmox_storage_pool" {
  type = string
}

variable "proxmox_snippet_storage" {
  type = string
}

variable "talos_iso_file_id" {
  type = string
}

variable "network_bridge" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cp_cores" {
  type    = number
  default = 4
}

variable "cp_memory_mb" {
  type    = number
  default = 4096
}

variable "cp_disk_size_gb" {
  type    = number
  default = 30
}

variable "wk_cores" {
  type    = number
  default = 8
}

variable "wk_memory_mb" {
  type    = number
  default = 8192
}

variable "wk_disk_size_gb" {
  type    = number
  default = 30
}

variable "wk_storage_disk_size_gb" {
  type    = number
  default = 200
}

variable "cp_hostname" {
  type = string
}

variable "cp_ip" {
  type = string
}

variable "wk0_hostname" {
  type = string
}

variable "wk0_ip" {
  type = string
}
