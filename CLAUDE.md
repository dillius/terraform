# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) and other agents
when working with code in this repository. Prefer preserving thorough README
explanations when editing docs — this repo is used for learning, not only ops.

## Commands

```sh
tofu fmt -recursive          # format all .tf files
tofu init -backend=false     # initialize without connecting to state backend
tofu validate                # syntax and reference check (no credentials needed)
tofu plan                    # preview changes (requires credentials + tfvars)
tofu apply                   # apply cloud resources + host_config deploy when triggers change
tofu destroy                 # tear everything down

# Force re-deploy of the docker stack without changing files:
tofu apply -replace=null_resource.host_config

# Deliberately rebuild the compute instance (re-runs cloud-init bootstrap):
tofu apply -replace=openstack_compute_instance_v2.web
```

`terraform.tfvars` is gitignored. Copy `terraform.tfvars.example` and fill in
values before running `plan`/`apply`. Required secrets (no defaults):
`postgres_password`, `grafana_admin_password`, `ntfy_topic`.

## Architecture

Single flat config (no modules) targeting one Ubuntu VM on an OpenStack-based
provider (Rumble Cloud). Auth reads from `~/.config/openstack/clouds.yaml` —
see README for the required structure.

### Two-layer configuration model

| Layer | File(s) | Lifecycle |
|-------|---------|-----------|
| Cloud resources | `main.tf`, `dns.tf`, `providers.tf` | Desired state on every apply |
| First-boot OS | `cloud-init.yaml.tftpl` via `user_data` | Once; then `ignore_changes = [user_data]` |
| Day-2 host stack | `host.tf` → `null_resource.host_config` | Re-runs when docker tree / secrets / `host_deploy_revision` / instance id change |

Do **not** put iterating app config only in cloud-init — it will not update on
apply. Put it under `docker/` (or extend `host.tf` provisioners).

### Resource graph

```
tls_private_key.tf
  └─ openstack_compute_keypair_v2.tf   (public key registered with OpenStack)
  └─ local_sensitive_file.tf_private_key  (private key → .ssh/tf-managed-key)
  └─ null_resource.host_config         (SSH with this key)

openstack_networking_secgroup_v2.web
  └─ openstack_networking_secgroup_rule_v2.{ssh,http,https,npm_admin}

data.openstack_images_image_v2.ubuntu  (name + most_recent = true)
  └─ openstack_blockstorage_volume_v3.boot  (root volume; image_id ignored after create)
        └─ openstack_compute_instance_v2.web  (block_device boot)

data.openstack_networking_network_v2.web   (var.network_name — e.g. PublicEphemeral)
  └─ openstack_networking_port_v2.web   (carries security group)
        └─ openstack_compute_instance_v2.web  (network { port = ... })
        └─ cloudflare_record.web              (optional; A → all_fixed_ips[0])
        └─ null_resource.host_config          (SSH deploy)

null_resource.host_config
  → uploads docker/ to /home/ubuntu/scripts/infra
  → writes .env + rendered contactpoints.yaml
  → docker compose pull && up -d
```

### Networking

The instance attaches **directly to `PublicEphemeral`** (a shared provider
network on Rumble: `router:external = false`, `shared = true`, DHCP-enabled,
subnet `207.5.194.0/23`). The port gets a routable public IP via DHCP. The
address is exposed as the `public_ip` output, derived from
`openstack_networking_port_v2.web.all_fixed_ips[0]`. Address may change if the
port is recreated.

**Rumble's two public networks:**
- `PublicEphemeral` — shared, directly attachable by tenant VMs. Used here.
- `PublicStatic` — external floating-IP pool (`router:external = true`, owned
  by a Rumble admin project, `shared = false`). Tenants cannot create ports on
  it directly; access is only via floating IPs through a router with external
  gateway. That pattern needs 2 slots of the default `public_ip = 1` quota
  (router gateway + floating IP), so it requires a quota raise.

To switch to the `PublicStatic` + floating-IP pattern: set `network_name` to
the *private* network, add `openstack_networking_router_v2` with
`external_network_id` pointing at `PublicStatic`, add
`openstack_networking_router_interface_v2` attaching the private subnet, and
re-add `openstack_networking_floatingip_v2` + `floatingip_associate_v2`.

Security groups are attached to `openstack_networking_port_v2.web`, not
directly to the instance — this is why `openstack_compute_instance_v2.web` has
no `security_groups` argument.

### Boot volume

The instance boots from `openstack_blockstorage_volume_v3.boot` (created from
the image). `delete_on_termination = false` means the volume survives if the
instance is deleted outside of Terraform. `lifecycle.ignore_changes = [image_id]`
avoids recreating the volume when the cloud publishes a newer image with the
same name.

### cloud-init (`cloud-init.yaml.tftpl`)

Bootstrap only: personal pubkey → `authorized_keys`, Docker engine from the
official apt repo, SSH hardening, fail2ban, unattended-upgrades, 2G swap, UFW,
optional apt nginx/certbot when `install_nginx = true`. The TF-managed keypair
is injected separately by OpenStack via `key_pair`. **Does not** deploy compose
or embed GitHub tokens.

### host_config (`host.tf`)

Idempotent-enough day-2 path: file/hash triggers, SSH provisioners, full
`docker/` sync, secrets via `.env`, ntfy topic via templatefile of
`contactpoints.yaml.tftpl`. Preconditions enforce password length and ntfy
topic not left as the placeholder.

### State

Local (`terraform.tfstate`) — no backend block. Contains private key material
and host secrets. To migrate to remote state, add a `backend` block to
`versions.tf` and run `tofu init -migrate-state`.

## Adding security group rules

Add more `openstack_networking_secgroup_rule_v2` blocks in `main.tf`. For
Rustdesk self-hosted: TCP 21115–21119, UDP 21116.

## Documentation

When changing architecture or operator workflow, update **README.md** with the
same level of detail (why + how + examples). Do not collapse long sections into
short tables only — this repository is used for learning.

## Provider compatibility

`versions.tf` uses a `terraform {}` block (not `tofu {}`), which is valid in
both Terraform ≥1.6 and OpenTofu. Do not change this.
