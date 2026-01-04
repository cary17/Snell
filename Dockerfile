ARG DEBIAN_VERSION=bookworm
FROM debian:${DEBIAN_VERSION}-slim AS builder

ARG TARGETARCH
ARG SNELL_VERSION
ARG USE_LOCAL=false

# 安装下载工具（仅在需要下载时）
RUN if [ "${USE_LOCAL}" != "true" ]; then \
        apt-get update && \
        apt-get install -y --no-install-recommends \
        ca-certificates \
        wget \
        unzip && \
        rm -rf /var/lib/apt/lists/*; \
    else \
        apt-get update && \
        apt-get install -y --no-install-recommends unzip && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# 映射架构名称
RUN case "${TARGETARCH}" in \
        "amd64") echo "amd64" > /tmp/arch ;; \
        "386") echo "i386" > /tmp/arch ;; \
        "arm64") echo "aarch64" > /tmp/arch ;; \
        "arm/v7") echo "armv7l" > /tmp/arch ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac

# 复制 Version 目录（如果使用仓库文件）
COPY Version /tmp/Version

# 下载或使用仓库中的 snell-server
RUN ARCH=$(cat /tmp/arch) && \
    mkdir -p /tmp/snell && \
    if [ "${USE_LOCAL}" = "true" ]; then \
        FILE_PATH="/tmp/Version/${SNELL_VERSION}/snell-server-v${SNELL_VERSION}-linux-${ARCH}.zip"; \
        echo "→ 使用仓库文件: ${FILE_PATH}"; \
        if [ -f "${FILE_PATH}" ]; then \
            echo "✓ 文件存在，使用仓库文件"; \
            cp "${FILE_PATH}" /tmp/snell.zip; \
        else \
            echo "✗ 仓库文件不存在: ${FILE_PATH}"; \
            echo "→ 回退到官方下载"; \
            DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${ARCH}.zip"; \
            echo "→ 下载地址: ${DOWNLOAD_URL}"; \
            wget -O /tmp/snell.zip "${DOWNLOAD_URL}"; \
        fi; \
    else \
        DOWNLOAD_URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${ARCH}.zip"; \
        echo "→ 下载地址: ${DOWNLOAD_URL}"; \
        wget -O /tmp/snell.zip "${DOWNLOAD_URL}"; \
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
