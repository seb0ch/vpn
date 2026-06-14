# Agent & contributor guide

Conventions for any assistant (Claude Code, Codex, …) or human working in this
repo. Read together with `README.md` (user docs) and the `vpn` skill
(`.claude/skills/vpn/SKILL.md`, the operational runbook).

## What this is

A self-hosted VPN stack — **AmneziaWG** (obfuscated WireGuard, host kernel
module) + **Xray REALITY** (VLESS) + **dnscrypt-proxy**, orchestrated with
Docker Compose, deployed by `deploy.sh` onto Ubuntu hosts. Everything is built
from source. See `README.md` for the architecture and operational scenarios.

## Operating the fleet

The operational runbook is **`.claude/skills/vpn/SKILL.md`** — read and follow
it to deploy, add/remove a client, check status, or chain a client through
another server; don't hand-roll the SSH/script calls. No setup beyond `git
clone`:
- **Claude Code** auto-discovers it as the `vpn` skill from `.claude/skills/vpn/`.
- **Codex** auto-reads this `AGENTS.md` on clone — just open and follow that
  `SKILL.md`. (Optional: `ln -s "$(pwd)/.claude/skills/vpn" ~/.agents/skills/vpn`
  to also surface it in Codex's native skill list — not required.)

## Code conventions

- **Built from source, no pre-built binaries.** Each third-party component is
  resolved per-deploy to a release tag (its `*_RELEASE` env var or the latest
  upstream), pinned to a commit **SHA**, and fetched by SHA. Images are tagged
  with the release (`xray:<ver>`, never `:latest`). There is no lock file and no
  `--refresh`; the deployed version is visible via the image tag. Resolution
  logic is `lib/versions.sh`.
- The Xray **geo databases are intentionally unpinned / unchecksummed** (always
  latest). This is a deliberate decision — do not "fix" it by adding pins.
- **AmneziaWG multi-hop is not implemented.** Cross-server per-client landing
  ("connect A, exit B") is **Xray-only** (`xray/add-upstream.sh` +
  `xray/set-route.sh`). An AWG profile always exits at the server the client
  connects to.
- Executable shell scripts: `#!/usr/bin/env bash` + `set -euo pipefail`. Sourced
  libraries (`lib/*.sh`) are not executed directly so they omit `set`, but all
  shell must pass `shellcheck` clean — apart from a few justified inline
  `# shellcheck disable=` directives (SC1091 on `source`; SC2034 for constants in
  `lib/versions.sh` consumed by the scripts that source it; SC2012 in
  `rebuild-amneziawg.sh`).
- Containers are named `vpn-amneziawg` / `vpn-xray` / `vpn-dns`; Compose service
  names are `amneziawg` / `xray` / `dns`. Use `docker exec vpn-<svc>` and
  `docker compose ... <service>` accordingly.
- The kernel-module loaded check reads `/proc/modules`, never `lsmod | grep -q`
  (the latter false-negatives under `set -o pipefail` via SIGPIPE).
- Secrets (keys, generated configs, `docker-compose.yml`, client files) are
  gitignored; only templates (`*.tmpl`, `*.example.*`) are committed.

## Workflow

- **Test changes on real hosts** before release — freshly provisioned Ubuntu
  **24.04 and 26.04** (deploy + add-client + re-deploy + cleanup).
- Run a **strict Codex review** of substantial changes before committing/release.
- Commit messages and PRs: **no AI-attribution trailers** (no `Co-Authored-By`,
  no "Generated with …"). All written artifacts (code, docs, commits) in English.
- **Release**: ff-merge to `main`, annotated tag `vX.Y.Z`, push, then
  `gh release create`.

## Layout

- `deploy.sh`, `docker-install.sh`, `cleanup.sh`, `rebuild-amneziawg.sh` — host ops.
- `add-client.sh` / `remove-client.sh` — top-level wrappers over per-service scripts.
- `amneziawg/`, `xray/`, `dns/` — per-service Dockerfiles, entrypoints, scripts, templates.
- `lib/common.sh` (helpers), `lib/versions.sh` (release resolution).
