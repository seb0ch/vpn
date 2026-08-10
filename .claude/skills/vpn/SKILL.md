---
name: vpn
description: >-
  Operate the self-hosted AmneziaWG + Xray REALITY + dnscrypt-proxy VPN fleet:
  deploy/redeploy a server, check status, add/remove a client (login), route a
  client out through another server (Xray cross-server landing), tear down, and
  rebuild the kernel module. Use whenever the user asks to deploy a VPN server,
  add or remove a VPN login/client, make a client land/exit through another
  server, or check VPN host health. Works in Claude Code and Codex.
---

# VPN fleet operator

You operate the VPN stack in this repo (`AmneziaWG` + `Xray REALITY` +
`dnscrypt-proxy`, Docker Compose) across one or more remote Ubuntu hosts over
SSH. You translate a plain request ("deploy fra", "add login alice on us",
"alice should land in de") into the right repo scripts on the right host, then
**verify**.

## Golden rules

1. **Verify after every mutating op.** A command exiting 0 is not proof — check
   containers are healthy, the module is loaded, the peer/client exists.
2. **Confirm outward/destructive actions** before running them (deploy to a new
   host, cleanup/teardown, removing a client). Read-only status never needs it.
3. **Container names are `vpn-amneziawg` / `vpn-xray` / `vpn-dns`.** Compose
   service names are `amneziawg` / `xray` / `dns` (use these with
   `docker compose ...`). Images are tagged with their release (`xray:<ver>`),
   never `:latest`.
4. **A host may deploy only one VPN component.** `ENABLE_AMNEZIAWG=0` /
   `ENABLE_XRAY=0` at deploy time drop that component. **`dns` follows
   AmneziaWG** (only AWG clients are DNAT'ed to it), so an Xray-only host runs
   exactly one container, `vpn-xray`. Check what a host actually runs before
   acting on it — the generated `/usr/src/vpn/docker-compose.yml` lists the
   deployed services (a missing `vpn-amneziawg`/`vpn-dns` on an Xray-only host
   is **correct**, not a fault).
5. **Cross-server per-client landing is Xray-only.** "Client connects to A but
   lands in B" works via Xray chaining. The equivalent for AmneziaWG (multi-hop)
   is **not implemented** — never promise it. An AWG profile always exits at the
   server the client connects to.
6. Never commit or print secrets (keys, `hosts.yml`). Client configs/QRs live in
   `clients/` on each host (gitignored).

## Host inventory

Inventory lives at **`~/.config/vpn/hosts.yml`** (outside the repo — it holds
addresses/keys/passwords). **The skill cannot operate without it** — there are no
hosts to act on. Schema (see `hosts.example.yml` in this skill dir):

```yaml
defaults:
  ssh_user: root
  ssh_key: ~/.ssh/id_ed25519        # default auth; a host may override
hosts:
  us:
    host: 1.2.3.4                   # IP or FQDN (e.g. us.vpn.example.com)
    os: ubuntu-26.04
    roles: [entry]
    # auth — exactly one of ssh_key / ssh_password (key strongly preferred):
    ssh_key: ~/.ssh/id_ed25519_us   # optional per-host override
    # ssh_password: "s3cret"        # plaintext — discouraged; needs `sshpass`
    # ssh_user: root                # optional override
    # port: 22                      # optional override
  de:
    host: de.vpn.example.com
    os: ubuntu-24.04
    roles: [exit]
```

You read this file yourself and resolve an alias → host/user/port/auth. A
`<host>` argument may be an alias from the inventory or a literal `user@host`.
Keep the file `chmod 600`.

### When the inventory is missing

If `~/.config/vpn/hosts.yml` does not exist, **do not guess and do not proceed**.
Tell the user it's required, then offer the two ways to get one:

1. **Import an existing/old inventory** — ask for its path; validate it parses as
   the schema above; `mkdir -p ~/.config/vpn`, copy it to
   `~/.config/vpn/hosts.yml`, `chmod 600`.
2. **Create a fresh one** — ask:
   - **One server or many?** (if **many**, note up front: *cross-server
     per-client landing is Xray-only — AmneziaWG multi-hop is not implemented*).
   - For each host: alias, **IP or FQDN**, SSH user, and **auth — key path or
     password** (recommend a key; if password, note `sshpass` is needed and
     suggest `ssh-copy-id` to move to a key later), OS, role (entry/exit/both).

   Write `~/.config/vpn/hosts.yml` from the schema (`mkdir -p ~/.config/vpn`
   first), `chmod 600`, then continue.

### add-host (user: "add a host …")

Collect: alias (unique), IP **or** FQDN, SSH user, auth (**key path or
password**), and optionally OS / role / port. Then:

1. If the inventory is missing, run the "missing" flow above first.
2. Reject a duplicate alias (offer to update it instead).
3. Append/merge the host entry into `~/.config/vpn/hosts.yml` (preserve existing
   entries and formatting), keep `chmod 600`.
4. If a password was given, warn it is stored in plaintext and recommend
   switching to a key (`ssh-copy-id -i <key> <user>@<host>`).
5. Offer a connectivity check: `<SSH> 'echo ok; . /etc/os-release; echo $PRETTY_NAME'`.

## Getting the repo onto a host

Operations run the repo's scripts on the host at `/usr/src/vpn`.

**Default — git** (deploys a committed ref → reproducible/auditable). The files
`deploy.sh` writes *inside the repo* (keys, configs, `docker-compose.yml`) are
all gitignored, so they stay untracked and `git pull`/`checkout` never touch
them — no fragile exclude list needed. (deploy.sh also writes host-level
artifacts *outside* the repo — `/etc/modules-load.d/amneziawg.conf`, the
`vpn-host-firewall.service`, the `.ko` in `/lib/modules` — those are unrelated to
the git checkout.) `git` is required on the host anyway (`lib/versions.sh` and
the Dockerfiles use it).

```bash
# fresh host
$SSH "git clone https://github.com/seb0ch/vpn /usr/src/vpn"
$SSH "cd /usr/src/vpn && git checkout <tag>"          # optional: pin a release tag

# redeploy to latest main (untracked secrets/configs preserved)
$SSH "cd /usr/src/vpn && git fetch --all --tags && git checkout main && git pull --ff-only"
# …or redeploy to a specific tag (detached HEAD; no pull needed)
$SSH "cd /usr/src/vpn && git fetch --all --tags && git checkout <tag>"
```

**Testing fallback — rsync.** Use ONLY to try *uncommitted local changes* on a
throwaway/test host during development. **Never rsync to a real/production host —
always use git there.** The excludes keep host secrets/configs intact (drop them
on a brand-new host — nothing to preserve):

```bash
# $RSYNC_E is the resolved ssh transport (key or password, incl. -p <port>) —
# see Operations → "Resolve <host>" below.
rsync -az --exclude='.git' --exclude='docs' --exclude='.claude' \
  --exclude='clients' --exclude='*.png' \
  --exclude='docker-compose.yml' --exclude='*/conf/*.key' \
  --exclude='*/conf/*.conf' --exclude='*/conf/config.json' \
  --exclude='*/conf/reality_keys.txt' \
  -e "$RSYNC_E" ./ <user>@<host>:/usr/src/vpn/
```

## Operations

Resolve `<host>` from the inventory to its `host`/`user`/`port`/auth for every
SSH / rsync / scp call. `<port>` defaults to 22. Build the command from the auth
type. Note `ssh`/`rsync` take a lowercase `-p <port>` but **`scp` uses uppercase
`-P <port>`**.

**Key auth:**
```bash
SSH="ssh -i <key> -p <port> -o BatchMode=yes -o ConnectTimeout=12 <user>@<host>"
RSYNC_E="ssh -i <key> -p <port> -o BatchMode=yes"      # rsync -e "$RSYNC_E"
SCP="scp -i <key> -P <port> -o BatchMode=yes"          # scp -P, not -p
```

**Password auth** (needs `sshpass` locally). Do **not** use `sshpass -p '<pw>'`
— the password then shows up in `ps`/argv to any local user. Pass it via a
mode-600 temp file with `-f` instead, and never `BatchMode=yes`:
```bash
PF=$(mktemp); chmod 600 "$PF"; printf '%s' '<password>' > "$PF"
trap 'rm -f "$PF"' EXIT
SSH="sshpass -f $PF ssh -p <port> -o ConnectTimeout=12 <user>@<host>"
RSYNC_E="sshpass -f $PF ssh -p <port>"                 # rsync -e "$RSYNC_E"
SCP="sshpass -f $PF scp -P <port>"
```

Never echo the password (or the temp-file contents) back to the user. Prefer
keys; offer `ssh-copy-id` to migrate a password host to a key.

### deploy / redeploy `<host>` [RELEASE pins]

1. Probe: `$SSH '. /etc/os-release; echo $PRETTY_NAME; free -m | awk "/Mem|Swap/"; command -v docker || echo NO-DOCKER'`.
2. **Swap prereq**: if total RAM < ~1.5 GB and swap is 0, add swap *before*
   deploy (the from-source Xray/gVisor build OOMs otherwise):
   `$SSH 'fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo "/swapfile none swap sw 0 0" >> /etc/fstab'`.
3. Get the repo onto the host (above — `git clone`/`git pull`; rsync only for
   uncommitted local changes).
4. If no docker: `$SSH 'cd /usr/src/vpn && ./docker-install.sh'` (installs
   `docker.io`/`docker-compose-v2`/`docker-buildx` from Ubuntu's own repos).
5. Deploy: `$SSH 'cd /usr/src/vpn && ./deploy.sh'`. To pin versions, prefix env
   vars: `XRAY_RELEASE=v26.6.1 AMNEZIAWG_RELEASE=... DNSCRYPT_RELEASE=... ./deploy.sh`.
   Default (no pins) = latest upstream release of each.
   **Single-protocol host**: prefix `ENABLE_AMNEZIAWG=0` (Xray only) or
   `ENABLE_XRAY=0` (AmneziaWG only). Both `0` is refused. Ask the user which
   protocols they want if they say "only VLESS/Xray" or "no WireGuard".
6. **Verify** (run `status` below). Report the printed firewall ports (AWG UDP +
   443/tcp — only the enabled ones are printed) the user must open in their
   cloud firewall.

A redeploy is idempotent: keys/clients are preserved, images rebuilt at the
resolved release. The kernel module is NOT rebuilt if already loaded — use
`rebuild-module` for that. Re-deploying with a changed `ENABLE_*` flag adds or
drops that component (a disabled one loses its container and, for AmneziaWG, its
boot-time module units; keys/clients stay on disk).

### status `<host>`

```bash
$SSH 'docker ps --format "{{.Names}} | {{.Image}} | {{.Status}}";
      echo -n "deployed: "; grep -E "^  (amneziawg|xray|dns):$" /usr/src/vpn/docker-compose.yml | tr -d " :" | tr "\n" " "; echo;
      echo -n "module: "; grep -q "^amneziawg " /proc/modules && echo LOADED || echo NOT-LOADED;
      echo -n "awg peers: "; docker exec vpn-amneziawg awg show awg0 peers 2>/dev/null | wc -l;
      echo -n "xray clients: "; docker exec vpn-xray grep -c "\"email\"" /etc/xray/config.json 2>/dev/null;
      echo -n "egress IP: "; curl -s --max-time 8 https://api.ipify.org; echo'
```

Healthy = **every deployed** `vpn-*` container `Up ... (healthy)`. Read the
`deployed:` line first: an Xray-only host has no `vpn-amneziawg` and no
`vpn-dns`, and needs no module (module NOT-LOADED is fine there, and `awg peers`
reads 0); an AmneziaWG-only host has no `vpn-xray`. Image tags show the deployed component
versions. `awg peers` / `xray clients` count the AmneziaWG peers and Xray clients
respectively (use them to confirm a client was added/removed on each side).

### add-client / login `<name> <host>` [proto]

```bash
$SSH "cd /usr/src/vpn && ./add-client.sh <name>"          # every deployed component
# proto-specific: ./amneziawg/add-client.sh <name>  OR  ./xray/add-client.sh <name>
```

The wrapper reads `docker-compose.yml` and only touches components this host
deploys — on an Xray-only host it produces just the VLESS profile (that is
expected; don't "fix" the missing `.conf` by running the AWG script).

**What to hand the user** — fetch the files and deliver per protocol. The QR
images are the easy path for phones (scan in the app); the file/link are for
desktop or manual import:

```bash
# $SCP is the resolved scp (key or password; note scp uses -P for the port) —
# see Operations → "Resolve <host>".
$SCP '<user>@<host>:/usr/src/vpn/clients/<name>_*' .
```

| Protocol | Files | Give the user |
|----------|-------|---------------|
| **AmneziaWG** | `<name>_amneziawg.conf` + `<name>_amneziawg.png` | the **`.conf`** to import (desktop/app), or the **QR PNG** to scan with the AmneziaWG **mobile** app |
| **Xray (VLESS)** | `<name>_xray.vless` + `<name>_xray.png` | the **`vless://…` link** to paste, or the **QR PNG** to scan with the v2box/etc. **mobile** app |

These are bearer credentials (anyone with them is the user) — send over a secure
channel, don't paste into logs/chat history. Verify via `status`: the `awg peers`
and `xray clients` counts should reflect the new client (or only the relevant one
if you used a proto-specific script).

### Login flow ("I need a login")

When the user wants a login but hasn't specified topology, ask two things:

1. **Which server do they connect to?** (entry)
2. **Which server should they exit/land on?** (landing)

- **entry == landing** → just `add-client <name> <entry>`. They connect and exit
  on the same server (AWG + Xray both work).
- **entry != landing** → **Xray chaining only** (state this: the AWG profile
  cannot cross servers). First create the client on the entry
  (`add-client <name> <entry>`), then do the *chain* op below; hand the user the
  **Xray** profile (`<name>_xray.vless`), which lands at the exit. Their AWG
  profile from the entry still exits at the entry.

### chain — client connects to A, lands in B (Xray)

The end client must already exist on **A** (run `add-client <client> <A>`
first — `set-route.sh` errors if the client/email is unknown). Then:

1. On **B (exit)**, register A as a **Xray-only** uplink client and grab its
   link. Use `xray/add-client.sh` (NOT the top-level wrapper) so no needless AWG
   peer is created on the exit:
   ```bash
   $SSH_B "cd /usr/src/vpn && ./xray/add-client.sh <A>-uplink"
   $SSH_B "cat /usr/src/vpn/clients/<A>-uplink_xray.vless"
   ```
2. On **A (entry)**, register B as an upstream outbound and route the client:
   ```bash
   $SSH_A "cd /usr/src/vpn && ./xray/add-upstream.sh <Btag> '<vless link from step 1>'"
   $SSH_A "cd /usr/src/vpn && ./xray/set-route.sh <client> <Btag>"
   ```
   `<Btag>` is a free alias for the exit (e.g. the exit's name). **Single-quote
   the VLESS URL** (it has `&`/`?`).
3. Verify (non-destructive) on A — the client now has a routing rule to
   `<Btag>`: dump the routing rules and read them
   `$SSH_A "docker exec vpn-xray cat /etc/xray/config.json"` (find the rule whose
   `user` contains `<client>` and whose `outboundTag` is `<Btag>`). The real
   proof is to test the client's egress IP and confirm it is B's.

To re-route an existing client: `$SSH_A "cd /usr/src/vpn && ./xray/set-route.sh <client> <Btag>"`.
To send a client back to local exit (this **removes** its upstream rule — a
mutation, not a check): `./xray/set-route.sh <client> direct`.

DNS note: Xray clients resolve via Xray's configured public resolvers (`1.1.1.1`
/ `8.8.8.8` in `config.json`), not the in-network dnscrypt, and those queries
follow the same outbound — so they exit at B too. (The forced in-network dnscrypt
applies only to AmneziaWG clients.)

### remove-client `<name> <host>`

`$SSH "cd /usr/src/vpn && ./remove-client.sh <name>"` (AWG hot-reloaded, Xray
restarted; halves run independently). Verify the peer/client is gone.

### cleanup / teardown `<host>` (destructive — confirm first)

`$SSH "cd /usr/src/vpn && echo yes | ./cleanup.sh"` — removes `vpn-*`
containers, every image tag, generated configs/keys/clients, and host artifacts
(firewall service + INPUT rule + modules-load). The module stays loaded until
reboot.

### rebuild-module `<host>` (after a kernel upgrade, or to bump the AWG module)

```bash
$SSH "cd /usr/src/vpn && docker compose stop amneziawg && ./rebuild-amneziawg.sh && docker compose start amneziawg"
```
`AMNEZIAWG_RELEASE=<tag>` may prefix it to pin the module release.

## REALITY camouflage (dest / SNI) on restricted networks

REALITY borrows the TLS handshake of a **camouflage domain**; the client sends
that domain as its SNI. The repo default is `cloudflare.com`
(`xray/conf/config.json.tmpl`). On some **restrictive networks the default SNI
is blocked**, so a client there cannot connect — this applies both to a direct
client and to an **uplink** used for a chain (the uplink is just a client that
one server logs into another with). What matters is the network the connection
is made **from**: pick the camouflage for that network.

**Symptom of an SNI block:** TCP to `:443` connects, but the TLS handshake gets
**0 bytes back / times out**, while ordinary HTTPS from the same client host
still works. That's SNI-based filtering, not a routing/IP fault (a *closed* port
refuses fast; a *blocked* SNI hangs).

**Pick a camouflage domain that** (a) is **not blocked** from the client's
network, (b) supports **TLS 1.3 and HTTP/2**, (c) isn't fronted by a CDN you'd
rather avoid — ideally a big, boring site popular in the server's own region.

**Diagnose without changing anything** (run from the client's host, targeting
the server IP):
```bash
# rc 28 = blocked (silent drop / hang); 0 = clean pass; 35/60 = a TLS reply came
# back (NOT the hang) — normally a pass (a cert mismatch is expected when the SNI
# != the server's serverNames), but active interference can also land here — confirm.
curl -s -o /dev/null -w '%{exitcode}\n' --max-time 8 --resolve <sni>:443:<server-ip> https://<sni>/
# can the server serve that handshake? want TLSv1.3 + ALPN h2
$SSH_SERVER "openssl s_client -connect <sni>:443 -servername <sni> -alpn h2 -tls1_3 </dev/null 2>/dev/null | grep -E 'Protocol|ALPN'"
```
A whole server IP can also be blocked at the **TCP layer regardless of SNI** —
test a non-TLS port too (e.g. `:22`): if even that hangs from the client network
but works from elsewhere, the IP itself is filtered and no SNI helps — use a
different address.

**Change the camouflage** (dest is not an env var):
- *Before first deploy* — edit `dest` + `serverNames` in
  `xray/conf/config.json.tmpl` so the default never appears on the wire.
- *On a live host* — in `xray/conf/config.json`, under
  `inbounds[0].streamSettings.realitySettings`, set `dest` to `"<sni>:443"` (host
  **and** port) and `serverNames` to `["<sni>"]` (host only); then
  `docker compose restart xray`, then **reissue client profiles**: only the
  `sni=` in each `<name>_xray.vless` changes (UUID/keys are unchanged), so
  regenerate the link + QR. A client's SNI must match the server's `serverNames`.

## Verify egress (proof a client/chain actually works)

Config rules only prove intent; the real proof is the **egress IP**. Spin a
throwaway Xray client from the client's `.vless` on a **deployed host** (it needs
the local `xray:<ver>` image) and check the IP it exits from (build `/tmp/cli.json`
= a `socks` inbound + a `vless`/`reality` outbound parsed from the link —
id/host/port/pbk/sid/sni):
```bash
CID=$($SSH_ONHOST "docker run -d --rm --network host -v /tmp/cli.json:/c.json --entrypoint xray xray:<ver> run -c /c.json")
$SSH_ONHOST "sleep 5; curl -s --max-time 15 --socks5-hostname 127.0.0.1:<port> https://api.ipify.org; echo; docker stop $CID >/dev/null"
```
The IP returned must equal the expected exit. For a chain, run it from the entry
host — the IP must be the **exit's**, not the entry's.

## Harden a host for production (key-only SSH)

Some VPS/cloud images enable SSH **password** auth (via
`/etc/ssh/sshd_config.d/50-cloud-init.conf` / `60-cloudimg-settings.conf`) and
ship a login user (or root) with a usable password and passwordless sudo — a
brute-force path to root (check yours: `sshd -T | grep -i passwordauth`,
`passwd -S <user>`). For production, go key-only. **Confirm key login works
first**, then:
```bash
# name it 00- so it sorts BEFORE the cloud-init drop-ins: sshd uses the FIRST
# value seen, so a 99- file would be overridden by 60-cloudimg-settings.conf.
$SSH 'printf "%s\n" "PasswordAuthentication no" "KbdInteractiveAuthentication no" \
  "X11Forwarding no" "PermitRootLogin prohibit-password" \
  > /etc/ssh/sshd_config.d/00-hardening.conf && sshd -t && systemctl reload ssh'
$SSH 'passwd -l <login-user>'      # lock the account password (key auth unaffected)
```
`reload` (not `restart`) keeps your current session; **verify with a fresh key
connection before disconnecting**. Drop `PermitRootLogin prohibit-password` on
hosts whose login user isn't root. Locking the password does not break `sudo`
(a `NOPASSWD` sudoers rule is independent of it).

## Gotchas

- **Host-key churn**: reprovisioned hosts present a new key → SSH/rsync fails
  with "REMOTE HOST IDENTIFICATION HAS CHANGED". Fix: `ssh-keygen -R <ip>` then
  reconnect with `-o StrictHostKeyChecking=accept-new`. (Only do this for hosts
  you control and expect to have been rebuilt.)
- **Swap** (see deploy step 2) — the #1 fresh-host failure.
- **Versions**: every deploy resolves env-or-latest and tags images with the
  release; the running version is visible via `docker images` / the `status` op.
  There is no lock file and no `--refresh`.
- **AWG multi-hop** is a deferred feature — cross-server landing is Xray-only.
- **Single-protocol hosts**: before reporting a host as broken, check which
  services its `docker-compose.yml` declares — a deploy with `ENABLE_AMNEZIAWG=0`
  legitimately has no `vpn-amneziawg`, no `vpn-dns`, no kernel module, and no
  `amneziawg-module.service`. Turning a component back on is a plain re-deploy
  with the flag at `1`; the old keys/clients come back with it.
- **git / docker compose may be missing** on a fresh host. Install `git`
  (`apt-get install -y git`) before `git clone`. If Docker is present but
  `docker compose version` fails, run `./docker-install.sh` — it adds the compose
  **and** buildx plugins (deploy needs both; a bare `docker.io` lacks them).
- **Very low RAM**: under ~1 GB the from-source build is painfully slow and can
  OOM even with swap. Add ≥2 GB swap and expect long builds; sub-512 MB hosts are
  impractical. (Watch the build; `sleep`-poll the log rather than hammering SSH,
  which competes for the host's scarce memory.)
- **Non-root hosts**: prefix scripts and `docker` with `sudo`; client files are
  created `root:root 600`, so fetch them with `sudo cat` / `sudo base64` — a plain
  `scp` as the login user can't read them.
- **Pending kernel before first deploy**: fresh hosts often have a newer kernel
  installed awaiting reboot (`/var/run/reboot-required`). Decide up front — reboot
  into it *before* deploy (the module is then built for the kernel you'll keep),
  else a later reboot needs `rebuild-module`. Ensure `linux-headers-$(uname -r)`
  for the **new** kernel are installed before rebooting.
- **Inventory ≠ `~/.ssh/config`**: resolve the host from `hosts.yml` and build an
  explicit `ssh -i <key> <user>@<ip>`; a stale ssh-config alias may point at an
  old IP.
- **Restricted-network SNI**: if a client/uplink can't connect but the host is
  healthy, suspect a blocked camouflage SNI — see **REALITY camouflage** above.

## Claude Code & Codex

Works in both with **no setup beyond `git clone`**:
- **Claude Code** auto-discovers this as the `vpn` skill from `.claude/skills/vpn/`.
- **Codex** auto-reads `AGENTS.md` at the repo root, which points here, so it
  follows this runbook without any install step.

Optional only — to also surface it in Codex's *native* skill list:
`ln -s "$(pwd)/.claude/skills/vpn" ~/.agents/skills/vpn` (run from the repo root,
then restart Codex). Not required. All operations are plain shell, so they
execute identically whichever assistant runs them.
