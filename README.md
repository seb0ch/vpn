**English** | [Русский](README.ru.md)

# VPN Stack

> For the paranoid sysadmin who doesn't trust pre-built binaries, considers "just use a commercial VPN" a personal insult, and won't sleep until every line of code has been read, every key has been generated on hardware they own, and every packet goes exactly where they said it goes. Everything here is built from source. No black boxes. Sleep tight :smile:

Self-hosted VPN server combining **AmneziaWG** (obfuscated WireGuard) and **Xray REALITY** (VLESS proxy), with an internal **dnscrypt-proxy** resolver — all orchestrated via Docker Compose. Both VPN components ship enabled; either can be switched off per host (see [Choosing components](#choosing-components)).

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

| Service       | Role                                                     | Exposed Port     | Optional |
|---------------|----------------------------------------------------------|------------------|----------|
| **DNS**       | dnscrypt-proxy — encrypts and authenticates DNS queries  | 53 (Docker only) | follows AmneziaWG |
| **AmneziaWG** | Obfuscated WireGuard VPN server                          | random/udp       | `ENABLE_AMNEZIAWG=0` |
| **Xray**      | VLESS + REALITY proxy                                    | 443/tcp          | `ENABLE_XRAY=0` |

All AmneziaWG clients are forced to use the internal DNS resolver via iptables DNAT — their DNS queries never leave the server uncontrolled. Xray clients resolve through the public servers configured in `config.json`, which is why `dns` is deployed only alongside AmneziaWG.

## Prerequisites

- Ubuntu **24.04 or newer** (tested on **24.04** and **26.04**)
- Root or sudo access
- `git` (the build resolves component release tags with `git ls-remote`) — install it first if the host lacks it (`apt-get install -y git`)
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

The script installs Docker Engine, the Compose plugin and the buildx plugin from Ubuntu's own repositories (`docker.io`, `docker-compose-v2`, `docker-buildx` from the `universe` component, enabled by default) — **no third-party apt repository or GPG key is added**. It skips any component that is already present, and errors out on Ubuntu versions older than 24.04.

> Note: `docker.io` depends on Ubuntu's `containerd` and therefore conflicts with the upstream `docker-ce` / `containerd.io` stack from `download.docker.com`. On a fresh host this is a clean install; if a host already runs the upstream Docker packages, purge them (and remove `/etc/apt/sources.list.d/docker.list`) before switching.

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
2. Resolve each **enabled** third-party component to a release (see [Component versions](#component-versions))
3. Build the images from source, tagged with their release (`amneziawg:<ver>`, `xray:<ver>`, `dns:<ver>`); the kernel module is compiled against the host kernel
4. Generate AmneziaWG server keys, random obfuscation parameters, and a random UDP port (49152–65535)
5. Generate `docker-compose.yml` from the template, containing only the enabled services
6. Generate Xray REALITY X25519 keys and Short ID
7. Start all services with `docker compose up -d` (containers are named `vpn-amneziawg`, `vpn-xray`, `vpn-dns`)

Steps 3–6 skip whatever is switched off — see [Choosing components](#choosing-components). At the end, the script prints the ports you must open on your cloud firewall.

### Component versions

Every deploy (and re-deploy) resolves each third-party component to a release
tag and builds from it. By default it uses the **latest upstream release**; pin
a specific one by exporting an env var before `deploy.sh`:

| Component | Env var | Upstream | Image |
|-----------|---------|----------|-------|
| Xray-core | `XRAY_RELEASE` | XTLS/Xray-core | `xray:<tag>` |
| AmneziaWG (kernel module **and** tools) | `AMNEZIAWG_RELEASE` | amnezia-vpn | `amneziawg:<tag>` |
| dnscrypt-proxy | `DNSCRYPT_RELEASE` | DNSCrypt/dnscrypt-proxy | `dns:<tag>` |

```bash
# latest of everything (default)
sudo ./deploy.sh

# pin Xray, take latest for the rest
sudo XRAY_RELEASE=v26.6.1 ./deploy.sh
```

- Resolution uses plain `git ls-remote` — no GitHub token, no `jq`. A tag is
  always pinned to its commit **SHA**, and sources are fetched by SHA, so a
  moved tag cannot silently change a build. The running version is visible as
  the image tag (`docker images`), so no lock file is kept.
- `AMNEZIAWG_RELEASE` drives both the kernel module (built on the host) and the
  userspace tools (in the image). The `amneziawg` image is tagged with the
  **tools** release — what the image actually contains; if the tools repo has no
  matching tag, the tools fall back to their own latest (logged). The kernel
  module is a separate host artifact and is only (re)built by
  `rebuild-amneziawg.sh` or a first deploy.
- The Xray **geo databases** (`geoip.dat`, `geosite.dat`) are always pulled at
  their latest and are intentionally not pinned; they refresh whenever the Xray
  image is rebuilt.

### Choosing components

Both VPN components are deployed by default. Set a flag to `0` to run a
single-protocol host — e.g. when you only ever hand out VLESS links, or when the
only thing that gets through a given network is AmneziaWG:

```bash
sudo ENABLE_AMNEZIAWG=0 ./deploy.sh    # Xray REALITY only (DNS goes with AmneziaWG)
sudo ENABLE_XRAY=0 ./deploy.sh         # AmneziaWG + DNS only
```

| Flag | Default | Values |
|------|---------|--------|
| `ENABLE_AMNEZIAWG` | `1` | `1/0`, `true/false`, `yes/no`, `on/off` (case-insensitive) |
| `ENABLE_XRAY` | `1` | same |

Disabling **both** is rejected — there would be nothing to deploy; use
`cleanup.sh` to tear a host down instead.

**`dns` follows AmneziaWG** and has no flag of its own: only AWG clients are
DNAT'ed to the internal resolver, while Xray resolves through the public servers
in its own `config.json`. So `ENABLE_AMNEZIAWG=0` also drops the `dns` container
(and the `depends_on` that referenced it) — an Xray-only host runs a **single**
container, `vpn-xray`.

A disabled component means:

- its image is not built, its keys are not generated, and its service is not
  rendered into `docker-compose.yml`;
- on a re-deploy its container is removed (`docker compose up -d --remove-orphans`);
- for AmneziaWG the host-level bits go too — `amneziawg-module.service` and
  `/etc/modules-load.d/amneziawg.conf` — so a reboot no longer loads or rebuilds
  the kernel module (an already-loaded module stays until the next reboot);
- **keys, live configs, and client files are left untouched.** Re-enabling the
  component (`sudo ./deploy.sh` with the flag back at `1`) brings back exactly
  the same peers/clients. Use `cleanup.sh` to erase them.

The generated `docker-compose.yml` is the source of truth for what a host runs:
`add-client.sh` / `remove-client.sh` read it and act only on the deployed
components, so `./add-client.sh alice` on an Xray-only host creates just the
VLESS profile.

## Client Management

**Add a client** to both AmneziaWG and Xray simultaneously (or to whichever
single component the host deploys — see [Choosing components](#choosing-components)):

```bash
./add-client.sh <name>
```

- Client names may only contain letters, digits, hyphens (`-`), and underscores (`_`).
- For AmneziaWG: creates `clients/<name>_amneziawg.conf` (import file) and `clients/<name>_amneziawg.png` (QR for the mobile app), and prints a QR to the terminal.
- For Xray: creates `clients/<name>_xray.vless` (the `vless://` link) and `clients/<name>_xray.png` (QR for the mobile app), and prints the link + a terminal QR.
- Either way the user needs only one artifact per protocol: the **file/link** for desktop import, or the **QR PNG** to scan on a phone.
- AmneziaWG is hot-reloaded in place (`awg syncconf`, no restart, existing sessions undisturbed); Xray is restarted (typically under 2 seconds).

**Remove a client** from both services:

```bash
./remove-client.sh <name>
```

The AmneziaWG peer is hot-reloaded out via `awg syncconf`; the Xray container is restarted. Each half runs independently, so a failure in one still revokes the other.

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

### 2. Upgrade / redeploy an existing server

**Upgrading is just a re-deploy — you do not remove anything.** Pull the new
code and re-run the same script:

```bash
git pull              # or rsync your changes onto the server
sudo ./deploy.sh
```

`deploy.sh` is **idempotent** and non-destructive. On an already-deployed host it:

- **preserves** server keys (`server_private.key`, `reality_keys.txt`) and **all
  clients** — key generation is skipped when the keys already exist;
- **re-resolves and rebuilds** the `amneziawg`, `xray`, and `dns` images at their
  release (latest by default, or your `*_RELEASE` pins), so a newer upstream
  release is picked up; the image tag reflects the deployed version;
- **re-renders** `docker-compose.yml` from the template, so changes to container
  capabilities, mounts, or ports take effect — and so does a changed
  `ENABLE_AMNEZIAWG` / `ENABLE_XRAY` (scenario 8);
- **re-applies** the host `INPUT` rule and `/etc/modules-load.d/amneziawg.conf` if
  they are missing.

Changed containers are recreated (a few seconds of downtime); unchanged ones are
left running.

**Two things a plain re-deploy does _not_ do** — handle these explicitly when an
upgrade touches them:

1. **Template changes are not back-ported to live configs.** `awg0.conf` and
   `config.json` are generated **once** (from `awg0.tmpl` / `config.json.tmpl`)
   and then own your live keys, clients, peers, and routes — so `deploy.sh` never
   overwrites them. If an upgrade changes `awg0.tmpl` (e.g. new firewall rules)
   you must migrate the live `awg0.conf` by hand, for example: back it up, port
   the new `PostUp`/`PostDown` block over while keeping your `[Interface]` keys
   and `[Peer]` blocks, then `docker compose up -d --force-recreate amneziawg`.
   (`config.json` rarely needs this — it holds your clients/routes, not policy.)
2. **The kernel module is not rebuilt.** `deploy.sh` skips the module build when
   one is already loaded, so picking up a newer AmneziaWG module release (or a
   kernel upgrade) needs scenario 3 (`rebuild-amneziawg.sh`).

To deliberately start fresh with **new** server keys, delete
`amneziawg/conf/server_private.key` / `xray/conf/reality_keys.txt` (and the
matching live configs) before re-deploying — but note this invalidates every
existing client.

### 3. Recompile the AmneziaWG kernel module

Needed after a host **kernel upgrade** (the `.ko` is built for one kernel
version), or to pick up a newer AmneziaWG module release. The container must be
stopped first — `rebuild-amneziawg.sh` refuses to run while it is up:

```bash
docker compose stop amneziawg
sudo ./rebuild-amneziawg.sh
docker compose start amneziawg
```
It rebuilds the module from the resolved release (`AMNEZIAWG_RELEASE` or latest)
in a one-shot Ubuntu container matching your running kernel, validates the `.ko`
with `modinfo`, atomically
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
   ./xray/add-upstream.sh germany '<vless_link_from_step_1>'
   ./xray/set-route.sh    alice germany
   ```
   - `<tag>` (`germany` here) — alias for the exit server. Cannot be `direct` or `blocked`.
   - `<user>` — existing client name (the `email` set by `add-client.sh`).
   - **Wrap the VLESS URL in single quotes** — it contains `&`/`?` the shell would split on.

   `alice` now reaches the internet from the exit server's IP over Xray; her
   AmneziaWG profile still exits at the entry server.

### 6. Change a client's exit (re-route)

Point an existing user at a different upstream, or back to local exit. No client
reconfiguration is needed — only the entry server changes:

```bash
./xray/set-route.sh alice israel    # send alice out via the 'israel' upstream instead
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

### 7. Restricted networks — change the REALITY camouflage domain

REALITY borrows the TLS handshake of a **camouflage domain**, and the client
sends it as the SNI. The default is `cloudflare.com`. Some **restrictive networks
block TLS to particular SNIs** — a client there sees the TCP connection open but
the handshake **hang (0 bytes back)**, while ordinary HTTPS still works. The fix
is to camouflage as a site that network doesn't block.

Pick a domain that is **not blocked from the client's network**, supports
**TLS 1.3 + HTTP/2**, and isn't fronted by an unwanted CDN — a big, boring,
locally-popular site is ideal. Quick check from the client's side (`rc` 28 =
blocked/silent-drop; `0` = clean pass; `35`/`60` = a TLS reply came back, not a
hang — normally a pass, but confirm since active interference can also land here):

```bash
curl -s -o /dev/null -w '%{exitcode}\n' --max-time 8 --resolve <sni>:443:<server-ip> https://<sni>/
```

Apply it:

- **Before the first deploy** — edit `dest` and `serverNames` in
  `xray/conf/config.json.tmpl`, then run `deploy.sh` (the default never touches the wire).
- **On a running server** — in `xray/conf/config.json`, under
  `inbounds[0].streamSettings.realitySettings`, set `dest` to `"<sni>:443"` (host
  **and** port) and `serverNames` to `["<sni>"]` (host only); then
  `docker compose restart xray`. Existing clients must be **reissued**: only the
  `sni=` in each `clients/<name>_xray.vless` changes (UUIDs/keys are unchanged) —
  regenerate the link + QR, and the client's SNI must match the server.

> A whole server IP can also be blocked at the TCP layer regardless of SNI. If
> even a non-TLS port (e.g. 22) hangs from the client's network but works from
> elsewhere, the IP itself is filtered — use a different address.

### 8. Turn a component off (or back on)

A host can run a single protocol. Re-deploy with the flag — nothing else to do:

```bash
sudo ENABLE_AMNEZIAWG=0 ./deploy.sh    # drop AmneziaWG (and DNS), keep Xray REALITY
sudo ./deploy.sh                       # both back on (flags default to 1)
```

The re-deploy removes the disabled service's container, stops building its
image, and — for AmneziaWG — removes `amneziawg-module.service` and
`/etc/modules-load.d/amneziawg.conf` so the kernel module is no longer loaded or
rebuilt at boot. Keys, live configs, and client files survive, so switching back
on restores the same peers/clients. Details and accepted values:
[Choosing components](#choosing-components).

Two notes:

- Existing profiles for the component you disabled **stop working** — that is
  the point. Their files stay in `clients/` until you delete them (or run
  `cleanup.sh`).
- Removing the last enabled component is refused; tear the host down with
  `cleanup.sh` instead.

## Operate with an AI assistant (Claude Code / Codex)

The repo ships a **`vpn` operator skill** — a runbook that lets Claude Code or
Codex drive the whole fleet from plain-language requests, picking the right
script on the right host and verifying the result. It turns the scenarios above
into one-liners.

**Setup — nothing beyond `git clone`:**
- **Claude Code** auto-discovers it as the `vpn` skill from `.claude/skills/vpn/`.
- **Codex** auto-reads `AGENTS.md` (repo root), which points at the same runbook.
- *(Optional)* surface it in Codex's native skill list:
  `ln -s "$(pwd)/.claude/skills/vpn" ~/.agents/skills/vpn`.

**Host inventory** (so you can refer to servers by alias, not IP): copy the
template and fill it in — it lives outside the repo because it holds IPs/keys:

```bash
mkdir -p ~/.config/vpn
cp .claude/skills/vpn/hosts.example.yml ~/.config/vpn/hosts.yml
$EDITOR ~/.config/vpn/hosts.yml        # alias -> ip / os / role / ssh key
```

You don't have to write it by hand. With no inventory, the assistant **creates
one** (asking one-vs-many servers, address, user, and key *or* password) or
**imports an existing/old file** if you give it a path — and it won't run any op
until an inventory exists. You can also just say *"add a host …"* at any time.
Hosts take an **IP or FQDN** and authenticate with an **SSH key (recommended) or
a password** (`sshpass`; the assistant warns and suggests `ssh-copy-id`).

**Examples** (just talk to the assistant):

| You say | It does |
|---------|---------|
| "add a host `de`, `de.example.com`, user root, key `~/.ssh/id_ed25519`" | appends the host to `~/.config/vpn/hosts.yml` (creating it if absent), offers a connectivity check |
| "deploy the VPN on `de`" | rsync/clone repo → swap check → `docker-install.sh` → `deploy.sh` → verifies containers/module, prints the ports to open |
| "deploy `de`, Xray only" | same, with `ENABLE_AMNEZIAWG=0` — no kernel module, no AWG container |
| "status of `de`" | containers, module, image versions, AWG-peer / Xray-client counts, egress IP |
| "add a login `alice` on `us`" | `add-client.sh alice`, hands you the `.conf` / VLESS link / QR |
| "I need a login that connects to `us` and exits in `de`" | asks to confirm entry/exit, sets up **Xray** chaining (`us` → `de`) and gives you the Xray profile (cross-server landing is Xray-only) |
| "route `alice` out through `de`" | `xray/add-upstream.sh` + `xray/set-route.sh alice de` |
| "send `alice` back to local exit" | `xray/set-route.sh alice direct` |
| "remove `alice` from `us`" | `remove-client.sh alice` |
| "rebuild the kernel module on `us`" | stops `amneziawg`, runs `rebuild-amneziawg.sh`, restarts |
| "tear down `us`" | confirms, then `cleanup.sh` |

Pin a component release by mentioning it (e.g. "deploy `de` with Xray v26.6.1")
— the assistant passes `XRAY_RELEASE=…` to `deploy.sh`. You stay in the loop:
the assistant confirms destructive/outward actions before running them.

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
├── AGENTS.md               # Conventions for AI assistants / contributors (single source of truth)
├── CLAUDE.md               # Imports AGENTS.md (@AGENTS.md) for Claude Code
├── .claude/skills/vpn/     # `vpn` operator skill: SKILL.md runbook + hosts.example.yml inventory template
├── docker-install.sh       # Install Docker + Compose + buildx from Ubuntu repos (24.04+, idempotent)
├── deploy.sh               # Full server bootstrap (requires Docker pre-installed)
├── add-client.sh           # Add client to both AWG + Xray
├── remove-client.sh        # Remove client from both AWG + Xray
├── rebuild-amneziawg.sh    # Rebuild and reload the AmneziaWG kernel module after a host kernel upgrade
├── mtu.sh                  # macOS helper to estimate path MTU and suggest AWG MTU
├── cleanup.sh              # Remove all containers, images, keys, and generated configs
├── docker-compose.yml.tmpl # Template; docker-compose.yml is generated and gitignored. Optional services sit between `# >>> service: x` / `# <<< service: x` markers
├── lib/
│   ├── common.sh           # Shared utilities (logging, validation, IP fetch, component selection)
│   └── versions.sh         # Resolves component release tags -> commit SHAs (git ls-remote)
├── amneziawg/
│   ├── Dockerfile          # Builds awg-tools (awg, awg-quick) from a resolved release (AWG_TOOLS_REF); the kernel module is built on the host by deploy.sh / rebuild-amneziawg.sh
│   ├── entrypoint.sh       # Verifies the host module is loaded (fail-fast, no CAP_SYS_MODULE), brings up awg0 via awg-quick
│   ├── gen-keys.sh         # Generates server keys + obfuscation params + random port (umask 077)
│   ├── add-client.sh       # Generates keypair + PSK, writes config, hot-reloads via awg syncconf
│   ├── remove-client.sh    # Removes peer (by name) and hot-reloads
│   ├── remove-peer.py      # Atomic [Peer]-block removal from awg0.conf (used by remove-client.sh)
│   └── conf/
│       └── awg0.tmpl       # Server config template incl. forward-path firewall (awg0.conf is gitignored)
├── xray/
│   ├── Dockerfile          # Multi-stage: builds Xray-core from a resolved release (XRAY_REF); geo DBs pulled latest
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

Xray REALITY makes VPN traffic look like ordinary HTTPS to a **camouflage domain** (the default is `cloudflare.com`). Unlike traditional TLS proxies, REALITY doesn't require a domain or certificate — it borrows the TLS handshake of that destination server, which makes it much harder for censorship systems to detect. On **restrictive networks that block the default camouflage SNI**, switch it to a site that network doesn't block — see [scenario 7](#7-restricted-networks--change-the-reality-camouflage-domain).

Client management requires a container restart (typically under 2 seconds). Each client is identified by a UUID and connects via the VLESS protocol with `xtls-rprx-vision` flow control.

**`minClientVer` is pinned to `""` (no minimum)** in `config.json.tmpl`. From
Xray-core **v26.7.11** the REALITY server defaults it to `26.3.27`, which
rejects client apps that embed an older Xray core (many mobile clients do) — the
handshake completes and the connection then fails, which looks like a broken
profile. Setting it explicitly keeps that upgrade from locking users out; raise
it deliberately if you ever want to force clients to update. Live `config.json`
files generated before this default was added do **not** get it from a re-deploy
(templates are never back-ported) — add the key by hand under
`inbounds[0].streamSettings.realitySettings` before upgrading Xray past
v26.7.11, then `docker compose restart xray`.

### DNS

All VPN client DNS queries are intercepted via iptables DNAT and redirected to an internal dnscrypt-proxy instance. This resolver encrypts queries via DNSCrypt or DNS-over-HTTPS to Cloudflare and Google, enforces DNSSEC validation, and requires no-logging from upstream resolvers. The DNS container is not exposed to the host — it's accessible only within the Docker network.

## Security Notes

- **Built from source, version-pinned per build** — the AmneziaWG kernel module, awg-tools, Xray-core, and dnscrypt-proxy are all compiled from source. Each deploy resolves a release tag (the latest, or a pinned `*_RELEASE` — see [Component versions](#component-versions)) down to its immutable commit **SHA** and fetches by that SHA, so a moved tag cannot silently change a build; the image tag records the deployed version. The Xray geo-databases are pulled at their latest and are intentionally not pinned. No pre-built binaries.
- **Minimal container privileges** — the AmneziaWG container holds only `CAP_NET_ADMIN`; it has no `CAP_SYS_MODULE` and no `/lib/modules` mount, so a container compromise cannot load code into the host kernel. The module is loaded on the host and persisted via `/etc/modules-load.d/`.
- **VPN-client network isolation** — forward-path rules in `awg0.tmpl` drop client→client traffic, the cloud metadata endpoint (`169.254.169.254`, `168.63.129.16`), RFC1918, and CGNAT ranges. `deploy.sh` also installs a host `INPUT` rule (persisted as `vpn-host-firewall.service`) blocking new connections from the docker subnet to the host — closing the path to host services (e.g. sshd) that the cloud firewall cannot see.
- **DNS privacy** — *all* client port-53 traffic (any destination) is forcibly DNAT'ed to the internal dnscrypt-proxy resolver; clients cannot bypass it with an external plain-DNS server. (DoH/DoT on 443/853 cannot be intercepted at this layer.)
- **Xray routing** blocks connections to private IP ranges (`geoip:private`) to prevent server-side request forgery.
- **Key isolation** — all keys are generated on the server and never transmitted. Secret-writing scripts run under `umask 077`; key files, live configs, and the `clients/` directory are `chmod 600`/`700`.
- **Firewall and SSH hardening are otherwise not automated** — beyond the host INPUT rule above, configure your cloud firewall and fail2ban separately, and lock SSH down to keys before production. Some cloud/VPS images enable password auth (via `/etc/ssh/sshd_config.d/*cloud*`) and ship a login user with a password + passwordless sudo — a brute-force path to root. After confirming key login works, add a drop-in **named to sort first** (sshd uses the *first* value it sees, so a `99-` file is overridden by `60-cloudimg-settings.conf` — use `00-`):
  ```bash
  printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' \
    'X11Forwarding no' 'PermitRootLogin prohibit-password' \
    | sudo tee /etc/ssh/sshd_config.d/00-hardening.conf
  sudo sshd -t && sudo systemctl reload ssh   # reload (not restart) keeps your session
  sudo passwd -l <login-user>                  # lock the account password; key auth is unaffected
  ```
  Verify with a **fresh** key connection before disconnecting (drop the `PermitRootLogin` line where the login user isn't root).
- Generated keys, client configs, and `docker-compose.yml` are gitignored and never committed.

## Troubleshooting

**Container won't start:**
```bash
docker compose logs <service>     # Check logs for errors
docker compose ps                 # Check container status and health
```

**AmneziaWG container restarting / won't stay up:**
```bash
lsmod | grep amneziawg                   # Module must be loaded on the HOST
docker exec vpn-amneziawg awg show           # Interface status (if the container is up)
```
If the module is missing, run scenario 3 (`rebuild-amneziawg.sh`). The container
has no `CAP_SYS_MODULE` by design and cannot load the module itself.

**Client can't connect (AWG):**
```bash
docker exec vpn-amneziawg awg show awg0      # Check if peer is listed
```

**Client can't connect (Xray):**
- Ensure port 443/tcp is open in your cloud firewall
- Verify the VLESS link matches the server's public key and Short ID

**DNS not resolving:**
```bash
docker exec vpn-dns drill @127.0.0.1 example.com   # Test internal DNS
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
- Removes the host artifacts installed by `deploy.sh`: the `INPUT` rule,
  `vpn-host-firewall.service`, and `/etc/modules-load.d/amneziawg.conf` (the
  kernel module stays loaded until the next reboot)

After cleanup, `sudo ./deploy.sh` brings everything back up from scratch.

## License

See [LICENSE](LICENSE).
