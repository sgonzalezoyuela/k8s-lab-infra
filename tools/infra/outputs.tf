output "vm_ids" {
  description = "Proxmox VM ids, keyed by node role."
  value = {
    cp  = proxmox_virtual_environment_vm.cp.vm_id
    wk0 = proxmox_virtual_environment_vm.wk0.vm_id
  }
}

output "vm_ips" {
  description = "Configured IPv4 addresses, keyed by node role. Source of truth is .env (Talos applies them at machine-config time)."
  value = {
    cp  = var.cp_ip
    wk0 = var.wk0_ip
  }
}
