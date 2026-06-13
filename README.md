**English** | [Русский](README.ru.md)

# VPN Stack

> For the paranoid sysadmin who doesn't trust pre-built binaries, considers "just use a commercial VPN" a personal insult, and won't sleep until every line of code has been read, every key has been generated on hardware they own, and every packet goes exactly where they said it goes. Everything here is built from source. No black boxes. Sleep tight :smile:

Self-hosted VPN server combining **AmneziaWG** (obfuscated WireGuard) and **Xray REALITY** (VLESS proxy), with an internal **dnscrypt-proxy** resolver — all orchestrated via Docker Compose.

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                  Docker network: vpn                 │
│                   172.20.0.0/24                      │
│                                                      │
│  ┌────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │    DNS     │  │  AmneziaWG   │  │    Xray      │  │
│  │ 172.20.0.2 │  │ 172.20.0.3   │  │ 172.20.0.4   │  │
│  │  DNS :53   │  │ VPN :<rand>  │  │ REALITY :443 │  │
│  │ (internal) │  │   (public)   │  │   (public)   │  │
│  └────────────┘  └──────────────┘  └──────────────┘  │
└──────────────────────────────────────────────────────┘
```

| Service       | Role                                                     | Exposed Port     |
|---------------|----------------------------------------------------------|------------------|
| **DNS**       | dnscrypt-proxy — encrypts and authenticates DNS queries  | 53 (Docker only) |
| **AmneziaWG** | Obfuscated WireGuard VPN server                          | random/udp       |
| **Xray**      | VLESS + REALITY proxy                                    | 443/tcp          |

All VPN clients are forced to use the internal DNS resolver via iptables DNAT — DNS queries never leave the server uncontrolled.

## Prerequisites

- Ubuntu **24.04 or newer**
- Root or sudo access
- Docker Engine + Docker Compose plugin (see below)
- Ports **443/tcp** and the randomly assigned **AWG UDP port** open in your cloud firewall (AWS Security Group, GCP VPC rules, etc.)
- **≈1.5 GB of RAM or swap during the build.** Everything is compiled from source; building Xray-core (which pulls in gVisor) peaks well above what a 512 MB box has. On a small instance, add swap **before** `deploy.sh`, e.g.:
  ```bash
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab   # persist across reboots
  ```
  Without enough memory the build is OOM-killed (`docker-buildx` dies, `xray` image never finishes). Runtime needs only a fraction of this — swap is purely for the from-source compile.

### Install Docker

If Docker is not yet installed, use the provided helper script:

```bash
sudo ./docker-install.sh
```

The script installs Docker Engine and the Docker Compose plugin from the official Docker apt repository. It skips any component that is already present, and errors out on Ubuntu versions older than 24.04.

> For production deployments, also consider:
> - Firewall rules (UFW, iptables, or cloud firewall)
> - SSH hardening (non-default port, disable password auth)
> - fail2ban or similar intrusion prevention

## Quick Start

```bash
sudo ./deploy.sh
```

This script will:

1. Verify Docker and Docker Compose are installed
2. Build all Docker images from source (`amneziawg`, `xray`, `dns`)
3. Generate AmneziaWG server keys, random obfuscation parameters, and a random UDP port (49152–65535)
4. Generate `docker-compose.yml` from the template
5. Generate Xray REALITY X25519 keys and Short ID
6. Start all services with `docker compose up -d`

At the end, the script prints the two ports you must open on your cloud firewall.

## Client Management

**Add a client** to both AmneziaWG and Xray simultaneously:

```bash
./add-client.sh <name>
```

- Client names may only contain letters, digits, hyphens (`-`), and underscores (`_`).
- For AmneziaWG: creates `clients/<name>_amneziawg.conf` and prints a QR code to the terminal.
- For Xray: creates `clients/<name>_xray.vless` and `clients/<name>_xray.png`, prints the VLESS link and a terminal QR code.
- Both services are restarted to apply the new configuration. This is a fast operation, typically taking only a few seconds.

**Remove a client** from both services:

```bash
./remove-client.sh <name>
```

Both the AmneziaWG and Xray containers are restarted to apply the updated config.

> The per-service scripts (`amneziawg/add-client.sh`, `xray/add-client.sh`, etc.) work individually if you only need one protocol.

## Operational Scenarios

A cookbook for the common lifecycle operations. All commands run from the repo
root on the relevant server.

### 1. Fresh deploy

```bash
sudo ./docker-install.sh   # once, if Docker is missing
sudo ./deploy.sh
```
Open the two ports it prints (443/tcp + the random AWG UDP port) in your cloud
firewall. See [Prerequisites](#prerequisites) for the swap requirement on small
instances.

### 2. Redeploy / update an existing server

Pull new code (or edit in place) and re-run the same script:

```bash
git pull              # or rsync your changes onto the server
sudo ./deploy.sh
```
`deploy.sh` is **idempotent**: it rebuilds the Docker images (picking up new
source and re-pinned upstreams), regenerates `docker-compose.yml`, and recreates
changed containers. Existing server keys (`server_private.key`,
`reality_keys.txt`) and all clients are **preserved** — key generation is skipped
when the keys already exist. To force new server keys, delete those files first.

### 3. Recompile the AmneziaWG kernel module

Needed after a host **kernel upgrade** (the `.ko` is built for one kernel
version), or to apply a new pinned module commit. The container must be stopped
first — `rebuild-amneziawg.sh` refuses to run while it is up:

```bash
docker compose stop amneziawg
sudo ./rebuild-amneziawg.sh
docker compose start amneziawg
```
It rebuilds the module from the pinned commit in a one-shot Ubuntu container
matching your running kernel, validates the `.ko` with `modinfo`, atomically
installs it, `modprobe`s it, persists autoload in `/etc/modules-load.d/`, and
auto-rolls-back from a timestamped backup (`/var/backups/amneziawg-kmod/<kver>/`,
3 most recent) if `modprobe` fails.

### 4. Deploy to additional servers

Each server is independent — repeat scenario 1 on every host. A typical layout is
one **entry** server clients connect to, plus one or more **exit** servers used
as upstreams (see scenario 5). There is nothing to share between hosts except the
VLESS uplink links you generate in the next scenario.

### 5. Create a client that exits through another server (Xray chaining)

Forward a specific user's Xray traffic from the entry server to an exit server,
while other users exit locally. **AmneziaWG is not chained — see the limitation
below; the user's AmneziaWG profile always exits at the entry server.**

```
                          ┌─▶ Internet            (other users / AWG exit here)
entry ─VLESS/REALITY──────┤
                          └─▶ exit server ─▶ Internet   (chained Xray user exits here)
```

1. On the **exit** server, register the entry server as an ordinary client and
   copy the printed VLESS link:
   ```bash
   ./xray/add-client.sh entry-uplink
   cat clients/entry-uplink_xray.vless
   ```

2. On the **entry** server, create the end client, register the exit as an
   upstream, and route the client through it:
   ```bash
   ./add-client.sh alice                       # AWG + Xray profiles for the user
   ./xray/add-upstream.sh de '<vless_link_from_step_1>'
   ./xray/set-route.sh    alice de
   ```
   - `<tag>` (`de` here) — alias for the exit server. Cannot be `direct` or `blocked`.
   - `<user>` — existing client name (the `email` set by `add-client.sh`).
   - **Wrap the VLESS URL in single quotes** — it contains `&`/`?` the shell would split on.

   `alice` now reaches the internet from the exit server's IP over Xray; her
   AmneziaWG profile still exits at the entry server.

### 6. Change a client's exit (re-route)

Point an existing user at a different upstream, or back to local exit. No client
reconfiguration is needed — only the entry server changes:

```bash
./xray/set-route.sh alice il        # send alice out via the 'il' upstream instead
./xray/set-route.sh alice direct    # send alice back to local (entry-server) exit
```
`set-route` is the single source of truth for a user's per-user rule: switching
replaces the old rule, and `direct` removes it entirely. Users without a rule use
the local `freedom` outbound. The Xray container restarts on each operation
(typically under 2 seconds).

> **AmneziaWG chaining is not implemented.** `add-upstream`/`set-route` only steer
> Xray traffic. A user's AmneziaWG tunnel always egresses at the server they
> connect to. Routing AWG through another host would require a site-to-site WG
> tunnel plus per-client policy routing, which this project does not (yet) ship.

## Client Apps

### AmneziaWG

Import `clients/<name>_amneziawg.conf` or scan the QR code printed in the terminal.

| Platform | App |
|----------|-----|
| Android  | [AmneziaWG](https://play.google.com/store/apps/details?id=org.amnezia.awg) |
| iOS / macOS | [AmneziaWG](https://apps.apple.com/app/amneziawg/id6478942365) |
| Windows  | [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-windows-client/releases) |

### MTU Tuning (macOS)

Use `mtu.sh` to find the optimal MTU for your AmneziaWG client.

1. Disconnect your VPN.
2. Run:

```bash
./mtu.sh <ip-or-hostname>  # your VPN server IP
```

3. Take the script's `Good starting point` value and set it as `MTU` in your AmneziaWG client config.

### Xray REALITY

Copy the VLESS link from `clients/<name>_xray.vless`, scan `clients/<name>_xray.png`, or use the terminal QR code.

| Platform | App |
|----------|-----|
| Android  | [V2Box](https://play.google.com/store/apps/details?id=dev.hexasoftware.v2box) |
| iOS / macOS | [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) · [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) |
| Windows  | [V2Box](https://github.com/nicola-5/v2box-releases/releases) |

## DNS Flow

```
VPN client → awg0 tunnel (10.8.0.0/24)
  → iptables DNAT (port 53 → 172.20.0.2:53)
  → dnscrypt-proxy (DNSSEC required, no-log, no-filter)
  → Cloudflare + Google resolvers (DNSCrypt / DoH)
```

## Project Structure

```
├── docker-install.sh       # Install Docker Engine + Compose plugin (Ubuntu 24.04+, idempotent)
├── deploy.sh               # Full server bootstrap (requires Docker pre-installed)
├── add-client.sh           # Add client to both AWG + Xray
├── remove-client.sh        # Remove client from both AWG + Xray
├── rebuild-amneziawg.sh    # Rebuild and reload the AmneziaWG kernel module after a host kernel upgrade
├── mtu.sh                  # macOS helper to estimate path MTU and suggest AWG MTU
├── cleanup.sh              # Remove all containers, images, keys, and generated configs
├── docker-compose.yml.tmpl # Template; docker-compose.yml is generated and gitignored
├── lib/
│   └── common.sh           # Shared utilities (logging, validation, IP fetch)
├── amneziawg/
│   ├── Dockerfile          # Builds awg-tools (awg, awg-quick) from a pinned source; the kernel module is built on the host by deploy.sh / rebuild-amneziawg.sh
│   ├── entrypoint.sh       # Verifies the host module is loaded (fail-fast, no CAP_SYS_MODULE), brings up awg0 via awg-quick
│   ├── gen-keys.sh         # Generates server keys + obfuscation params + random port (umask 077)
│   ├── add-client.sh       # Generates keypair + PSK, writes config, hot-reloads via awg syncconf
│   ├── remove-client.sh    # Removes peer (by name) and hot-reloads
│   ├── remove-peer.py      # Atomic [Peer]-block removal from awg0.conf (used by remove-client.sh)
│   └── conf/
│       └── awg0.tmpl       # Server config template incl. forward-path firewall (awg0.conf is gitignored)
├── xray/
│   ├── Dockerfile          # Multi-stage: builds Xray-core from a pinned commit; geo DBs checksum-verified
│   ├── entrypoint.sh       # Starts Xray with config
│   ├── gen-keys.sh         # Generates X25519 keypair + Short ID (umask 077)
│   ├── add-client.sh       # Generates UUID, patches config.json, restarts
│   ├── remove-client.sh    # Removes client + its routing rules from config.json, restarts
│   ├── remove-client.py    # Atomic client + route-rule removal (used by remove-client.sh)
│   ├── add-upstream.sh     # Registers an upstream Xray server as a vless+reality outbound
│   ├── set-route.sh        # Routes a specific user through an upstream (or back to direct)
│   └── conf/
│       └── config.json.tmpl # Xray config template (config.json is gitignored)
├── dns/
│   ├── Dockerfile          # Builds dnscrypt-proxy from source
│   └── dnscrypt-proxy.toml # Pinned to Cloudflare + Google, DNSSEC enforced
└── clients/                # Generated client configs, VLESS links, QR PNGs (gitignored)
```

## How It Works

### AmneziaWG

AmneziaWG is an obfuscated fork of WireGuard that adds junk packets and header manipulation to resist DPI-based blocking. On deploy, the server generates random obfuscation parameters (Jc, Jmin, Jmax, S1–S4, H1–H4) that are baked into both server and client configs, making each deployment's traffic fingerprint unique.

Adding or removing a client is applied live via `awg syncconf` — no container restart — so existing sessions are undisturbed. Each client gets a dedicated IP in the 10.8.0.0/24 subnet with a pre-shared key for post-quantum forward secrecy. The kernel module itself is built on the host (not in the container) and reloaded only on a kernel upgrade (see scenario 3).

### Xray REALITY

Xray REALITY makes VPN traffic indistinguishable from legitimate HTTPS traffic to `cloudflare.com`. Unlike traditional TLS proxies, REALITY doesn't require a domain or certificate — it borrows the TLS handshake of the destination server, making it virtually undetectable by censorship systems.

Client management requires a container restart (typically under 2 seconds). Each client is identified by a UUID and connects via the VLESS protocol with `xtls-rprx-vision` flow control.

### DNS

All VPN client DNS queries are intercepted via iptables DNAT and redirected to an internal dnscrypt-proxy instance. This resolver encrypts queries via DNSCrypt or DNS-over-HTTPS to Cloudflare and Google, enforces DNSSEC validation, and requires no-logging from upstream resolvers. The DNS container is not exposed to the host — it's accessible only within the Docker network.

## Security Notes

- **Built from source, pinned** — the AmneziaWG kernel module, awg-tools, Xray-core, and dnscrypt-proxy are all compiled from source. Each upstream is pinned to a specific commit (kernel-module commit in `lib/common.sh`, the rest via Dockerfile `ARG`s), and the Xray geo-databases are verified against SHA-256 hashes recorded in-repo — a tampered or swapped upstream fails the build. No pre-built binaries.
- **Minimal container privileges** — the AmneziaWG container holds only `CAP_NET_ADMIN`; it has no `CAP_SYS_MODULE` and no `/lib/modules` mount, so a container compromise cannot load code into the host kernel. The module is loaded on the host and persisted via `/etc/modules-load.d/`.
- **VPN-client network isolation** — forward-path rules in `awg0.tmpl` drop client→client traffic, the cloud metadata endpoint (`169.254.169.254`, `168.63.129.16`), RFC1918, and CGNAT ranges. `deploy.sh` also installs a host `INPUT` rule (persisted as `vpn-host-firewall.service`) blocking new connections from the docker subnet to the host — closing the path to host services (e.g. sshd) that the cloud firewall cannot see.
- **DNS privacy** — *all* client port-53 traffic (any destination) is forcibly DNAT'ed to the internal dnscrypt-proxy resolver; clients cannot bypass it with an external plain-DNS server. (DoH/DoT on 443/853 cannot be intercepted at this layer.)
- **Xray routing** blocks connections to private IP ranges (`geoip:private`) to prevent server-side request forgery.
- **Key isolation** — all keys are generated on the server and never transmitted. Secret-writing scripts run under `umask 077`; key files, live configs, and the `clients/` directory are `chmod 600`/`700`.
- **Firewall and SSH hardening are otherwise not automated** — beyond the host INPUT rule above, configure your cloud firewall, SSH key-only auth, and fail2ban separately (recommended for production).
- Generated keys, client configs, and `docker-compose.yml` are gitignored and never committed.

## Troubleshooting

**Container won't start:**
```bash
docker compose logs <service>     # Check logs for errors
docker compose ps                 # Check container status and health
```

**AmneziaWG daemon fails:**
```bash
docker exec amneziawg cat /tmp/awg.log   # Daemon startup log
docker exec amneziawg awg show           # Interface status
```

**Client can't connect (AWG):**
```bash
docker exec amneziawg awg show awg0      # Check if peer is listed
```

**Client can't connect (Xray):**
- Ensure port 443/tcp is open in your cloud firewall
- Verify the VLESS link matches the server's public key and Short ID

**DNS not resolving:**
```bash
docker exec dns drill @127.0.0.1 example.com   # Test internal DNS
```

**Regenerate everything:**
```bash
./cleanup.sh && sudo ./deploy.sh
```

**Kernel upgrade — AmneziaWG module no longer loads:**

After an Ubuntu kernel upgrade, the AmneziaWG `.ko` built for the previous kernel will not load. Stop the container, rebuild the module against the new kernel, restart:

```bash
docker compose stop amneziawg
sudo ./rebuild-amneziawg.sh
docker compose start amneziawg
```

`rebuild-amneziawg.sh` builds the module in a one-shot Ubuntu container matching your kernel version, validates the resulting `.ko` (`modinfo`), atomically replaces the installed module, and auto-rolls-back from a backup if `modprobe` fails. Backups are kept in `/var/backups/amneziawg-kmod/<kver>/` (3 most recent).

## Teardown

To fully reset the server back to a clean state:

```bash
./cleanup.sh
```

Prompts for confirmation, then:
- Stops and removes all containers and the Docker network
- Removes Docker images (`amneziawg`, `xray`, `dns`)
- Deletes all generated keys, server configs, client configs, and QR codes

After cleanup, `sudo ./deploy.sh` brings everything back up from scratch.

## License

See [LICENSE](LICENSE).
