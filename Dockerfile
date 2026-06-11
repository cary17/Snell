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

# 安装所有必要的运行时依赖
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcares2 \
    libssl1.1 \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# Debian stable-slim 可能没有 libssl1.1，从 Debian 旧版本源安装
# 如果上面的安装失败，使用下面的备选方案
RUN if ! dpkg -l | grep -q libssl1.1; then \
        echo "deb http://deb.debian.org/debian bullseye main" >> /etc/apt/sources.list.d/bullseye.list && \
        apt-get update && \
        apt-get install -y --no-install-recommends libssl1.1 && \
        rm -rf /var/lib/apt/lists/* /var/cache/apt/* && \
        rm -f /etc/apt/sources.list.d/bullseye.list; \
    fi

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh && \
    chmod 777 /snell

# 如果需要，可以创建符号链接确保库可用
RUN ldconfig 2>/dev/null || true

ENTRYPOINT ["/snell/entrypoint.sh"]
