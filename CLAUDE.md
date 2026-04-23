# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
tofu fmt -recursive          # format all .tf files
tofu init -backend=false     # initialize without connecting to state backend
tofu validate                # syntax and reference check (no credentials needed)
tofu plan                    # preview changes (requires credentials + tfvars)
tofu apply                   # apply changes
tofu destroy                 # tear everything down
```

`terraform.tfvars` is gitignored. Copy `terraform.tfvars.example` and fill in values before running `plan`/`apply`.

## Architecture

Single flat config (no modules) targeting one Ubuntu VM on an OpenStack-based provider (Rumble Cloud). Auth reads from `~/.config/openstack/clouds.yaml` — see README for the required structure.

**Resource graph:**

```
tls_private_key.tf
  └─ openstack_compute_keypair_v2.tf   (public key registered with OpenStack)
  └─ local_sensitive_file.tf_private_key  (private key → .ssh/tf-managed-key)

openstack_networking_secgroup_v2.web
  └─ openstack_networking_secgroup_rule_v2.{ssh,http,https}

data.openstack_images_image_v2.ubuntu
  └─ openstack_blockstorage_volume_v3.boot  (20 GiB root volume)
        └─ openstack_compute_instance_v2.web  (block_device boot)

data.openstack_networking_network_v2.internal
  └─ openstack_networking_port_v2.web   (carries security group)
        └─ openstack_compute_instance_v2.web  (network { port = ... })
        └─ openstack_networking_floatingip_associate_v2.web

openstack_networking_floatingip_v2.web
  └─ openstack_networking_floatingip_associate_v2.web
```

Security groups are attached to `openstack_networking_port_v2.web`, not directly to the instance — this is why `openstack_compute_instance_v2.web` has no `security_groups` argument.

The instance boots from `openstack_blockstorage_volume_v3.boot` (created from the image). `delete_on_termination = false` means the volume survives if the instance is deleted outside of Terraform.

**cloud-init (`cloud-init.yaml.tftpl`):** Templated with `user_pubkey`. Appends the user's personal pubkey to `ubuntu`'s `authorized_keys`, then installs nginx and Docker (from the official Docker apt repo). The TF-managed keypair is separately injected by OpenStack via the `key_pair` argument.

**State:** Local (`terraform.tfstate`) — no backend block. To migrate to remote state, add a `backend` block to `versions.tf` and run `tofu init -migrate-state`.

## Adding security group rules

Add more `openstack_networking_secgroup_rule_v2` blocks in `main.tf`. For Rustdesk self-hosted: TCP 21115–21119, UDP 21116.

## Provider compatibility

`versions.tf` uses a `terraform {}` block (not `tofu {}`), which is valid in both Terraform ≥1.6 and OpenTofu. Do not change this.
