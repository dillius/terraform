variable "openstack_cloud" {
  description = "Name of the cloud entry in ~/.config/openstack/clouds.yaml to use for auth."
  type        = string
  default     = "rumble"
}

variable "instance_name" {
  description = "Name for the compute instance and prefix for related resources."
  type        = string
  default     = "web-host"
}

variable "image_name" {
  description = "Name of the OpenStack image to boot from. Ubuntu 24.04 LTS recommended; cloud-init assumes a Debian/Ubuntu base."
  type        = string
}

variable "flavor_name" {
  description = "Name of the OpenStack flavor (instance size)."
  type        = string
}

variable "network_name" {
  description = "Name of the internal OpenStack network to attach the instance to."
  type        = string
}

variable "external_network_name" {
  description = "Name of the external network used as the floating IP pool."
  type        = string
}

variable "ssh_pubkey_path" {
  description = "Path to your personal SSH public key. Installed on the instance alongside the Terraform-managed key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks permitted to SSH (port 22) to the instance."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_web_cidrs" {
  description = "CIDR blocks permitted to reach HTTP (80) and HTTPS (443) on the instance."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "volume_size" {
  description = "Size of the root block storage volume in GiB."
  type        = number
  default     = 20
}

variable "proxy_domains" {
  description = "Reverse-proxy virtual hosts to configure in nginx. Each entry requires a domain name and a backend upstream URL (e.g. http://127.0.0.1:3000). Certificates are issued separately via setup-ssl after DNS propagation."
  type = list(object({
    domain   = string
    upstream = string
  }))
  default = []
}

variable "certbot_email" {
  description = "Email address for Let's Encrypt certificate registration. Required when proxy_domains is non-empty."
  type        = string
  default     = ""
}
