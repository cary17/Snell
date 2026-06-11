ARG BASE_TAG=stable-slim
FROM debian:${BASE_TAG} AS builder

ARG TARGETARCH
ARG SNELL_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*

RUN set -ex && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386)   ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm)   ARCH="armv7l" ;; \
        *) exit 1 ;; \
    esac && \
    V_NUM="${SNELL_VERSION#v}" && \
    FILE="snell-server-v${V_NUM}-linux-${ARCH}.zip" && \
    URL="https://dl.nssurge.com/snell/${FILE}" && \
    echo "Downloading: ${URL}" && \
    if ! curl -fsSL --retry 3 --retry-delay 5 -o /tmp/s.zip "${URL}"; then \
        echo "ERROR: ${URL} not found, this platform may not be supported in this version" >&2; \
        exit 1; \
    fi && \
    unzip -q /tmp/s.zip -d /tmp/ && \
    chmod +x /tmp/snell-server

FROM debian:${BASE_TAG}

# 从 Debian 11 (bullseye) 安装 OpenSSL 1.1 和其他依赖
# Debian 12 默认只有 OpenSSL 3.0，需要从旧版本源安装 1.1
RUN echo "deb http://deb.debian.org/debian bullseye main" > /etc/apt/sources.list.d/bullseye.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libc-ares2 \
        libssl1.1 \
        libuv1 \
        libsodium23 \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* && \
    rm -f /etc/apt/sources.list.d/bullseye.list

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh && \
    chmod 777 /snell

# 验证所有依赖已满足
RUN ldd snell-server | grep "not found" && echo "Warning: Missing dependencies" || echo "All dependencies satisfied"

ENTRYPOINT ["/snell/entrypoint.sh"]
