# 可选基础镜像版本
ARG BASE_TAG=stable-slim
FROM --platform=$TARGETPLATFORM debian:${BASE_TAG} AS builder

ARG TARGETARCH
ARG SNELL_VERSION

# 1. 安装构建工具
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# 2. 复制本地备份文件
COPY Version /tmp/Version

# 3. 下载并准备二进制文件
RUN set -ex && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386)   ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm)   ARCH="armv7l" ;; \
        *) exit 1 ;; \
    esac && \
    V_NUM="${SNELL_VERSION#v}" && \
    FILENAME="snell-server-v${V_NUM}-linux-${ARCH}.zip" && \
    \
    if ! curl -fsSL -o /tmp/s.zip "https://dl.nssurge.com/snell/${FILENAME}"; then \
        echo "官方下载失败，尝试使用本地备份..." && \
        cp "/tmp/Version/v${V_NUM}/${FILENAME}" /tmp/s.zip; \
    fi && \
    unzip -q /tmp/s.zip -d /tmp/ && \
    chmod +x /tmp/snell-server

# --- 运行时环境 ---
FROM debian:${BASE_TAG}

# 只保留运行必需的 CA 证书，安装后立即清理以最小化体积
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/*

WORKDIR /snell

# 拷贝二进制文件和 entrypoint
COPY --from=builder /tmp/snell-server .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh

# entrypoint.sh 内部使用 exec 确保信号优雅处理 (SIGTERM/SIGINT)
ENTRYPOINT ["./entrypoint.sh"]
