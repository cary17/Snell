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

# 检测版本并准备标记文件
FROM debian:${BASE_TAG} AS version-detector
COPY --from=builder /tmp/snell-server /tmp/snell-server
RUN chmod +x /tmp/snell-server && \
    VERSION=$(/tmp/snell-server -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1) && \
    MAJOR_VERSION=$(echo "$VERSION" | cut -d. -f1) && \
    echo "$MAJOR_VERSION" > /tmp/is_v6_or_higher && \
    if [ "$MAJOR_VERSION" -ge 6 ]; then \
        echo "v6+" > /tmp/version_type; \
    else \
        echo "legacy" > /tmp/version_type; \
    fi

# 最终镜像
FROM debian:${BASE_TAG}
ARG SNELL_VERSION

# 复制版本检测结果
COPY --from=version-detector /tmp/version_type /tmp/version_type
COPY --from=version-detector /tmp/is_v6_or_higher /tmp/is_v6_or_higher

# 根据 Snell 版本安装依赖
RUN set -ex && \
    VERSION_TYPE=$(cat /tmp/version_type) && \
    if [ "$VERSION_TYPE" = "v6+" ]; then \
        echo "Installing dependencies for Snell v6+ (requires OpenSSL 1.1 from bullseye)"; \
        echo "deb http://deb.debian.org/debian bullseye main" > /etc/apt/sources.list.d/bullseye.list && \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            ca-certificates \
            libc-ares2 \
            libssl1.1 \
            libuv1 \
            libsodium23 && \
        rm -rf /var/lib/apt/lists/* /var/cache/apt/* && \
        rm -f /etc/apt/sources.list.d/bullseye.list; \
    else \
        echo "Installing dependencies for Snell legacy version (native OpenSSL)"; \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            ca-certificates \
            libc-ares2 \
            libuv1 \
            libsodium23 && \
        rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh && \
    chmod 777 /snell

# 验证所有依赖已满足
RUN ldd snell-server | grep "not found" && echo "Warning: Missing dependencies" || echo "All dependencies satisfied"

ENTRYPOINT ["/snell/entrypoint.sh"]
