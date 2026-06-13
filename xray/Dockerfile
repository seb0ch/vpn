# ── Stage 1: build Xray from source ──────────────────────────────────────
FROM golang:1.26-alpine AS builder

# Pinned upstream (release v26.6.1); bump deliberately after review.
ARG XRAY_COMMIT=94ffd50060f1cfd5d7482ec90a23a92bdefdff68

RUN apk add --no-cache git make gcc musl-dev
RUN git init /src/xray && \
    git -C /src/xray remote add origin https://github.com/XTLS/Xray-core && \
    git -C /src/xray fetch --depth 1 origin ${XRAY_COMMIT} && \
    git -C /src/xray checkout --detach FETCH_HEAD
WORKDIR /src/xray
RUN CGO_ENABLED=0 go build -o xray -trimpath -ldflags "-s -w" ./main

# ── Stage 2: runtime ─────────────────────────────────────────────────────
FROM alpine:3.23

RUN apk add --no-cache bash ca-certificates tzdata libqrencode-tools

COPY --from=builder /src/xray/xray /usr/local/bin/xray

# Geo databases pinned to a release and checksum-verified; geoip.dat feeds
# the `geoip:private -> blocked` routing rule, so its integrity matters.
ARG GEOIP_TAG=202606050359
ARG DLC_TAG=20260612151339
RUN mkdir -p /usr/share/xray && cd /usr/share/xray && \
    wget -q https://github.com/v2fly/geoip/releases/download/${GEOIP_TAG}/geoip.dat \
            https://github.com/v2fly/geoip/releases/download/${GEOIP_TAG}/geoip.dat.sha256sum && \
    sha256sum -c geoip.dat.sha256sum && rm geoip.dat.sha256sum && \
    wget -q https://github.com/v2fly/domain-list-community/releases/download/${DLC_TAG}/dlc.dat \
            https://github.com/v2fly/domain-list-community/releases/download/${DLC_TAG}/dlc.dat.sha256sum && \
    sha256sum -c dlc.dat.sha256sum && rm dlc.dat.sha256sum && \
    mv dlc.dat geosite.dat

ENV XRAY_LOCATION_ASSET=/usr/share/xray

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
