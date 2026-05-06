# Two VMs: control-plane (cp) and worker-0 (wk0).
#
# Both boot from the Talos NoCloud ISO mounted as a CDROM on first boot, then
# from the SCSI disk after Talos has installed itself. Proxmox cloud-init is
# used only as a NoCloud datasource: Talos reads the machine config from
# user-data and the static IP settings from network data. Talos does not run
# generic Linux cloud-init inside the guest.
#
# Sizing differs per role:
#   - cp:  smaller (control-plane workload only)
#   - wk0: larger, with a second disk dedicated to Longhorn storage (scsi1 →
#          /dev/sdb inside the guest). The OS install lands on /dev/sda and
#          ignores the second disk.

resource "proxmox_virtual_environment_file" "cp_talos_user_data" {
  node_name    = var.proxmox_node
  datastore_id = var.proxmox_snippet_storage
  content_type = "snippets"
  overwrite    = true

  source_file {
    path      = var.cp_talos_config_path
    file_name = "talos-${var.cluster_name}-cp.yaml"
  }
}

resource "proxmox_virtual_environment_file" "wk0_talos_user_data" {
  node_name    = var.proxmox_node
  datastore_id = var.proxmox_snippet_storage
  content_type = "snippets"
  overwrite    = true

  source_file {
    path      = var.wk0_talos_config_path
    file_name = "talos-${var.cluster_name}-wk0.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "cp" {
  name      = "cp-${var.cluster_name}"
  node_name = var.proxmox_node
  tags      = ["talos", "k8s", var.cluster_name, "cp"]

  on_boot = true
  started = true

  cpu {
    cores = var.cp_cores
    type  = "host"
  }

  memory {
    dedicated = var.cp_memory_mb
  }

  # OS disk (scsi0). Talos installs to /dev/sda.
  disk {
    datastore_id = var.proxmox_storage_pool
    interface    = "scsi0"
    size         = var.cp_disk_size_gb
    file_format  = "raw"
  }

  cdrom {
    enabled   = true
    interface = "ide3"
    file_id   = var.talos_iso_file_id
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id      = var.proxmox_storage_pool
    interface         = "ide2"
    type              = "nocloud"
    user_data_file_id = proxmox_virtual_environment_file.cp_talos_user_data.id

    dns {
      servers = [var.network_dns]
    }

    ip_config {
      ipv4 {
        address = "${var.cp_ip}/${var.network_cidr}"
        gateway = var.network_gateway
      }
    }
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  # Boot from CDROM (Talos installer ISO) first, then from the installed disk.
  boot_order = ["ide3", "scsi0"]
}

resource "proxmox_virtual_environment_vm" "wk0" {
  name      = "wk0-${var.cluster_name}"
  node_name = var.proxmox_node
  tags      = ["talos", "k8s", var.cluster_name, "worker"]

  on_boot = true
  started = true

  cpu {
    cores = var.wk_cores
    type  = "host"
  }

  memory {
    dedicated = var.wk_memory_mb
  }

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

  cdrom {
    enabled   = true
    interface = "ide3"
    file_id   = var.talos_iso_file_id
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id      = var.proxmox_storage_pool
    interface         = "ide2"
    type              = "nocloud"
    user_data_file_id = proxmox_virtual_environment_file.wk0_talos_user_data.id

    dns {
      servers = [var.network_dns]
    }

    ip_config {
      ipv4 {
        address = "${var.wk0_ip}/${var.network_cidr}"
        gateway = var.network_gateway
      }
    }
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  boot_order = ["ide3", "scsi0"]
}
