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
    FILE="snell-server-v${V_NUM}-linux-${ARCH}.zip" && \
    URL="https://dl.nssurge.com/snell/${FILE}" && \
    echo "Downloading: ${URL}" && \
    if ! curl -fsSL --retry 3 --retry-delay 5 -o /tmp/s.zip "${URL}"; then \
        echo "ERROR: ${URL} not found, this platform may not be supported in this version" >&2; \
        exit 1; \
    fi && \
    unzip -q /tmp/s.zip -d /tmp/ && \
    chmod +x /tmp/snell-server

FROM debian:${BASE_TAG}

# 安装运行时依赖：libcares (DNS解析库) 和其他必要库
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcares2 \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/*

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh && \
    chmod 777 /snell

# 使用 exec 形式的 ENTRYPOINT 确保信号传递
ENTRYPOINT ["/snell/entrypoint.sh"]
