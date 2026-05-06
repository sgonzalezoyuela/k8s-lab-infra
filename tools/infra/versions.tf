# Module-level provider requirements. The actual `provider "proxmox" {}`
# block lives in the consuming cluster wrapper (e.g. clusters/<name>/infra/main.tf),
# so the module is reusable without baking in auth.

terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}
