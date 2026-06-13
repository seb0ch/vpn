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

# Geo databases pinned to a release AND to a checksum recorded here in-repo.
# geoip.dat feeds the `geoip:private -> blocked` routing rule, so its integrity
# matters. The expected SHA-256 is committed (not fetched from the same mutable
# release as the payload), so a tampered/replaced release asset fails the build.
# To bump: change the tag, download the asset, and update the hash below.
ARG GEOIP_TAG=202606050359
ARG GEOIP_SHA256=a322dfb6bfd8987c83453c39582a07771c9deddf9f8f7d2d19c7927ebd5e76c8
ARG DLC_TAG=20260612151339
ARG DLC_SHA256=b0c1d450d422766f72ca63674cb166a91b555acb55469472ba544375bccce9a8
RUN mkdir -p /usr/share/xray && cd /usr/share/xray && \
    wget -qO geoip.dat https://github.com/v2fly/geoip/releases/download/${GEOIP_TAG}/geoip.dat && \
    echo "${GEOIP_SHA256}  geoip.dat" | sha256sum -c - && \
    wget -qO geosite.dat https://github.com/v2fly/domain-list-community/releases/download/${DLC_TAG}/dlc.dat && \
    echo "${DLC_SHA256}  geosite.dat" | sha256sum -c -

ENV XRAY_LOCATION_ASSET=/usr/share/xray

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
