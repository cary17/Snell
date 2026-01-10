ARG BASE_VERSION=latest
FROM debian:${BASE_VERSION}-slim AS builder

ARG TARGETARCH
ARG SNELL_VERSION

# 安装必要工具
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    unzip && \
    rm -rf /var/lib/apt/lists/*

# 创建工作目录
RUN mkdir -p /tmp/snell

# 复制 Version 目录
COPY Version /tmp/Version

# 下载或使用仓库中的 snell-server
RUN set -ex && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386) ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm/v7|arm) ARCH="armv7l" ;; \
        *) echo "❌ Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    echo "→ Snell Version: ${SNELL_VERSION}, Arch: ${ARCH}" && \
    DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${ARCH}.zip" && \
    REPO_FILE="/tmp/Version/${SNELL_VERSION}/snell-server-${SNELL_VERSION}-linux-${ARCH}.zip" && \
    echo "→ 尝试官方下载: ${DOWNLOAD_URL}" && \
    if wget --timeout=30 --tries=3 -O /tmp/snell.zip "${DOWNLOAD_URL}" 2>&1; then \
        echo "✓ 官方下载成功"; \
    else \
        echo "⚠️ 官方下载失败，尝试使用仓库文件"; \
        if [ -f "${REPO_FILE}" ]; then \
            echo "✓ 使用仓库文件: ${REPO_FILE}"; \
            cp "${REPO_FILE}" /tmp/snell.zip; \
        else \
            echo "❌ 构建失败：官方下载失败且仓库中无备份文件"; \
            echo "提示：请在 Version/${SNELL_VERSION}/ 目录下添加 snell 文件"; \
            exit 1; \
        fi; \
    fi && \
    unzip /tmp/snell.zip -d /tmp/snell && \
    chmod +x /tmp/snell/snell-server && \
    echo "✓ Snell Server 准备完成"

# 最终运行镜像
FROM debian:${BASE_VERSION}-slim

ARG SNELL_VERSION
LABEL org.opencontainers.image.source="https://github.com/yourusername/snell-docker"
LABEL org.opencontainers.image.description="Snell Server"
LABEL org.opencontainers.image.version="${SNELL_VERSION}"

# 只安装运行时必需的依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 创建工作目录
RUN mkdir -p /snell

# 从构建阶段复制文件
COPY --from=builder /tmp/snell/snell-server /snell/snell-server
COPY entrypoint.sh /snell/entrypoint.sh

# 设置执行权限
RUN chmod +x /snell/entrypoint.sh /snell/snell-server

WORKDIR /snell

EXPOSE 20000

# 使用 root 用户运行（egress-interface 需要 root 权限）
ENTRYPOINT ["/snell/entrypoint.sh"]
