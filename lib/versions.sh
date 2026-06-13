#!/usr/bin/env bash
# lib/versions.sh — resolve third-party component versions for the build.
#
# Policy (see deploy.sh): every deploy/re-deploy resolves each component fresh.
#   - If the component's *_RELEASE env var is set, use that tag.
#   - Otherwise, use the latest non-prerelease release tag from upstream.
#
# Resolution is done with plain git (`git ls-remote`) — no GitHub API token and
# no `jq` dependency. A resolved tag is always pinned down to its immutable
# commit SHA; the image is *tagged* with the human-readable release, but the
# source is *fetched* by SHA, so a moved tag cannot silently change a build.
# The deployed version is always visible afterwards as the image tag
# (e.g. `xray:v26.6.1`), so no separate lock file is kept.
#
# Source this file; do not execute it directly.

# ── Upstream repositories ──────────────────────────────────────────────────────
# These are consumed by the scripts that source this file (deploy.sh,
# rebuild-amneziawg.sh); shellcheck can't see that cross-file use.
# shellcheck disable=SC2034
readonly REPO_AWG_KMOD="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module"
# shellcheck disable=SC2034
readonly REPO_AWG_TOOLS="https://github.com/amnezia-vpn/amneziawg-tools"
# shellcheck disable=SC2034
readonly REPO_XRAY="https://github.com/XTLS/Xray-core"
# shellcheck disable=SC2034
readonly REPO_DNSCRYPT="https://github.com/DNSCrypt/dnscrypt-proxy.git"

# ── Tag resolution (plain git) ─────────────────────────────────────────────────

# latest_tag <repo> — print the newest non-prerelease tag, or nothing + return 1.
# Sorts tags by version descending and drops -rc/-alpha/-beta/-pre/-dev/-test.
latest_tag() {
  local repo="$1" tag
  tag="$(git ls-remote --tags --refs --sort=-v:refname "${repo}" 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | grep -viE -- '-(rc|alpha|beta|pre|dev|test|snapshot)' \
    | head -n1)"
  [[ -n "${tag}" ]] || return 1
  printf '%s' "${tag}"
}

# tag_to_sha <repo> <tag> — resolve a tag to its commit SHA (peeled for
# annotated tags), or nothing + return 1.
tag_to_sha() {
  local repo="$1" tag="$2" sha
  sha="$(git ls-remote "${repo}" "refs/tags/${tag}^{}" 2>/dev/null | awk '{print $1}' | head -n1)"
  [[ -z "${sha}" ]] && sha="$(git ls-remote "${repo}" "refs/tags/${tag}" 2>/dev/null | awk '{print $1}' | head -n1)"
  [[ -n "${sha}" ]] || return 1
  printf '%s' "${sha}"
}

# valid_docker_tag <tag> — return 0 iff the tag is a legal Docker image tag
# (first char alnum/underscore, then alnum/_/./-, max 128). This also guarantees
# the tag is safe to use as a `sed` replacement (no `/` or metacharacters).
valid_docker_tag() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
}

# resolve_ref <repo> <env_value>
#   Prints "<tag>\t<sha>": the env tag if set, else the latest upstream tag,
#   pinned to its commit SHA. Returns 1 if the tag or SHA cannot be resolved,
#   or if the tag is not a legal/safe Docker image tag.
resolve_ref() {
  local repo="$1" env_val="$2" tag sha
  if [[ -n "${env_val}" ]]; then
    tag="${env_val}"
  else
    tag="$(latest_tag "${repo}")" || return 1
  fi
  valid_docker_tag "${tag}" || return 1
  sha="$(tag_to_sha "${repo}" "${tag}")" || return 1
  printf '%s\t%s' "${tag}" "${sha}"
}
