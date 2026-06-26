ARG BASE_TAG=stable-slim
FROM debian:${BASE_TAG} AS builder

ARG TARGETARCH
ARG SNELL_VERSION
ARG GITHUB_REPOSITORY

COPY snell-config.yml /tmp/snell-config.yml
COPY scripts/generate-config-items.awk /tmp/generate-config-items.awk

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*

RUN set -ex && \
    [ -n "${SNELL_VERSION}" ] || { echo "SNELL_VERSION build arg is required" >&2; exit 1; } && \
    TARGETARCH="${TARGETARCH:-$(dpkg --print-architecture)}" && \
    case "${TARGETARCH}" in \
        amd64) ARCH="amd64" ;; \
        386)   ARCH="i386" ;; \
        arm64) ARCH="aarch64" ;; \
        arm)   ARCH="armv7l" ;; \
        *) exit 1 ;; \
    esac && \
    V_NUM="${SNELL_VERSION#v}" && \
    MAJOR_VERSION="${V_NUM%%.*}" && \
    FILE="snell-server-v${V_NUM}-linux-${ARCH}.zip" && \
    LOCAL_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/main/Version/v${V_NUM}/${FILE}" && \
    OFFICIAL_URL="https://dl.nssurge.com/snell/${FILE}" && \
    \
    echo "Downloading Snell v${MAJOR_VERSION} from official website..."; \
    curl -4 -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -o /tmp/s.zip "${OFFICIAL_URL}" || \
    curl -6 -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -o /tmp/s.zip "${OFFICIAL_URL}" || { \
        [ -n "${GITHUB_REPOSITORY}" ] || { echo "Official downloads failed and GITHUB_REPOSITORY is not set" >&2; exit 1; }; \
        echo "Official downloads failed, trying Version/ backup..."; \
        curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -o /tmp/s.zip "${LOCAL_URL}"; \
    } && \
    \
    unzip -q /tmp/s.zip -d /tmp/ && \
    chmod +x /tmp/snell-server && \
    awk -v sn_version="${SNELL_VERSION}" -f /tmp/generate-config-items.awk /tmp/snell-config.yml > /tmp/config-items.sh && \
    echo "${SNELL_VERSION}" > /tmp/snell-version && \
    echo "${MAJOR_VERSION}" > /tmp/snell-major-version

FROM debian:${BASE_TAG}

COPY --from=builder /tmp/snell-version /snell-version
COPY --from=builder /tmp/snell-major-version /snell-major-version

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        netcat-openbsd \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY --from=builder /tmp/snell-version .
COPY --from=builder /tmp/snell-major-version .
COPY --from=builder /tmp/config-items.sh .
COPY entrypoint.sh .
RUN chmod +x snell-server entrypoint.sh && chmod 755 /snell

ENTRYPOINT ["/snell/entrypoint.sh"]
