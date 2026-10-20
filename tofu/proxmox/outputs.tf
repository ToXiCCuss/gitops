output "vm_ip_addresses" {
  description = "IP address per VM, to be copied into the Ansible host configuration."
  value       = { for name, vm in module.vm : name => vm.ip_address }
}
