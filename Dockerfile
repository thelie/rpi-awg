# Stage 1: Build amneziawg-go and tools
FROM golang:1.24-alpine AS builder

RUN apk add --no-cache git make gcc musl-dev linux-headers bash

# Pin to specific commits for reproducible builds
ARG AWG_GO_COMMIT=e7ef4339e718641fc7bc1b0ea41b538108de77cc
ARG AWG_TOOLS_COMMIT=5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079

# Build amneziawg-go (userspace daemon)
RUN git clone https://github.com/amnezia-vpn/amneziawg-go.git /src/amneziawg-go && \
    cd /src/amneziawg-go && \
    git checkout ${AWG_GO_COMMIT} && \
    make

# Build amneziawg-tools (awg, awg-quick)
RUN git clone https://github.com/amnezia-vpn/amneziawg-tools.git /src/amneziawg-tools && \
    cd /src/amneziawg-tools && \
    git checkout ${AWG_TOOLS_COMMIT} && \
    cd src && \
    make && \
    make install DESTDIR=/tools WITH_WGQUICK=yes

# Stage 2: Minimal runtime
FROM alpine:3.21

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
