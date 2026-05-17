locals {
  # Per-domain zone_id wins; falls back to the global cloudflare_zone_id.
  # Domains where neither is set are silently skipped.
  cf_dns_records = {
    for d in var.proxy_domains :
    d.domain => d.cf_zone_id != "" ? d.cf_zone_id : var.cloudflare_zone_id
    if d.cf_zone_id != "" || var.cloudflare_zone_id != ""
  }
}

resource "cloudflare_record" "web" {
  for_each = local.cf_dns_records

  zone_id = each.value
  name    = each.key
  type    = "A"
  content = openstack_networking_port_v2.web.all_fixed_ips[0]
  proxied = var.cloudflare_proxied
  ttl     = var.cloudflare_proxied ? 1 : 300
}
