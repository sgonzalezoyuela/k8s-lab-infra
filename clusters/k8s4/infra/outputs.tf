output "vm_ids" {
  description = "Proxmox VM ids, keyed by node role."
  value       = module.cluster.vm_ids
}

output "vm_ips" {
  description = "Configured IPv4 addresses, keyed by node role."
  value       = module.cluster.vm_ips
}
