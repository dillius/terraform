# Summary: host_config refactor and review fixes

**Date:** 2026-08-01

## Overall changes

### Architecture (the big shift)

Previously, cloud-init tried to own both first boot **and** the Docker stack. That doesn’t work well for day-2 changes (OpenStack often replaces the VM when `user_data` changes), so the code had `ignore_changes` on `user_data` — which meant compose/config updates never applied.

**Now there are two layers, both driven by `tofu apply`:**

| Layer | What | When |
|--------|------|------|
| **Cloud** (`main.tf`, `dns.tf`) | VM, volume, port, SG, DNS, keypair | Every apply |
| **Bootstrap** (`cloud-init.yaml.tftpl`) | Docker engine, SSH harden, fail2ban, swap, UFW, optional apt nginx | **First boot only** (`ignore_changes` kept) |
| **Day-2 host** (`host.tf` → `null_resource.host_config`) | Full `docker/` tree, `.env`, ntfy contact point, `compose up`, optional GHCR login | When `docker/**`, secrets, or `host_deploy_revision` change |

Force redeploy:

```sh
tofu apply -replace=null_resource.host_config
```

### Fixes from the review

- **Compose deploy** — whole `docker/` tree (compose + otelcol + grafana provisioning), not only `docker-compose.yml`
- **Secrets** — required `postgres_password`, `grafana_admin_password`, `ntfy_topic` (not CHANGE-ME in git)
- **No secrets in cloud-init** — GHCR login moved to host deploy
- **Image safety** — `most_recent = true`; boot volume ignores `image_id` after create
- **Compose hygiene** — pinned image tags; Watchtower only updates labeled services (Postgres unlabeled); NPM no longer falsely depends on Postgres
- **Example flavor** — `s1a.medium` (~4 GiB) to match mem limits
- **Docs** — full learning-oriented README/CLAUDE restored and aligned with the new model
- **CI** — OpenTofu 1.9.x; watches `docker/**`; null provider in lockfile

### What did *not* change

- Still one flat OpenStack VM on PublicEphemeral
- Still local state (gitignored)
- Still optional Cloudflare DNS via `proxy_domains`
- Still NPM as default reverse proxy (`install_nginx = false`)

---

## Next steps

1. **Add required secrets to `terraform.tfvars`**

   ```hcl
   postgres_password      = "…"   # ≥ 12 chars
   grafana_admin_password = "…"   # ≥ 12 chars
   ntfy_topic             = "…"   # long random string
   ```

2. **Recommended hardening**

   ```hcl
   allowed_ssh_cidrs   = ["YOUR.PUBLIC.IP/32"]
   allowed_admin_cidrs = ["YOUR.PUBLIC.IP/32"]
   ```

   Confirm `flavor_name = "s1a.medium"` (or equivalent ~4 GiB) if you’re still on small.

3. **Apply**

   ```sh
   tofu plan    # expect null_resource.host_config create (+ any other drift)
   tofu apply   # waits for Docker, deploys stack over SSH (can take several minutes)
   ```

4. **After apply**

   - SSH: `tofu output ssh_command_tf_key`
   - Stack: `/home/ubuntu/scripts/infra` → `sudo docker compose ps`
   - NPM: `http://<public-ip>:81` — change default `admin@example.com` / `changeme`
   - Subscribe to your ntfy topic; log into Grafana via NPM (`lgtm:3000`) with the Grafana password from tfvars
   - Import dashboards 1860 / 19908 if you want host/container graphs

5. **Ongoing workflow**

   - Edit `docker/` or secrets → `tofu apply`
   - Force host redeploy without file changes → `-replace=null_resource.host_config`
   - Cloud-init-only changes need a deliberate instance replace (or manual SSH)

6. **Optional later**

   - Remote/encrypted state (state holds SSH key + passwords)
   - Commit the local changes when you’re happy (`host.tf`, docs, compose, etc.)

---

*A full apply against the live host was not run as part of this work — it needs the new tfvars values and network access from your machine.*
