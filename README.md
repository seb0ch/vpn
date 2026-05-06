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

## Per-User Upstream Chaining (Xray)

Forward a specific user's traffic from this server to another Xray server, while other users continue to exit locally. AmneziaWG is unaffected — chaining is Xray-only.

```
                         ┌─▶ Internet  (other users exit here)
this server ─VLESS/REALITY┤
                         └─▶ upstream Xray ─▶ Internet  (chained user exits here)
```

**Setup:**

1. On the **upstream** server, treat this server as a regular Xray client and save the printed VLESS link:
   ```bash
   ./xray/add-client.sh server1-uplink
   ```

2. On **this** server, register the upstream and route a user through it:
   ```bash
   ./xray/add-upstream.sh <tag> '<vless_url_from_step_1>'
   ./xray/set-route.sh    <user> <tag>
   ```

   - `<tag>` — alias for the upstream (e.g. `eu-exit`). Cannot be `direct` or `blocked`.
   - `<user>` — existing client name (matches the `email` field set by `add-client.sh`).
   - Wrap the VLESS URL in single quotes — it contains `&` and `?` characters that the shell would otherwise interpret.

3. Revert a user back to local exit:
   ```bash
   ./xray/set-route.sh <user> direct
   ```

The Xray container is restarted on each operation; users without a per-user rule continue to exit through the server's local `freedom` outbound.

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
│   ├── Dockerfile          # Multi-stage: builds amneziawg-go + awg-tools from source
│   ├── entrypoint.sh       # Sets up TUN, iptables, DNS DNAT, starts daemon
│   ├── gen-keys.sh         # Generates server keys + obfuscation params + random port
│   ├── add-client.sh       # Generates keypair, writes config, restarts container
│   ├── remove-client.sh    # Removes peer from config, restarts container
│   └── conf/
│       └── awg0.tmpl       # Server config template (awg0.conf is gitignored)
├── xray/
│   ├── Dockerfile          # Multi-stage: builds Xray-core from source
│   ├── entrypoint.sh       # Starts Xray with config
│   ├── gen-keys.sh         # Generates X25519 keypair + Short ID
│   ├── add-client.sh       # Generates UUID, patches config.json, restarts
│   ├── remove-client.sh    # Removes client from config.json, restarts
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

Client management requires a container restart (typically a few seconds). Each client gets a dedicated IP in the 10.8.0.0/24 subnet with a pre-shared key for post-quantum forward secrecy.

### Xray REALITY

Xray REALITY makes VPN traffic indistinguishable from legitimate HTTPS traffic to `cloudflare.com`. Unlike traditional TLS proxies, REALITY doesn't require a domain or certificate — it borrows the TLS handshake of the destination server, making it virtually undetectable by censorship systems.

Client management requires a container restart (typically under 2 seconds). Each client is identified by a UUID and connects via the VLESS protocol with `xtls-rprx-vision` flow control.

### DNS

All VPN client DNS queries are intercepted via iptables DNAT and redirected to an internal dnscrypt-proxy instance. This resolver encrypts queries via DNSCrypt or DNS-over-HTTPS to Cloudflare and Google, enforces DNSSEC validation, and requires no-logging from upstream resolvers. The DNS container is not exposed to the host — it's accessible only within the Docker network.

## Security Notes

- **Built from source** — amneziawg-go, awg-tools, Xray-core, and dnscrypt-proxy are all compiled from source inside multi-stage Docker builds. No pre-built binaries.
- **Firewall and SSH hardening are not automated** — `deploy.sh` focuses solely on the VPN stack. Configure UFW/iptables, SSH key-only auth, and fail2ban separately (recommended for production).
- **Key isolation** — all keys are generated on the server and never transmitted. Key files have `chmod 600` permissions.
- **DNS privacy** — client DNS queries are forcibly redirected to the internal resolver via iptables DNAT; they never leave the server unencrypted.
- **Xray routing** blocks connections to private IP ranges (RFC 1918) to prevent server-side request forgery.
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
