# terraform

OpenTofu config for a personal web host on Rumble Cloud (OpenStack). Provisions
a single Ubuntu VM with Docker and OS hardening via cloud-init, deploys a shared
infra compose stack over SSH on every relevant apply, optionally manages
Cloudflare DNS, and uses a locked-down security group.

This repo is also a learning project: the sections below explain *why* things
are wired the way they are, not only *how* to run them.

## How configuration is applied (read this first)

OpenStack `user_data` / cloud-init is a **first-boot** mechanism. Changing it
and re-applying often forces **instance replacement** on the OpenStack provider,
which destroys the VM. That is a bad day-2 story for Docker volumes, NPM certs,
and Postgres data.

This config therefore splits into two layers that still both run under
`tofu apply`:

| Layer | Mechanism | When it runs | What belongs here |
|-------|-----------|--------------|-------------------|
| Cloud resources | Normal OpenTofu resources (`main.tf`, `dns.tf`, …) | Every apply | VM, volume, port, SG, DNS, keypair |
| OS bootstrap | cloud-init `user_data` | **First boot only** | Docker *engine*, SSH hardening, fail2ban, swap, UFW, optional apt nginx |
| Host app stack | `null_resource.host_config` in `host.tf` | When `docker/**`, secrets, or `host_deploy_revision` change | Full `docker/` tree, `.env`, ntfy contact point, `compose up`, GHCR login |

`openstack_compute_instance_v2.web` uses:

```hcl
lifecycle {
  ignore_changes = [user_data]
}
```

so editing `cloud-init.yaml.tftpl` does **not** replace the instance on apply.
That also means cloud-init changes do **not** take effect until you deliberately
rebuild the VM (see [Rebuilding bootstrap (cloud-init)](#rebuilding-bootstrap-cloud-init)).

Day-2 work (compose files, monitoring, passwords) goes through **`host.tf`**,
not cloud-init. Force a host redeploy without changing files:

```sh
tofu apply -replace=null_resource.host_config
# or bump host_deploy_revision in terraform.tfvars
```

**Why a `null_resource` instead of “pure” Terraform resources for containers?**
The Docker provider can manage individual containers, but a multi-service
compose stack (networks, bind mounts, healthchecks, Watchtower) is far more
natural as Compose. The null_resource is the bridge: Terraform still owns
*when* deploy runs (file hashes as triggers) and *how* secrets get to the host,
while Compose owns *what* runs on the box.

## Layout

```
.
├── versions.tf              # provider + tofu version constraints
├── providers.tf             # openstack + cloudflare providers
├── variables.tf             # input variables
├── main.tf                  # cloud resources + cloud-init template wiring
├── host.tf                  # null_resource.host_config (SSH deploy of docker/)
├── dns.tf                   # Cloudflare A records from proxy_domains
├── outputs.tf               # public IP, ssh command, host_config id
├── cloud-init.yaml.tftpl    # first-boot bootstrap only (not day-2 compose)
├── terraform.tfvars.example # copy to terraform.tfvars and fill in
├── .github/workflows/       # fmt + validate in CI (plan disabled, see below)
└── docker/                  # shared services — deployed by host_config
    ├── docker-compose.yml
    ├── otelcol-config.yaml           # extends grafana/otel-lgtm collector config
    └── grafana-provisioning/
        └── alerting/                 # contact point template, policy, alert rules
            ├── contactpoints.yaml.tftpl  # ntfy topic injected on deploy
            ├── policies.yaml
            └── rules.yaml
```

Flat, no modules. When you want a second host type (or a second provider),
extract a `modules/web-host/` directory and call it from `main.tf`.

## Prerequisites

Install OpenTofu:

```sh
brew install opentofu
```

## Initial setup

### 1. Get credentials from Rumble Cloud

Log into the Rumble Cloud dashboard and navigate to **API Access** (or
**Credentials**). Download the `clouds.yaml` file if offered — otherwise note
the values needed below.

### 2. Create the clouds.yaml file

```sh
mkdir -p ~/.config/openstack
```

Create `~/.config/openstack/clouds.yaml` with the values from the dashboard:

```yaml
clouds:
  rumble:
    auth:
      auth_url: https://<rumble-keystone-endpoint>/v3
      username: <username>
      password: <password>
      project_name: <project>
      project_id: <project-id>
      user_domain_name: Default
      project_domain_name: Default
    region_name: <region>
    interface: public
    identity_api_version: 3
```

The `cloud` name (`rumble`) must match `openstack_cloud` in `terraform.tfvars`.

### 3. Lock down the file

```sh
chmod 600 ~/.config/openstack/clouds.yaml
```

### 4. Configure terraform.tfvars

Look up the flavor name, image name, and network names from the **Rumble Cloud
dashboard**, then fill them in:

```sh
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
```

**Required host secrets** (written to the instance `.env` by `host_config`;
also stored in Terraform state — treat state like a secret store):

| Variable | Notes |
|----------|--------|
| `postgres_password` | ≥ 12 characters |
| `grafana_admin_password` | ≥ 12 characters |
| `ntfy_topic` | Long random string; ntfy.sh topics are readable by anyone who guesses the name |

**Recommended after bootstrap:**

```hcl
allowed_ssh_cidrs   = ["203.0.113.42/32"]   # your public IP
allowed_admin_cidrs = ["203.0.113.42/32"]   # NPM admin UI on port 81
```

Security groups enforce these CIDRs. UFW on the host still allows 22/80/443/81
from anywhere as defence-in-depth only — the **real** lock is the OpenStack
security group.

**Flavor / RAM:** compose `mem_limit`s assume ~**4 GiB** (`s1a.medium` on
Rumble). Do not use `s1a.small` without shrinking limits in
`docker/docker-compose.yml` (see [Memory management on small flavors](#memory-management-on-small-flavors)).

Alternatively, export `OS_*` env vars and remove the `cloud =` line from
`providers.tf` if you prefer not to use `clouds.yaml`.

## Usage

```sh
tofu init
tofu plan
tofu apply
```

What happens on a full apply:

1. OpenTofu creates/updates cloud resources (volume, port, instance, SG, DNS…).
2. On first boot, cloud-init installs Docker, hardens SSH, enables swap/UFW, etc.
3. `null_resource.host_config` SSHes in (using the TF-managed key), waits for
   `cloud-init status --wait` and `docker info`, uploads `docker/`, writes
   `.env` + rendered ntfy contact point, then runs
   `docker compose pull && docker compose up -d`.

First boot + package install can take several minutes; the SSH connection
timeout is set to 25m so apply does not give up early.

After apply, `tofu output` prints the public IP and a ready-to-use SSH command.
A Terraform-managed private key is written to `.ssh/tf-managed-key`
(gitignored); your personal key from `ssh_pubkey_path` is also installed on the
instance via cloud-init on first boot.

Useful outputs:

| Output | Meaning |
|--------|---------|
| `public_ip` | DHCP address on the attached network (see networking notes below) |
| `ssh_command_tf_key` | Copy-paste SSH with the TF-managed key |
| `infra_compose_dir` | Remote path: `/home/ubuntu/scripts/infra` |
| `host_config_id` | Bump/redeploy helper identity for `-replace` |

### Updating the stack later

1. Edit files under `docker/` and/or secrets in `terraform.tfvars`.
2. Run `tofu apply` — if hashes/triggers changed, `host_config` re-uploads and
   restarts compose.
3. Or force redeploy: `tofu apply -replace=null_resource.host_config`.

Bind-mounted data dirs on the host (`postgres_data`, `npm_data`, `lgtm_data`,
…) are **not** in the git tree, so re-uploading compose files does not wipe
them.

## SSH keys

Two keys end up on the instance:

1. **Terraform-managed key** — generated by `tls_private_key`, registered as an
   OpenStack keypair, private half saved to `.ssh/tf-managed-key`. Used by
   `host_config` provisioners and any automation that must SSH independently of
   your personal laptop key.
2. **Your personal key** — read from `ssh_pubkey_path` and appended to
   `ubuntu`'s `authorized_keys` via cloud-init on first boot.

Both live in Terraform state in some form (the private key resource is
sensitive-marked). Protect state files accordingly.

## Networking notes (PublicEphemeral vs floating IP)

This setup attaches the instance **directly to `PublicEphemeral`** (or whatever
you set in `network_name`): a shared, DHCP-enabled provider network. The port
gets a routable public address; `public_ip` is
`openstack_networking_port_v2.web.all_fixed_ips[0]`.

That address **can change** if the port is recreated. Cloudflare records (if
enabled) track the port IP on apply; anything you configured by hand will drift
until you update it.

Rumble also has **`PublicStatic`**: an external floating-IP pool
(`router:external = true`). Tenants cannot put ports on it directly; you need a
private network + router with external gateway + floating IP. That pattern
typically needs **2** slots of the default `public_ip = 1` quota (router
gateway + FIP), so it requires a quota raise. See
[Extending](#extending) for the resource sketch.

Security groups are attached to **`openstack_networking_port_v2.web`**, not via
the instance’s `security_groups` argument — that is the correct OpenStack
Neutron pattern for port-based SGs.

## Domain proxying & SSL

There are two reverse-proxy modes. Default is **Nginx Proxy Manager in Docker**
(`install_nginx = false`). The apt **nginx + certbot** path is optional and only
fully configured on first boot.

### Cloudflare DNS

If you're managing DNS through Cloudflare, Terraform can create the A records
automatically. Add your API token to `terraform.tfvars`:

```hcl
cloudflare_api_token = "..."   # Zone:DNS:Edit token — dash.cloudflare.com/profile/api-tokens
```

**Single zone** (all your domains live in one Cloudflare zone) — set the global
default and every `proxy_domains` entry uses it:

```hcl
cloudflare_zone_id = "abc123..."   # zone Overview page, right-hand panel
proxy_domains = [
  { domain = "example.com",     upstream = "http://127.0.0.1:3000" },
  { domain = "api.example.com", upstream = "http://127.0.0.1:8080" },
]
```

**Multiple zones** — set `cf_zone_id` per entry instead (overrides the global
default for that domain):

```hcl
proxy_domains = [
  { domain = "example.com",    upstream = "http://127.0.0.1:3000", cf_zone_id = "abc123..." },
  { domain = "other-site.com", upstream = "http://127.0.0.1:8080", cf_zone_id = "def456..." },
]
```

You can mix both: set `cloudflare_zone_id` as the default for most domains and
only specify `cf_zone_id` on entries that belong to a different zone.

With the default **NPM** path, `upstream` in `proxy_domains` is **unused** for
routing — it is only meaningful when `install_nginx = true`. You still use
`proxy_domains` so Terraform can create the A records; configure the actual
proxy hosts in the NPM UI (or its API).

`cloudflare_proxied` defaults to `false` (plain DNS-only A records). **Leave it
false until after certificates are issued** (whether via NPM’s Let’s Encrypt
or certbot). If traffic is routed through the Cloudflare proxy first, HTTP-01
still works only if the zone’s SSL/TLS mode is **Full** or **Full (Strict)**;
the default **Flexible** mode causes a redirect loop that breaks issuance.

Once certs are in place and you want the orange-cloud benefits (DDoS mitigation,
CDN, origin IP hidden from public DNS), flip the setting:

```hcl
cloudflare_proxied = true
```

Then set the zone's SSL/TLS mode to **Full (Strict)** in the Cloudflare
dashboard and run `tofu apply`.

### Post-provision steps (DNS)

**1. Point DNS at the instance IP**

If `cloudflare_zone_id` (or per-domain `cf_zone_id`) is set, `tofu apply`
already created the A records — skip to step 2. Otherwise, create an A record
for each domain pointing to `tofu output -raw public_ip`. DNS must resolve
before Let’s Encrypt can issue certificates.

**2. Wait for DNS to propagate**

```sh
watch -n 10 dig +short example.com
```

Once `dig` returns the instance public IP, proceed.

### Default path: Nginx Proxy Manager

After `host_config` has brought the stack up:

1. Open the NPM admin UI at `http://<public-ip>:81` (or via a domain if you’ve
   already proxied it). Restrict who can reach port 81 with
   `allowed_admin_cidrs`.
2. Default first login is `admin@example.com` / `changeme` — **change
   immediately**.
3. **Proxy Hosts → Add Proxy Host** for each app (see Grafana example under
   [Monitoring & alerting](#monitoring--alerting)).
4. **SSL tab**: request a Let’s Encrypt certificate, force SSL.
5. NPM stores config and certs under bind mounts on the host
   (`npm_data`, `letsencrypt`) so they survive compose redeploys.

### Optional path: apt nginx (`install_nginx = true`)

On **first boot only**, cloud-init will:

- Install `certbot` and `python3-certbot-nginx` via apt
- Write an nginx reverse-proxy server block for each `proxy_domains` entry
  (HTTP on port 80), using each entry’s `upstream`
- Write `/usr/local/bin/setup-ssl` — the one-time SSL issuance script

After DNS propagates:

```sh
ssh ubuntu@<public-ip>
sudo /usr/local/bin/setup-ssl
```

This runs `certbot --nginx` for each configured domain, obtains Let’s Encrypt
certificates, and reloads nginx with HTTPS. Certbot’s systemd timer handles
renewals automatically — no further action needed.

```sh
curl -I https://example.com
```

Because `user_data` is ignored after create, **adding apt-nginx domains later
does not rewrite vhosts on apply**. Prefer NPM for day-2 domains, or configure
nginx manually on the host (snippet below), or deliberately rebuild the
instance so cloud-init runs again.

#### Adding apt-nginx domains after initial provisioning (manual)

```sh
# On the instance:
sudo tee /etc/nginx/sites-available/newdomain.com > /dev/null <<'EOF'
server {
    listen 80;
    listen [::]:80;
    server_name newdomain.com;

    location / {
        proxy_pass         http://127.0.0.1:PORT;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
EOF
sudo ln -s /etc/nginx/sites-available/newdomain.com /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx --non-interactive --agree-tos -m you@example.com -d newdomain.com
```

## Monitoring & alerting

`docker/docker-compose.yml` runs a metrics stack alongside the other shared
services. `host_config` deploys the whole tree to
`/home/ubuntu/scripts/infra` on the instance.

| Service | Role |
|---------|------|
| **`node-exporter`** | Host CPU/memory/disk/load metrics |
| **`cadvisor`** | Per-container CPU/memory metrics |
| **`lgtm`** (`grafana/otel-lgtm`) | Grafana + Prometheus + OTel Collector. `otelcol-config.yaml` adds scrape jobs for node-exporter and cadvisor so host/container metrics land next to OTLP data |
| **`npm`** | Nginx Proxy Manager — HTTP(S) edge and Let’s Encrypt |
| **`postgres`** | Shared DB for *your* apps on `shared-network` (NPM uses SQLite, not this DB) |
| **`portainer`** | Docker UI via NPM only (has `docker.sock` — high privilege) |
| **`watchtower`** | Daily updates for containers labeled `com.centurylinklabs.watchtower.enable=true`. **Postgres is intentionally unlabeled** so the database is not auto-updated |

Alert rules, a notification policy, and an ntfy contact point are provisioned
from `docker/grafana-provisioning/alerting/` — CPU > 90% for 5m, available
memory < 10% for 5m, and `node-exporter` scrape failures.

None of the metrics services are published on host ports in compose — they ride
`shared-network` and are reached through NPM (or other containers), same as
other internal services.

Image tags are **pinned** (not `:latest`) so deploys are reproducible; Watchtower
still updates *labeled* services to newer digests on its schedule. Bump pins in
compose when you want a controlled upgrade path without Watchtower.

### Secrets and first-time monitoring setup

**1. ntfy topic (`ntfy_topic` in terraform.tfvars)**

Rendered into Grafana’s contact point on deploy from
`contactpoints.yaml.tftpl`. ntfy.sh topics are unauthenticated by default —
anyone who guesses the name can read or publish — so pick something long/random,
or self-host ntfy if you want it locked down. Subscribe in the
[ntfy app](https://ntfy.sh/) (or `ntfy subscribe <topic>` via CLI) to receive
pushes.

**2. Grafana admin password (`grafana_admin_password`)**

Written to the host `.env` as `GF_SECURITY_ADMIN_PASSWORD`. The `lgtm` service
disables anonymous access (the image otherwise defaults to anonymous users with
**Admin** role). Log in as `admin` with the password from tfvars.

**3. Postgres password (`postgres_password`)**

Also written to `.env`. Required by compose (`POSTGRES_PASSWORD` must be set).

**4. Stack is brought up by apply**

You do not need a separate manual `docker compose up` for the infra stack —
`host_config` does it. To inspect on the host:

```sh
ssh -i .ssh/tf-managed-key ubuntu@$(tofu output -raw public_ip)
cd /home/ubuntu/scripts/infra
sudo docker compose ps
```

Grafana provisions alert rules/contact point/policy automatically on startup
from the mounted `grafana-provisioning/alerting/` files — no manual UI step
for alerting itself.

**5. Expose Grafana through nginx-proxy-manager**

The `npm` container already handles HTTP(S)/certs for everything else. Add
Grafana as a new proxy host:

1. Open the NPM admin UI (`http://<public-ip>:81`, or via a domain if
   you've proxied it — default login `admin@example.com` / `changeme` on
   first run, change immediately).
2. **Proxy Hosts → Add Proxy Host**:
   - Domain Names: `grafana.yourdomain.com`
   - Scheme: `http`
   - Forward Hostname/IP: `lgtm` (container name — both are on
     `shared-network`, so NPM resolves it by Docker DNS)
   - Forward Port: `3000`
   - Enable **Websockets Support** (Grafana's live-updating dashboards use
     them)
3. **SSL tab**: request a new Let's Encrypt certificate, force SSL.
4. Point DNS for `grafana.yourdomain.com` at the instance (same as any other
   `proxy_domains` entry — via Cloudflare or manually; see
   [Domain proxying & SSL](#domain-proxying--ssl)). This domain isn't managed
   as an apt-nginx vhost; it's an NPM-only route to an internal Docker service.
   You can still list it under `proxy_domains` solely so Cloudflare creates the
   A record (upstream is ignored when `install_nginx = false`).
5. Visit `https://grafana.yourdomain.com` and log in with `admin` / the
   password from `grafana_admin_password`.

**6. Import dashboards**

The image ships JVM/RED dashboards for OTLP-instrumented apps, but nothing
for the host/container metrics this setup adds. `cadvisor` collects
per-container stats for *every* container on the box, so it covers
`postgres`, `npm`, `portainer`, and `watchtower` too — no per-service
exporter needed for basic CPU/memory visibility into any of them.

In Grafana: **Dashboards → New → Import**, paste the dashboard ID, and point
it at the pre-provisioned `Prometheus` data source (uid `prometheus`).

| ID | Dashboard | Covers |
|----|-----------|--------|
| [1860](https://grafana.com/grafana/dashboards/1860) | Node Exporter Full | Host CPU, memory, disk, load, network |
| [19908](https://grafana.com/grafana/dashboards/19908) | cAdvisor / Docker container overview | Per-container CPU/memory for every service, including `postgres`, `npm`, `portainer`, `watchtower`, `lgtm` itself |

If you later want deeper-than-CPU/mem insight — Postgres connections/query
stats, or NPM request rates and status codes — that needs a dedicated
exporter added as a new container (`postgres_exporter`, an nginx log
exporter), not just a dashboard import.

## Rebuilding bootstrap (cloud-init)

Because of `ignore_changes = [user_data]`, edits to `cloud-init.yaml.tftpl`
never reach a running instance on normal apply. That is intentional so day-2
work does not destroy the VM.

To re-run bootstrap (e.g. you changed SSH hardening or swap):

1. Prefer applying the same change manually over SSH if the instance has data
   you care about.
2. Or replace the instance deliberately (understand this recreates the compute
   instance; the boot volume is a separate resource with
   `delete_on_termination = false`, but you must still plan for data and
   downtime):

```sh
tofu apply -replace=openstack_compute_instance_v2.web
```

After a new instance boots, `host_config` re-runs because its trigger includes
`instance_id`, and redeploys the docker stack.

## State

Local state (`terraform.tfstate`) for now. Fine for a single-operator personal
project. **What ends up in state that is sensitive:**

- TF-managed SSH private key (`tls_private_key`)
- Host passwords and ntfy topic (variables + provisioner material)
- Cloudflare API token (if set)
- GitHub PAT (if set)

Do not commit state (already gitignored). Back it up encrypted if the host
matters.

When you want remote state, common options for OpenStack:

- **S3-compatible object store** (if Rumble exposes one, or via Hetzner/AWS).
  Use the `s3` backend with `skip_credentials_validation` / `skip_region_validation`
  flags for non-AWS endpoints.
- **Terraform Cloud / Scalr / Spacelift** — managed, free tier available.
- **Git-based via `tfstate-git`** — not recommended but exists.

To migrate, add a `backend` block to `versions.tf` and run `tofu init -migrate-state`.

## CI

`.github/workflows/terraform.yml` runs `fmt -check`, `init -backend=false`, and
`validate` on PRs (also when `docker/**` changes). `plan` is commented out —
enable it once you have:

1. A remote state backend (so CI has something to diff against).
2. OpenStack credentials injected as secrets (`OS_AUTH_URL`, `OS_USERNAME`,
   `OS_PASSWORD`, `OS_PROJECT_NAME`, `OS_REGION_NAME`, etc.).

Note: `plan` in CI also needs network reachability to the instance **or** a
design that does not run provisioners on every plan (provisioners only run on
apply when the null_resource is created/replaced). Targeting pure cloud
resources for CI plan is a common approach.

## Extending

- **More security group rules** — e.g. Rustdesk self-hosted uses TCP
  21115–21119 and UDP 21116. Add corresponding
  `openstack_networking_secgroup_rule_v2` resources in `main.tf`.
- **Additional providers** — add entries to `required_providers` in
  `versions.tf` and a matching `provider` block. Keep vendor-specific resources
  in their own `*.tf` files (e.g. `hetzner.tf`, `aws.tf`).
- **Base image updates** — the image data source uses `most_recent = true`, but
  the boot volume has `lifecycle { ignore_changes = [image_id] }` so a newer
  cloud image with the same name does not recreate the volume (and cascade into
  instance replacement). To intentionally rebuild from a new image, plan a
  volume/instance replacement and data migration.
- **PublicStatic + floating IP pattern** — set `network_name` to a *private*
  network, add `openstack_networking_router_v2` with `external_network_id`
  pointing at `PublicStatic`, add `openstack_networking_router_interface_v2`
  attaching the private subnet, and add `openstack_networking_floatingip_v2` +
  `floatingip_associate_v2`. Requires enough `public_ip` quota.

## Memory management on small flavors

The `docker/docker-compose.yml` services all carry a `mem_limit` sized for an
`s1a.medium` (4 GB) host running the infra stack plus a couple of Node.js/JVM
apps alongside it. If you add services or move to a smaller flavor, revisit
these limits — a container hitting its `mem_limit` gets OOM-killed (and
restarted per `restart: unless-stopped`) rather than starving the host, which
is deliberate, but a limit set too low just means frequent restarts instead of
a real fix.

`cloud-init.yaml.tftpl` provisions a 2 GB swapfile on first boot
(`vm.swappiness=10`, so it's used as a burst cushion, not a substitute for
having enough RAM). This only applies to *new* instances — changing the
template does not re-run on existing VMs (see
[Rebuilding bootstrap (cloud-init)](#rebuilding-bootstrap-cloud-init)).
To add swap to an already-running instance without replacing it, run the
equivalent commands manually over SSH:

```sh
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
sudo sysctl -w vm.swappiness=10
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
```

For JVM and Node.js apps you deploy alongside this stack, set explicit memory
ceilings rather than relying on runtime defaults — `-Xmx` for the JVM,
`--max-old-space-size` for Node — since both otherwise size themselves off
total visible host memory, which can over-allocate on a small instance.

## Resizing the instance

To check the current flavor and see what else is available:

```sh
openstack server list -f json                 # current flavor, under "Flavor"
openstack flavor list -f json                  # all flavors available on the project
openstack flavor show <flavor-name> -f json    # RAM/vCPU/disk + rumble:* properties for one flavor
```

Rumble's flavor families (shared-compute `s1a`, compute-optimized `c2a`,
general-purpose `m2a`, memory-optimized `r2a`) each scale from `large`/`micro`
up through `Nxlarge`. All of them report `disk: 0` — the root disk here is the
separate `openstack_blockstorage_volume_v3.boot` volume, so a resize only
changes CPU/RAM and never touches your data volume.

To resize, change `flavor_name` in `terraform.tfvars` (or on
`openstack_compute_instance_v2.web`) and run `tofu apply`. The OpenStack
provider does this as an in-place resize, not a destroy/recreate — the boot
volume, port, and public IP all survive. Nova stops the instance during the
resize and Terraform confirms it automatically, so expect a minute or two of
downtime.

## Learning map (where to read code)

| Question | Look at |
|----------|---------|
| How is the VM, volume, port, SG built? | `main.tf` |
| How does day-2 deploy work? | `host.tf` |
| What runs on first boot only? | `cloud-init.yaml.tftpl` |
| How are Cloudflare records keyed off domains? | `dns.tf` |
| What variables exist and why? | `variables.tf`, `terraform.tfvars.example` |
| What containers run and with what limits? | `docker/docker-compose.yml` |
| How do host metrics enter Prometheus? | `docker/otelcol-config.yaml` |
| What alerts fire to ntfy? | `docker/grafana-provisioning/alerting/` |
