output "instance_id" {
  description = "OpenStack instance ID."
  value       = openstack_compute_instance_v2.web.id
}

output "instance_name" {
  description = "Instance name."
  value       = openstack_compute_instance_v2.web.name
}

output "public_ip" {
  description = "Public IP address assigned to the instance via DHCP on the attached network."
  value       = openstack_networking_port_v2.web.all_fixed_ips[0]
}

output "ssh_command_tf_key" {
  description = "SSH into the instance using the Terraform-managed key."
  value       = "ssh -i ${local_sensitive_file.tf_private_key.filename} ubuntu@${openstack_networking_port_v2.web.all_fixed_ips[0]}"
}
