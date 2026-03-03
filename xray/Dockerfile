# ── Stage 1: build Xray from source ──────────────────────────────────────
FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git make gcc musl-dev
RUN git clone --depth 1 https://github.com/XTLS/Xray-core /src/xray
WORKDIR /src/xray
RUN CGO_ENABLED=0 go build -o xray -trimpath -ldflags "-s -w" ./main

# ── Stage 2: runtime ─────────────────────────────────────────────────────
FROM alpine:3.23

RUN apk add --no-cache bash ca-certificates tzdata libqrencode-tools

COPY --from=builder /src/xray/xray /usr/local/bin/xray

# Download geo-databases to dedicated asset directory
RUN mkdir -p /usr/share/xray && \
    wget -qO /usr/share/xray/geoip.dat   https://github.com/v2fly/geoip/releases/latest/download/geoip.dat && \
    wget -qO /usr/share/xray/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat

ENV XRAY_LOCATION_ASSET=/usr/share/xray

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
