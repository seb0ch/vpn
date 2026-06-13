# ── Stage 1: build Xray from source ──────────────────────────────────────
FROM golang:1.26-alpine AS builder

# Commit SHA resolved from a release tag by deploy.sh (XRAY_RELEASE or latest).
# Fetched by SHA so a moved tag cannot change the build. Build via deploy.sh,
# which always passes this; a bare `docker build` must supply it.
ARG XRAY_REF

RUN apk add --no-cache git make gcc musl-dev
RUN : "${XRAY_REF:?XRAY_REF build-arg is required — build through deploy.sh}" && \
    git init /src/xray && \
    git -C /src/xray remote add origin https://github.com/XTLS/Xray-core && \
    git -C /src/xray fetch --depth 1 origin ${XRAY_REF} && \
    git -C /src/xray checkout --detach FETCH_HEAD
WORKDIR /src/xray
RUN CGO_ENABLED=0 go build -o xray -trimpath -ldflags "-s -w" ./main

# ── Stage 2: runtime ─────────────────────────────────────────────────────
FROM alpine:3.23

RUN apk add --no-cache bash ca-certificates tzdata libqrencode-tools

COPY --from=builder /src/xray/xray /usr/local/bin/xray

# Geo databases: always fetch the latest upstream release. These are public
# routing data (geoip.dat feeds the `geoip:private -> blocked` rule); they are
# intentionally NOT pinned or checksummed. GEO_BUST is a per-deploy nonce passed
# by deploy.sh and referenced below so this layer is never served from cache —
# every deploy re-pulls the latest geo data. Keep this RUN last-ish so busting it
# does not invalidate the expensive Xray build above.
ARG GEO_BUST=0
RUN echo "geo cache-bust: ${GEO_BUST}" >/dev/null && \
    mkdir -p /usr/share/xray && cd /usr/share/xray && \
    wget -qO geoip.dat   https://github.com/v2fly/geoip/releases/latest/download/geoip.dat && \
    wget -qO geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat

ENV XRAY_LOCATION_ASSET=/usr/share/xray

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
