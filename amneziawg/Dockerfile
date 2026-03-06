# ── Build awg-tools (awg, awg-quick) ──────────────────────────────────────
FROM alpine:3.23 AS builder-tools

RUN apk add --no-cache git make gcc musl-dev libmnl-dev
RUN git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools /src/awg-tools
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
