output "vm_name" {
  description = "Foundation runner VM."
  value       = azapi_resource.vm["foundation"].name
}

output "runner_vm_names" {
  value = { for k, vm in azapi_resource.vm : k => vm.name }
}

output "vm_id" {
  value = azapi_resource.vm["foundation"].id
}

output "state_private_endpoint_id" {
  value = azapi_resource.state_pe.id
}
