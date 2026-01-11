ARG BASE_VERSION=bookworm
FROM --platform=$BUILDPLATFORM debian:${BASE_VERSION}-slim AS builder

ARG TARGETPLATFORM
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
    echo "→ Build Platform: ${BUILDPLATFORM:-unknown}" && \
    echo "→ Target Platform: ${TARGETPLATFORM:-unknown}" && \
    case "${TARGETPLATFORM}" in \
        linux/amd64) ARCH="amd64" ;; \
        linux/386) ARCH="i386" ;; \
        linux/arm64) ARCH="aarch64" ;; \
        linux/arm/v7) ARCH="armv7l" ;; \
        *) echo "❌ Unsupported platform: ${TARGETPLATFORM}" && exit 1 ;; \
    esac && \
    VERSION="${SNELL_VERSION#v}" && \
    VERSION_WITH_V="v${VERSION}" && \
    echo "→ Snell Version: ${VERSION_WITH_V}, Arch: ${ARCH}" && \
    DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-${VERSION_WITH_V}-linux-${ARCH}.zip" && \
    REPO_FILE="/tmp/Version/${VERSION_WITH_V}/snell-server-${VERSION_WITH_V}-linux-${ARCH}.zip" && \
    if [ -f "${REPO_FILE}" ]; then \
        echo "✓ 使用仓库文件: ${REPO_FILE}"; \
        cp "${REPO_FILE}" /tmp/snell.zip; \
    else \
        echo "→ 仓库文件不存在，尝试官方下载: ${DOWNLOAD_URL}"; \
        if wget --timeout=30 --tries=3 -O /tmp/snell.zip "${DOWNLOAD_URL}"; then \
            echo "✓ 官方下载成功"; \
        else \
            echo "❌ 构建失败：官方下载失败且仓库中无备份文件"; \
            echo "提示：请运行 ./download-snell.sh ${VERSION_WITH_V} 下载文件"; \
            exit 1; \
        fi; \
    fi && \
    echo "→ 解压文件..." && \
    unzip /tmp/snell.zip -d /tmp/snell && \
    chmod +x /tmp/snell/snell-server && \
    echo "✓ Snell Server 准备完成"

# 最终运行镜像
FROM debian:${BASE_VERSION}-slim

ARG SNELL_VERSION

LABEL org.opencontainers.image.source="https://github.com/yourusername/snell-docker"
LABEL org.opencontainers.image.description="Snell Server"
LABEL org.opencontainers.image.version="${SNELL_VERSION}"

# 安装运行时必需的依赖（包括 tini 用于信号处理）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    tini && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# 创建工作目录
RUN mkdir -p /snell

# 从构建阶段复制文件
COPY --from=builder /tmp/snell/snell-server /snell/snell-server
COPY entrypoint.sh /snell/entrypoint.sh

# 设置执行权限
RUN chmod +x /snell/entrypoint.sh /snell/snell-server

WORKDIR /snell

# 使用 tini 作为 init 进程来正确处理信号
ENTRYPOINT ["/usr/bin/tini", "--", "/snell/entrypoint.sh"]