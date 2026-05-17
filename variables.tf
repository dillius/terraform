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
  description = "Name of the OpenStack network to attach the instance to. For a single-VM setup on Rumble, set this to the external/public network so the instance gets a routable IP directly via DHCP — no router or floating IP needed."
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

variable "allowed_admin_cidrs" {
  description = "CIDR blocks permitted to reach the NPM admin UI (port 81). Restrict to your IP once the proxy is configured."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "volume_size" {
  description = "Size of the root block storage volume in GiB."
  type        = number
  default     = 20
}

variable "proxy_domains" {
  description = "Reverse-proxy virtual hosts to configure in nginx. Each entry requires a domain name and a backend upstream URL (e.g. http://127.0.0.1:3000). Certificates are issued separately via setup-ssl after DNS propagation. Set cf_zone_id to override the global cloudflare_zone_id for domains in a different Cloudflare zone."
  type = list(object({
    domain     = string
    upstream   = string
    cf_zone_id = optional(string, "")
  }))
  default = []
}

variable "certbot_email" {
  description = "Email address for Let's Encrypt certificate registration. Required when proxy_domains is non-empty."
  type        = string
  default     = ""
}

variable "github_username" {
  description = "GitHub username for authenticating to GHCR (ghcr.io). Set alongside github_token to enable docker login on the instance."
  type        = string
  default     = ""
}

variable "install_nginx" {
  description = "Install nginx and certbot from apt. Set to false when using Nginx Proxy Manager (or another reverse proxy) in Docker."
  type        = bool
  default     = false
}

variable "github_token" {
  description = "GitHub Personal Access Token with read:packages scope. Used to docker login to ghcr.io on the instance. Stored in Terraform state — use a fine-grained token scoped to packages only."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit permission. Create at dash.cloudflare.com/profile/api-tokens. Must be set alongside cloudflare_zone_id."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the domain. Found in the right-hand panel on your zone's Overview page. When empty, no DNS records are created."
  type        = string
  default     = ""
}

variable "cloudflare_proxied" {
  description = "Whether Cloudflare should proxy traffic (orange cloud). false = DNS-only A record. Keep false for initial certbot HTTP-01 certificate issuance; flip to true afterwards if desired."
  type        = bool
  default     = false
}
