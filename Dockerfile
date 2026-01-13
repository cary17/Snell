ARG BASE_VERSION=stable

# =========================
# Builder
# =========================
FROM --platform=$TARGETPLATFORM debian:${BASE_VERSION}-slim AS builder

ARG TARGETARCH
ARG SNELL_VERSION

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    unzip && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /tmp/snell
COPY Version /tmp/Version

RUN set -ex && \
    echo "→ TARGETARCH=${TARGETARCH}" && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386)   ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm)   ARCH="armv7l" ;; \
        *) echo "❌ Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
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
            cp "${REPO_FILE}" /tmp/snell.zip; \
        else \
            echo "❌ 构建失败：无可用 Snell 安装包"; \
            exit 1; \
        fi; \
    fi && \
    unzip -q /tmp/snell.zip -d /tmp/snell && \
    chmod +x /tmp/snell/snell-server && \
    rm -f /tmp/snell.zip

# =========================
# Runtime
# =========================
FROM debian:${BASE_VERSION}-slim

ARG SNELL_VERSION
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="Snell Server" \
      org.opencontainers.image.version="${SNELL_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/cary17/snell-docker" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    tini && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /snell

COPY --from=builder /tmp/snell/snell-server /snell/snell-server
COPY entrypoint.sh /snell/entrypoint.sh

RUN chmod +x /snell/snell-server /snell/entrypoint.sh

WORKDIR /snell
EXPOSE 20000

ENTRYPOINT ["/usr/bin/tini", "--", "/snell/entrypoint.sh"]
