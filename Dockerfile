ARG BASE_VERSION=stable
FROM --platform=$BUILDPLATFORM debian:${BASE_VERSION}-slim AS builder

ARG TARGETPLATFORM
ARG SNELL_VERSION

# 安装必要工具
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
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
    echo "→ 尝试官方下载: ${DOWNLOAD_URL}" && \
    if curl -fsSL --connect-timeout 30 --retry 3 -o /tmp/snell.zip "${DOWNLOAD_URL}"; then \
        echo "✓ 官方下载成功"; \
    else \
        echo "⚠️ 官方下载失败，尝试使用仓库文件"; \
        if [ -f "${REPO_FILE}" ]; then \
            echo "✓ 使用仓库文件: ${REPO_FILE}"; \
            cp "${REPO_FILE}" /tmp/snell.zip; \
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

# 最终运行镜像 - 使用最小基础镜像
FROM debian:${BASE_VERSION}-slim

ARG SNELL_VERSION
ARG BUILD_DATE
ARG VCS_REF

# OCI 标准标签（这些标签不会增加镜像体积，只是元数据）
LABEL org.opencontainers.image.title="Snell Server" \
      org.opencontainers.image.description="Multi-architecture Snell Server - Supports amd64, 386, arm64, armv7" \
      org.opencontainers.image.version="${SNELL_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.url="https://github.com/cary17/snell-docker" \
      org.opencontainers.image.source="https://github.com/cary17/snell-docker" \
      org.opencontainers.image.documentation="https://github.com/cary17/snell-docker#readme" \
      org.opencontainers.image.vendor="cary17" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="cary17"

# 只安装运行时必需的最小依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    tini && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/apt/archives/*

# 创建工作目录
RUN mkdir -p /snell

# 从构建阶段复制文件
COPY --from=builder /tmp/snell/snell-server /snell/snell-server
COPY entrypoint.sh /snell/entrypoint.sh

# 设置执行权限
RUN chmod +x /snell/entrypoint.sh /snell/snell-server

WORKDIR /snell

# 暴露默认端口
EXPOSE 20000

# 使用 tini 作为 init 进程来正确处理信号
ENTRYPOINT ["/usr/bin/tini", "--", "/snell/entrypoint.sh"]
