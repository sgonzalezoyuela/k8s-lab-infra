# __CLUSTER_NAME__ cluster wrapper for the shared OpenTofu module under
# tools/infra. This file declares the Proxmox provider and forwards every
# input variable to the module. State for this cluster lives in this
# directory's terraform.tfstate; resource addresses are namespaced under
# module.cluster.* (state mv that on first apply if migrating from an old
# layout).

terraform {
  required_version = ">= 1.6"
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

module "cluster" {
  source = "../../../tools/infra"

  proxmox_endpoint         = var.proxmox_endpoint
  proxmox_api_token_id     = var.proxmox_api_token_id
  proxmox_api_token_secret = var.proxmox_api_token_secret
  proxmox_insecure         = var.proxmox_insecure
  proxmox_node             = var.proxmox_node
  proxmox_storage_pool     = var.proxmox_storage_pool
  proxmox_snippet_storage  = var.proxmox_snippet_storage
  talos_iso_file_id        = var.talos_iso_file_id
  network_bridge           = var.network_bridge
  cluster_name             = var.cluster_name
  cp_cores                 = var.cp_cores
  cp_memory_mb             = var.cp_memory_mb
  cp_disk_size_gb          = var.cp_disk_size_gb
  wk_cores                 = var.wk_cores
  wk_memory_mb             = var.wk_memory_mb
  wk_disk_size_gb          = var.wk_disk_size_gb
  wk_storage_disk_size_gb  = var.wk_storage_disk_size_gb
  cp_hostname              = var.cp_hostname
  cp_ip                    = var.cp_ip
  wk0_hostname             = var.wk0_hostname
  wk0_ip                   = var.wk0_ip
}
