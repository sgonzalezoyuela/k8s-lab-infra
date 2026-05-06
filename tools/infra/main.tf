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
#
# IMPORTANT — snippet placement:
#   The Proxmox API does not support uploading `snippets` content; the bpg
#   provider can only do it over SSH+SCP. We deliberately avoid that and
#   instead reference the snippet volume id directly. The operator must copy
#   _out/cp.yaml and _out/wk0.yaml onto the Proxmox host's snippet storage
#   (typically /var/lib/vz/snippets/) before running `tofu apply`.
#   `talos/scripts/print-snippet-upload-cmd.sh` (also chained from
#   render-tfvars.sh) prints the exact scp commands required.

locals {
  # Snippet volume ids that Proxmox expects, format: <storage>:snippets/<file>.
  # The files behind these ids are NOT uploaded by OpenTofu — they must be
  # placed manually on the Proxmox host (see file header above).
  cp_user_data_file_id  = "${var.proxmox_snippet_storage}:snippets/talos-${var.cluster_name}-cp.yaml"
  wk0_user_data_file_id = "${var.proxmox_snippet_storage}:snippets/talos-${var.cluster_name}-wk0.yaml"
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
    interface = "ide3"
    file_id   = var.talos_iso_file_id
  }

  network_device {
    bridge = var.network_bridge
  }

  # IMPORTANT — DO NOT add `ip_config { }` or `dns { }` here.
  # Those blocks would make Proxmox emit a cloud-init network-config file in
  # the NoCloud datasource, which competes with the network config that lives
  # inside the Talos machine config (user-data). When the gateway is off-link
  # from the node prefix (e.g. 10.4.0.1/24 with gateway 10.0.0.1), the
  # cloud-init network-config tries to install the gateway, fails, and
  # prevents Talos from applying its own user-data routes — symptom: IP and
  # DNS work but the default route is missing.
  # We keep the cloud-init drive carrying ONLY the user-data file (Talos
  # machine config). Talos reads it and configures the link, addresses,
  # routes, and nameservers itself per `machine.network` in the snippet.
  initialization {
    datastore_id      = var.proxmox_storage_pool
    interface         = "ide2"
    type              = "nocloud"
    user_data_file_id = local.cp_user_data_file_id
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
    interface = "ide3"
    file_id   = var.talos_iso_file_id
  }

  network_device {
    bridge = var.network_bridge
  }

  # See cp's initialization block for the rationale: networking lives in the
  # Talos machine config (user-data), NOT in cloud-init network-config.
  initialization {
    datastore_id      = var.proxmox_storage_pool
    interface         = "ide2"
    type              = "nocloud"
    user_data_file_id = local.wk0_user_data_file_id
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  boot_order = ["ide3", "scsi0"]
}
