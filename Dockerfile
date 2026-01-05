ARG DEBIAN_VERSION=bookworm
FROM debian:${DEBIAN_VERSION}-slim AS builder

ARG TARGETARCH
ARG SNELL_VERSION
ARG USE_LOCAL=false

# 安装必要工具
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        unzip && \
    rm -rf /var/lib/apt/lists/*

# 创建工作目录
RUN mkdir -p /tmp/snell

# 复制 Version 目录（如果存在）
COPY Version /tmp/Version

# 下载或使用仓库中的 snell-server
RUN set -ex && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386) ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm) ARCH="armv7l" ;; \
        *) echo "❌ Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    echo "→ Target Architecture: ${TARGETARCH}" && \
    echo "→ Snell Architecture: ${ARCH}" && \
    echo "→ Snell Version: ${SNELL_VERSION}" && \
    FILE_PATH="/tmp/Version/${SNELL_VERSION}/snell-server-${SNELL_VERSION}-linux-${ARCH}.zip" && \
    DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${ARCH}.zip" && \
    \
    if [ "${USE_LOCAL}" = "true" ] && [ -f "${FILE_PATH}" ]; then \
        echo "✓ 使用仓库中的 Snell 文件"; \
        cp "${FILE_PATH}" /tmp/snell.zip; \
    else \
        echo "→ 尝试官方下载: ${DOWNLOAD_URL}"; \
        if ! wget -O /tmp/snell.zip "${DOWNLOAD_URL}"; then \
            echo "⚠ 官方下载失败，尝试使用仓库文件"; \
            if [ -f "${FILE_PATH}" ]; then \
                echo "✓ 回退使用仓库文件"; \
                cp "${FILE_PATH}" /tmp/snell.zip; \
            else \
                echo "❌ 官方下载失败，仓库中也不存在对应文件"; \
                exit 1; \
            fi; \
        fi; \
    fi && \
    unzip /tmp/snell.zip -d /tmp/snell && \
    chmod +x /tmp/snell/snell-server && \
    echo "✓ Snell Server 准备完成"

# 最终运行镜像
FROM debian:${DEBIAN_VERSION}-slim

ARG SNELL_VERSION
LABEL org.opencontainers.image.source="https://github.com/yourusername/snell-docker"
LABEL org.opencontainers.image.description="Snell Server"
LABEL org.opencontainers.image.version="${SNELL_VERSION}"

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN mkdir -p /snell

COPY --from=builder /tmp/snell/snell-server /snell/snell-server
COPY entrypoint.sh /snell/entrypoint.sh

RUN chmod +x /snell/entrypoint.sh /snell/snell-server

WORKDIR /snell

EXPOSE 20000

ENTRYPOINT ["/snell/entrypoint.sh"]
