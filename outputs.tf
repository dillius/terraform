output "instance_id" {
  description = "OpenStack instance ID."
  value       = openstack_compute_instance_v2.web.id
}

output "instance_name" {
  description = "Instance name."
  value       = openstack_compute_instance_v2.web.name
}

output "public_ip" {
  description = "Public IP from DHCP on the attached network (PublicEphemeral). May change if the port is recreated."
  value       = openstack_networking_port_v2.web.all_fixed_ips[0]
}

output "ssh_command_tf_key" {
  description = "SSH into the instance using the Terraform-managed key."
  value       = "ssh -i ${local_sensitive_file.tf_private_key.filename} ubuntu@${openstack_networking_port_v2.web.all_fixed_ips[0]}"
}

output "infra_compose_dir" {
  description = "Remote path where null_resource.host_config deploys the docker stack."
  value       = local.infra_remote_dir
}

output "host_config_id" {
  description = "ID of the host_config null_resource. Replace to force redeploy: tofu apply -replace=null_resource.host_config"
  value       = null_resource.host_config.id
}
