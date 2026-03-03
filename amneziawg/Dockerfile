# ── Stage 1: build amneziawg-go ──────────────────────────────────────────
FROM golang:1.26-alpine AS builder-awg

RUN apk add --no-cache git make
RUN git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go /src/awg-go
WORKDIR /src/awg-go
RUN make

# ── Stage 2: build awg-tools ─────────────────────────────────────────────
FROM alpine:3.23 AS builder-tools

RUN apk add --no-cache git make gcc musl-dev libmnl-dev
RUN git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools /src/awg-tools
WORKDIR /src/awg-tools/src
RUN make

# ── Stage 3: runtime ─────────────────────────────────────────────────────
FROM alpine:3.23

RUN apk add --no-cache bash iproute2 iptables libqrencode-tools

COPY --from=builder-awg   /src/awg-go/amneziawg-go   /usr/local/bin/amneziawg-go
COPY --from=builder-tools /src/awg-tools/src/wg       /usr/local/bin/awg
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

