# Two near-identical VMs: control-plane (cp) and worker-0 (wk0). Both boot from
# the Talos ISO mounted as a CDROM on first boot, then from the SCSI disk after
# Talos has installed itself. Network/IP configuration is handled by Talos via
# `talosctl apply-config` (not Proxmox cloud-init), so no `initialization` block.

resource "proxmox_virtual_environment_vm" "cp" {
  name      = "cp-${var.cluster_name}"
  node_name = var.proxmox_node
  tags      = ["talos", "k8s", var.cluster_name, "cp"]

  on_boot = true
  started = true

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
    enabled   = true
    interface = "ide3"
    file_id   = var.talos_iso_file_id
  }

  network_device {
    bridge = var.network_bridge
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
    enabled   = true
    interface = "ide3"
    file_id   = var.talos_iso_file_id
  }

  network_device {
    bridge = var.network_bridge
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  boot_order = ["ide3", "scsi0"]
}
