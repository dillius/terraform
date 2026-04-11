output "instance_id" {
  description = "OpenStack instance ID."
  value       = openstack_compute_instance_v2.web.id
}

output "instance_name" {
  description = "Instance name."
  value       = openstack_compute_instance_v2.web.name
}

output "floating_ip" {
  description = "Public floating IP address."
  value       = openstack_networking_floatingip_v2.web.address
}

output "ssh_command_tf_key" {
  description = "SSH into the instance using the Terraform-managed key."
  value       = "ssh -i ${local_sensitive_file.tf_private_key.filename} ubuntu@${openstack_networking_floatingip_v2.web.address}"
}
