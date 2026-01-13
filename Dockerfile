ARG BASE_TAG=stable-slim
FROM --platform=$TARGETPLATFORM debian:${BASE_TAG} AS builder

ARG TARGETARCH
ARG SNELL_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends curl unzip && rm -rf /var/lib/apt/lists/*

COPY Version /tmp/Version

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
    \
    if ! curl -fsSL -o /tmp/s.zip "https://dl.nssurge.com/snell/${FILE}"; then \
        cp "/tmp/Version/v${V_NUM}/${FILE}" /tmp/s.zip; \
    fi && \
    unzip -q /tmp/s.zip -d /tmp/ && \
    chmod +x /tmp/snell-server

FROM debian:${BASE_TAG}

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh

# 使用 exec 形式的 ENTRYPOINT 确保信号传递
ENTRYPOINT ["/snell/entrypoint.sh"]