resource "tls_private_key" "tf" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "tf_private_key" {
  content         = tls_private_key.tf.private_key_openssh
  filename        = "${path.module}/.ssh/tf-managed-key"
  file_permission = "0600"
}

resource "openstack_compute_keypair_v2" "tf" {
  name       = "${var.instance_name}-tf"
  public_key = tls_private_key.tf.public_key_openssh
}

resource "openstack_networking_secgroup_v2" "web" {
  name        = "${var.instance_name}-sg"
  description = "Security group for ${var.instance_name}"
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  for_each          = toset(var.allowed_ssh_cidrs)
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.web.id
}

resource "openstack_networking_secgroup_rule_v2" "http" {
  for_each          = toset(var.allowed_web_cidrs)
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.web.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  for_each          = toset(var.allowed_web_cidrs)
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.web.id
}

data "openstack_images_image_v2" "ubuntu" {
  name = var.image_name
}

data "openstack_networking_network_v2" "web" {
  name = var.network_name
}

resource "openstack_blockstorage_volume_v3" "boot" {
  name     = "${var.instance_name}-boot"
  size     = var.volume_size
  image_id = data.openstack_images_image_v2.ubuntu.id
}

resource "openstack_networking_port_v2" "web" {
  name               = "${var.instance_name}-port"
  network_id         = data.openstack_networking_network_v2.web.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.web.id]
}

locals {
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    user_pubkey     = trimspace(file(pathexpand(var.ssh_pubkey_path)))
    proxy_domains   = var.proxy_domains
    certbot_email   = var.certbot_email
    install_nginx   = var.install_nginx
    github_username = var.github_username
    github_token    = var.github_token
  })
}

resource "openstack_compute_instance_v2" "web" {
  name        = var.instance_name
  flavor_name = var.flavor_name
  key_pair    = openstack_compute_keypair_v2.tf.name
  user_data   = local.cloud_init

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.boot.id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = false
  }

  network {
    port = openstack_networking_port_v2.web.id
  }
}

