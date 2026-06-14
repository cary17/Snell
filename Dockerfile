# 多阶段构建，用于下载 Snell 二进制文件
ARG BASE_TAG=stable-slim
FROM debian:${BASE_TAG} AS builder

ARG TARGETARCH
ARG SNELL_VERSION
ARG GITHUB_REPOSITORY

# 安装构建时需要的工具
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# 根据架构和版本下载对应的 Snell 二进制文件
RUN set -ex; \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386)   ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm)   ARCH="armv7l" ;; \
        *) exit 1 ;; \
    esac; \
    V_NUM="${SNELL_VERSION#v}"; \
    MAJOR_VERSION=$(echo "$V_NUM" | cut -d. -f1); \
    FILE="snell-server-v${V_NUM}-linux-${ARCH}.zip"; \
    if [ "$MAJOR_VERSION" = "3" ]; then \
        echo "Downloading Snell v3 from local repository..."; \
        LOCAL_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/main/Version/v${V_NUM}/${FILE}"; \
        curl -fsSL --retry 3 --retry-delay 5 -o /tmp/s.zip "${LOCAL_URL}"; \
    else \
        echo "Downloading Snell v${MAJOR_VERSION} from official website..."; \
        OFFICIAL_URL="https://dl.nssurge.com/snell/${FILE}"; \
        curl -fsSL --retry 3 --retry-delay 5 -o /tmp/s.zip "${OFFICIAL_URL}"; \
    fi; \
    unzip -q /tmp/s.zip -d /tmp/; \
    chmod +x /tmp/snell-server; \
    echo "${SNELL_VERSION}" > /tmp/snell-version; \
    echo "${MAJOR_VERSION}" > /tmp/snell-major-version

# -----------------------------------------------------------------------------
# 最终运行镜像
FROM debian:${BASE_TAG}

# 从构建阶段复制 Snell 服务器和版本文件
COPY --from=builder /tmp/snell-server /snell/snell-server
COPY --from=builder /tmp/snell-version /snell/snell-version
COPY --from=builder /tmp/snell-major-version /snell/snell-major-version

# 复制启动脚本
COPY entrypoint.sh /snell/entrypoint.sh

# 设置工作目录并赋予执行权限
WORKDIR /snell
RUN chmod +x snell-server entrypoint.sh && chmod 777 /snell

# -----------------------------------------------------------------------------
# 关键修复：安装运行时必需的依赖
# 1. 更新包列表（重要！）
# 2. 安装 ca-certificates 和 netcat-openbsd
# 3. 清理 apt 缓存以减小镜像体积
# 4. 验证关键命令是否存在
RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        netcat-openbsd; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    # 验证 snell-server 的依赖是否满足
    ldd snell-server | grep "not found" && { echo "ERROR: Missing dependencies for snell-server"; exit 1; } || true; \
    # 验证 nc 命令是否存在（这一步会确保 nc 被正确安装）
    command -v nc >/dev/null 2>&1 || { echo "ERROR: nc command not found after installation"; exit 1; }

# 健康检查：检测 Snell 默认端口
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD nc -z -w2 localhost 20000 || exit 1

ENTRYPOINT ["/snell/entrypoint.sh"]