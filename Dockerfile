ARG BASE_TAG=stable-slim
FROM debian:${BASE_TAG} AS builder

ARG TARGETARCH
ARG SNELL_VERSION
ARG GITHUB_REPOSITORY

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
    echo "${SNELL_VERSION}" > /tmp/snell-version && \
    echo "${MAJOR_VERSION}" > /tmp/snell-major-version

FROM debian:${BASE_TAG}

COPY --from=builder /tmp/snell-version /snell-version
COPY --from=builder /tmp/snell-major-version /snell-major-version

# 安装运行时依赖（ca-certificates 和 netcat-openbsd）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        netcat-openbsd \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY --from=builder /tmp/snell-version .
COPY --from=builder /tmp/snell-major-version .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh && \
    chmod 777 /snell

RUN ldd snell-server | grep -q "not found" && echo "Warning: Missing dependencies" || true

ENTRYPOINT ["/snell/entrypoint.sh"]