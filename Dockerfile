ARG DEBIAN_VERSION=bookworm
FROM debian:${DEBIAN_VERSION}-slim AS builder

ARG TARGETARCH
ARG SNELL_VERSION

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates wget unzip && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /tmp/snell

COPY Version /tmp/Version

RUN set -ex && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386) ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm/v7|arm) ARCH="armv7l" ;; \
        *) echo "❌ Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    VERSION_NUM="${SNELL_VERSION#v}" && \
    FILE_PATH="/tmp/Version/${VERSION_NUM}/snell-server-v${VERSION_NUM}-linux-${ARCH}.zip" && \
    DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v${VERSION_NUM}-linux-${ARCH}.zip" && \
    echo "→ 下载 Snell: ${DOWNLOAD_URL}" && \
    i=1 && \
    while [ $i -le 5 ]; do \
        if wget -O /tmp/snell.zip "${DOWNLOAD_URL}"; then \
            echo "✓ 下载成功"; \
            break; \
        fi; \
        echo "⚠ 下载失败，第 $i 次重试，3 秒后重试"; \
        i=$((i+1)); \
        sleep 3; \
    done && \
    if [ ! -f /tmp/snell.zip ]; then \
        echo "✗ 官方下载失败，尝试使用仓库文件"; \
        if [ -f "${FILE_PATH}" ]; then \
            cp "${FILE_PATH}" /tmp/snell.zip; \
            echo "✓ 使用仓库文件"; \
        else \
            echo "✗ 仓库中也不存在文件，构建失败"; \
            exit 1; \
        fi; \
    fi && \
    unzip /tmp/snell.zip -d /tmp/snell && \
    chmod +x /tmp/snell/snell-server

FROM debian:${DEBIAN_VERSION}-slim

ARG SNELL_VERSION
LABEL org.opencontainers.image.version="${SNELL_VERSION}"

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /snell

COPY --from=builder /tmp/snell/snell-server /snell/snell-server
COPY entrypoint.sh /snell/entrypoint.sh

RUN chmod +x /snell/*

WORKDIR /snell
EXPOSE 20000
ENTRYPOINT ["/snell/entrypoint.sh"]
