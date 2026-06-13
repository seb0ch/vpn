FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git

# Commit SHA resolved from a release tag by deploy.sh (DNSCRYPT_RELEASE /
# latest). Fetched by SHA so a moved tag cannot change the build.
ARG DNSCRYPT_REF

WORKDIR /src
RUN : "${DNSCRYPT_REF:?DNSCRYPT_REF build-arg is required — build through deploy.sh}" && \
    git init . && \
    git remote add origin https://github.com/DNSCrypt/dnscrypt-proxy.git && \
    git fetch --depth 1 origin ${DNSCRYPT_REF} && \
    git checkout --detach FETCH_HEAD

WORKDIR /src/dnscrypt-proxy
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -trimpath -o /dnscrypt-proxy .

FROM alpine:3.23

RUN apk add --no-cache ca-certificates drill \
 && mkdir -p /var/cache/dnscrypt-proxy

COPY --from=builder /dnscrypt-proxy /usr/local/bin/dnscrypt-proxy
COPY dnscrypt-proxy.toml /etc/dnscrypt-proxy/dnscrypt-proxy.toml

EXPOSE 53/udp 53/tcp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=30s \
    CMD drill @127.0.0.1 cloudflare.com || exit 1

CMD ["dnscrypt-proxy", "-config", "/etc/dnscrypt-proxy/dnscrypt-proxy.toml"]
