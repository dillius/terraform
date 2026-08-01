# Day-2 host configuration. Re-runs when docker/** (or related secrets/config)
# change, without replacing the OpenStack instance.
#
# Force a redeploy without file changes:
#   tofu apply -replace=null_resource.host_config

locals {
  infra_remote_dir = "/home/ubuntu/scripts/infra"

  docker_files = fileset("${path.module}/docker", "**")

  docker_tree_hash = sha256(join("", [
    for f in sort(local.docker_files) :
    filesha256("${path.module}/docker/${f}")
  ]))

  # Hash secrets so password/topic rotations re-trigger deploy without putting
  # plaintext into the trigger map (plan still shows the hash changed).
  host_secrets_hash = sha256(join("|", [
    var.postgres_password,
    var.grafana_admin_password,
    var.ntfy_topic,
    var.github_username,
    var.github_token,
  ]))

  docker_env = <<-EOT
    POSTGRES_USER=${var.postgres_user}
    POSTGRES_PASSWORD=${var.postgres_password}
    POSTGRES_DB=${var.postgres_db}
    GF_SECURITY_ADMIN_USER=${var.grafana_admin_user}
    GF_SECURITY_ADMIN_PASSWORD=${var.grafana_admin_password}
  EOT

  contactpoints_yaml = templatefile(
    "${path.module}/docker/grafana-provisioning/alerting/contactpoints.yaml.tftpl",
    { ntfy_topic = var.ntfy_topic }
  )
}

resource "null_resource" "host_config" {
  triggers = {
    docker_tree     = local.docker_tree_hash
    secrets         = local.host_secrets_hash
    deploy_revision = var.host_deploy_revision
    instance_id     = openstack_compute_instance_v2.web.id
  }

  connection {
    type        = "ssh"
    host        = openstack_networking_port_v2.web.all_fixed_ips[0]
    user        = "ubuntu"
    private_key = tls_private_key.tf.private_key_openssh
    timeout     = "25m"
  }

  # Wait for cloud-init (Docker install) before uploading the stack.
  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "echo 'Waiting for cloud-init to finish...'",
      "cloud-init status --wait || true",
      "echo 'Waiting for Docker...'",
      "for i in $(seq 1 60); do sudo docker info >/dev/null 2>&1 && break; sleep 5; done",
      "sudo docker info >/dev/null",
      "mkdir -p ${local.infra_remote_dir}",
    ]
  }

  # Sync the full docker/ tree (compose, otelcol, grafana provisioning, etc.).
  provisioner "file" {
    source      = "${path.module}/docker/"
    destination = local.infra_remote_dir
  }

  # Secrets and rendered alerting contact point (not committed with real values).
  provisioner "file" {
    content     = local.docker_env
    destination = "${local.infra_remote_dir}/.env"
  }

  provisioner "file" {
    content     = local.contactpoints_yaml
    destination = "${local.infra_remote_dir}/grafana-provisioning/alerting/contactpoints.yaml"
  }

  # GHCR credentials (if set) are written to a mode-600 file and consumed via
  # --password-stdin so the token is not placed on the process argv list.
  provisioner "file" {
    content     = var.github_username != "" && var.github_token != "" ? var.github_token : ""
    destination = "/tmp/.ghcr_token"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",
      "sudo chown -R ubuntu:ubuntu /home/ubuntu/scripts",
      "chmod 600 ${local.infra_remote_dir}/.env",
      # Drop the template source on the host if it was uploaded with the tree.
      "rm -f ${local.infra_remote_dir}/grafana-provisioning/alerting/contactpoints.yaml.tftpl",
      "if [ -s /tmp/.ghcr_token ]; then",
      "  sudo docker login ghcr.io -u '${var.github_username}' --password-stdin < /tmp/.ghcr_token",
      "  sudo mkdir -p /home/ubuntu/.docker",
      "  sudo cp -r /root/.docker/. /home/ubuntu/.docker/ 2>/dev/null || true",
      "  sudo chown -R ubuntu:ubuntu /home/ubuntu/.docker",
      "fi",
      "rm -f /tmp/.ghcr_token",
      "cd ${local.infra_remote_dir}",
      "sudo docker compose pull",
      "sudo docker compose up -d --remove-orphans",
      "sudo docker compose ps",
    ]
  }

  lifecycle {
    precondition {
      condition     = length(var.postgres_password) >= 12
      error_message = "postgres_password must be at least 12 characters (set in terraform.tfvars)."
    }
    precondition {
      condition     = length(var.grafana_admin_password) >= 12
      error_message = "grafana_admin_password must be at least 12 characters (set in terraform.tfvars)."
    }
    precondition {
      condition     = var.ntfy_topic != "" && var.ntfy_topic != "CHANGE-ME-terraform-alerts"
      error_message = "ntfy_topic must be set to a hard-to-guess topic name (not the placeholder)."
    }
    precondition {
      condition     = !var.install_nginx || length(var.proxy_domains) == 0 || var.certbot_email != ""
      error_message = "certbot_email is required when install_nginx is true and proxy_domains is non-empty."
    }
  }

  depends_on = [
    openstack_compute_instance_v2.web,
    local_sensitive_file.tf_private_key,
  ]
}
