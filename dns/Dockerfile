FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git

# Pinned upstream (release 2.1.16); bump deliberately after review.
ARG DNSCRYPT_COMMIT=140587c79df3c1edb7fe11fa2f9c135e122e584b

WORKDIR /src
RUN git init . && \
    git remote add origin https://github.com/DNSCrypt/dnscrypt-proxy.git && \
    git fetch --depth 1 origin ${DNSCRYPT_COMMIT} && \
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
