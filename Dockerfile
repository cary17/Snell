ARG BASE_TAG=stable-slim
FROM debian:${BASE_TAG} AS builder

ARG TARGETARCH
ARG SNELL_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*

RUN set -ex && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386)   ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm)   ARCH="armv7l" ;; \
        *) exit 1 ;; \
    esac && \
    V_NUM="${SNELL_VERSION#v}" && \
    MAJOR_VERSION=$(echo "$V_NUM" | cut -d. -f1) && \
    FILE="snell-server-v${V_NUM}-linux-${ARCH}.zip" && \
    \
    # 判断版本：v3 从本地仓库拉取，v4+ 从官网拉取
    if [ "$MAJOR_VERSION" = "3" ]; then \
        echo "Downloading Snell v3 from local repository..."; \
        LOCAL_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/main/Version/v${V_NUM}/${FILE}"; \
        echo "URL: ${LOCAL_URL}"; \
        if ! curl -fsSL --retry 3 --retry-delay 5 -o /tmp/s.zip "${LOCAL_URL}"; then \
            echo "ERROR: Failed to download ${FILE} from local repository" >&2; \
            exit 1; \
        fi; \
    else \
        echo "Downloading Snell v${MAJOR_VERSION} from official website..."; \
        OFFICIAL_URL="https://dl.nssurge.com/snell/${FILE}"; \
        echo "URL: ${OFFICIAL_URL}"; \
        if ! curl -fsSL --retry 3 --retry-delay 5 -o /tmp/s.zip "${OFFICIAL_URL}"; then \
            echo "ERROR: ${OFFICIAL_URL} not found, this platform may not be supported in this version" >&2; \
            exit 1; \
        fi; \
    fi && \
    \
    unzip -q /tmp/s.zip -d /tmp/ && \
    chmod +x /tmp/snell-server && \
    # 保存版本信息到文件
    echo "${SNELL_VERSION}" > /tmp/snell-version && \
    echo "${MAJOR_VERSION}" > /tmp/snell-major-version

FROM debian:${BASE_TAG}

# 从构建阶段复制版本信息
COPY --from=builder /tmp/snell-version /snell-version
COPY --from=builder /tmp/snell-major-version /snell-major-version

# 根据版本安装依赖
RUN set -ex && \
    MAJOR_VERSION=$(cat /snell-major-version) && \
    echo "Building for Snell version: $(cat /snell-version), major: ${MAJOR_VERSION}" && \
    echo "deb http://deb.debian.org/debian bullseye main" > /etc/apt/sources.list.d/bullseye.list && \
    apt-get update && \
    if [ "$MAJOR_VERSION" -ge 6 ]; then \
        echo "Installing dependencies for Snell v6+"; \
        apt-get install -y --no-install-recommends \
            ca-certificates \
            libc-ares2 \
            libssl1.1 \
            libuv1 \
            libsodium23; \
    elif [ "$MAJOR_VERSION" -ge 4 ]; then \
        echo "Installing dependencies for Snell v4/v5"; \
        apt-get install -y --no-install-recommends \
            ca-certificates \
            libc-ares2 \
            libuv1 \
            libsodium23 \
            libssl1.1; \
    else \
        echo "Installing dependencies for Snell v3"; \
        apt-get install -y --no-install-recommends \
            ca-certificates \
            libc-ares2 \
            libuv1 \
            libsodium23; \
        # v3 可能不需要 OpenSSL 或需要特定版本
        if ldd /tmp/snell-server 2>/dev/null | grep -q "libcrypto"; then \
            apt-get install -y --no-install-recommends libssl1.1; \
        fi; \
    fi && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* && \
    rm -f /etc/apt/sources.list.d/bullseye.list

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY --from=builder /tmp/snell-version .
COPY --from=builder /tmp/snell-major-version .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh && \
    chmod 777 /snell

# 验证所有依赖已满足
RUN ldd snell-server | grep "not found" && echo "Warning: Missing dependencies" || echo "All dependencies satisfied"

ENTRYPOINT ["/snell/entrypoint.sh"]
