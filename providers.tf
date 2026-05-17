provider "openstack" {
  cloud = var.openstack_cloud
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
