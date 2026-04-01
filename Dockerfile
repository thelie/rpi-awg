# Stage 1: Build amneziawg-go and tools
FROM golang:1.24-alpine AS builder

RUN apk add --no-cache make gcc musl-dev linux-headers bash

# Copy local source trees (avoids git clone during build)
COPY amneziawg-go/ /src/amneziawg-go/
COPY amneziawg-tools/ /src/amneziawg-tools/

# Build amneziawg-go (userspace daemon)
RUN cd /src/amneziawg-go && make

# Build amneziawg-tools (awg, awg-quick)
RUN cd /src/amneziawg-tools/src && \
    make && \
    make install DESTDIR=/tools WITH_WGQUICK=yes

# Stage 2: Minimal runtime
FROM alpine:3.21.3

RUN apk add --no-cache \
    iptables \
    iproute2 \
    bash \
    curl \
    dnsmasq \
    ipset

# Copy built binaries
COPY --from=builder /src/amneziawg-go/amneziawg-go /usr/bin/amneziawg-go
COPY --from=builder /tools/usr/bin/awg /usr/bin/awg
COPY --from=builder /tools/usr/bin/awg-quick /usr/bin/awg-quick

# Copy scripts
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]
