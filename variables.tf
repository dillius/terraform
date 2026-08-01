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
  description = "Name of the OpenStack image to boot from. Ubuntu 24.04 LTS recommended; cloud-init assumes a Debian/Ubuntu base. The newest matching image is selected (most_recent)."
  type        = string
}

variable "flavor_name" {
  description = "Name of the OpenStack flavor (instance size). The docker/ mem_limits are sized for ~4 GiB RAM (e.g. s1a.medium on Rumble)."
  type        = string
}

variable "network_name" {
  description = "Name of the OpenStack network to attach the instance to. For a single-VM setup on Rumble, use PublicEphemeral so the instance gets a routable IP via DHCP — no router or floating IP needed. Address may change if the port is recreated."
  type        = string
}

variable "ssh_pubkey_path" {
  description = "Path to your personal SSH public key. Installed on the instance alongside the Terraform-managed key."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks permitted to SSH (port 22) to the instance. Prefer your /32 over 0.0.0.0/0 once you have a stable IP."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_web_cidrs" {
  description = "CIDR blocks permitted to reach HTTP (80) and HTTPS (443) on the instance."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_admin_cidrs" {
  description = "CIDR blocks permitted to reach the NPM admin UI (port 81). Restrict to your IP after initial setup — this is the real lock (UFW still allows 81 from anywhere)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "volume_size" {
  description = "Size of the root block storage volume in GiB."
  type        = number
  default     = 40
}

variable "proxy_domains" {
  description = <<-EOT
    Domains associated with this host. Used for:
      - Cloudflare A records (when zone IDs are set), always
      - apt nginx vhosts + setup-ssl, only when install_nginx = true

    With the default NPM path (install_nginx = false), upstream is unused —
    configure reverse-proxy routes in the NPM UI (or its API). Set cf_zone_id
    to override the global cloudflare_zone_id for a domain in another zone.
  EOT
  type = list(object({
    domain     = string
    upstream   = string
    cf_zone_id = optional(string, "")
  }))
  default = []
}

variable "certbot_email" {
  description = "Email for Let's Encrypt when install_nginx is true. Required if install_nginx and proxy_domains are both set."
  type        = string
  default     = ""
}

variable "install_nginx" {
  description = "Install nginx + certbot from apt on first boot. Default false — use Nginx Proxy Manager in Docker instead."
  type        = bool
  default     = false
}

variable "github_username" {
  description = "GitHub username for GHCR (ghcr.io). Set with github_token to docker login during host_config deploy."
  type        = string
  default     = ""
}

variable "github_token" {
  description = "GitHub PAT with read:packages. Used only by null_resource.host_config (not cloud-init). Stored in Terraform state — prefer a fine-grained packages-only token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "postgres_user" {
  description = "Postgres superuser name for the infra compose stack."
  type        = string
  default     = "postgres"
}

variable "postgres_db" {
  description = "Default database created for the infra compose Postgres service."
  type        = string
  default     = "postgres"
}

variable "postgres_password" {
  description = "Postgres password written to the host .env on deploy. Min 12 characters. Stored in Terraform state."
  type        = string
  sensitive   = true
}

variable "grafana_admin_user" {
  description = "Grafana admin username (otel-lgtm)."
  type        = string
  default     = "admin"
}

variable "grafana_admin_password" {
  description = "Grafana admin password written to the host .env on deploy. Min 12 characters. Stored in Terraform state."
  type        = string
  sensitive   = true
}

variable "ntfy_topic" {
  description = "ntfy.sh topic for Grafana alerts. Anyone who guesses the name can read/publish — use a long random string, or self-host ntfy."
  type        = string
}

variable "host_deploy_revision" {
  description = "Bump this string to force null_resource.host_config to re-run without changing docker/ files."
  type        = string
  default     = "1"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit. Create at dash.cloudflare.com/profile/api-tokens."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Default Cloudflare Zone ID. When empty (and no per-domain cf_zone_id), no DNS records are created."
  type        = string
  default     = ""
}

variable "cloudflare_proxied" {
  description = "Orange-cloud proxy. Keep false until origin certificates work; then set true and use Full (Strict) SSL mode in Cloudflare."
  type        = bool
  default     = false
}
