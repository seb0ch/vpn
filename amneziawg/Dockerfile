# ── Build awg-tools (awg, awg-quick) ──────────────────────────────────────
FROM alpine:3.23 AS builder-tools

# Commit SHA resolved from a release tag by deploy.sh (AMNEZIAWG_RELEASE or the
# tools' latest). Fetched by SHA so a moved tag cannot change the build.
ARG AWG_TOOLS_REF

RUN apk add --no-cache git make gcc musl-dev libmnl-dev
RUN : "${AWG_TOOLS_REF:?AWG_TOOLS_REF build-arg is required — build through deploy.sh}" && \
    git init /src/awg-tools && \
    git -C /src/awg-tools remote add origin https://github.com/amnezia-vpn/amneziawg-tools && \
    git -C /src/awg-tools fetch --depth 1 origin ${AWG_TOOLS_REF} && \
    git -C /src/awg-tools checkout --detach FETCH_HEAD
WORKDIR /src/awg-tools/src
RUN make

# ── Runtime ───────────────────────────────────────────────────────────────
# Expects the amneziawg kernel module to be loaded on the host.
# The container uses awg-quick to configure the kernel interface.
FROM alpine:3.23

RUN apk add --no-cache bash iproute2 iptables libqrencode-tools kmod

COPY --from=builder-tools /src/awg-tools/src/wg              /usr/local/bin/awg
COPY --from=builder-tools /src/awg-tools/src/wg-quick/linux.bash /usr/local/bin/awg-quick
RUN ln -s awg /usr/local/bin/wg
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
