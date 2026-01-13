ARG BASE_VERSION=stable

# =========================
# Builder
# =========================
FROM --platform=$BUILDPLATFORM debian:${BASE_VERSION}-slim AS builder

ARG TARGETPLATFORM
ARG SNELL_VERSION

# 构建期最小依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    unzip && \
    rm -rf /var/lib/apt/lists/*

# 工作目录
RUN mkdir -p /tmp/snell

# 复制仓库 Version 目录（作为官方下载失败的兜底）
COPY Version /tmp/Version

# 下载或使用仓库中的 snell-server（统一官方包名）
RUN set -ex && \
    echo "→ Target Platform: ${TARGETPLATFORM}" && \
    case "${TARGETPLATFORM}" in \
        linux/amd64)  ARCH="amd64" ;; \
        linux/386)    ARCH="i386" ;; \
        linux/arm64)  ARCH="aarch64" ;; \
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
            exit 1; \
        fi; \
    fi && \
    unzip -q /tmp/snell.zip -d /tmp/snell && \
    chmod +x /tmp/snell/snell-server && \
    rm -f /tmp/snell.zip && \
    echo "✓ Snell Server 准备完成"

# =========================
# Runtime
# =========================
FROM debian:${BASE_VERSION}-slim

ARG SNELL_VERSION
ARG BUILD_DATE
ARG VCS_REF

# OCI 标签（仅元数据，不影响体积）
LABEL org.opencontainers.image.title="Snell Server" \
      org.opencontainers.image.description="Multi-architecture Snell Server (amd64, 386, arm64, armv7)" \
      org.opencontainers.image.version="${SNELL_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/cary17/snell-docker" \
      org.opencontainers.image.licenses="MIT"

# 运行期最小依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    tini && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/apt/archives/*

# 工作目录
RUN mkdir -p /snell

# 拷贝构建产物
COPY --from=builder /tmp/snell/snell-server /snell/snell-server
COPY entrypoint.sh /snell/entrypoint.sh

# 权限
RUN chmod +x /snell/snell-server /snell/entrypoint.sh

WORKDIR /snell


ENTRYPOINT ["/usr/bin/tini", "--", "/snell/entrypoint.sh"]
