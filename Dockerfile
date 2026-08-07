ARG BASE_TAG=stable-slim
FROM debian:${BASE_TAG} AS builder

ARG TARGETARCH
ARG SNELL_VERSION
ARG GITHUB_REPOSITORY
ARG USE_LOCAL_BINARY=false

COPY snell-config.yml /tmp/snell-config.yml
COPY scripts/generate-config-items.awk /tmp/generate-config-items.awk
COPY Version /tmp/Version

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip && \
    rm -rf /var/lib/apt/lists/*

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
    LOCAL_FILE="/tmp/Version/v${V_NUM}/${FILE}" && \
    LOCAL_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/main/Version/v${V_NUM}/${FILE}" && \
    OFFICIAL_URL="https://dl.nssurge.com/snell/${FILE}" && \
    \
    if [ "${USE_LOCAL_BINARY}" = "true" ]; then \
        echo "Using local Snell package: ${LOCAL_FILE}"; \
        [ -f "${LOCAL_FILE}" ] || { echo "Local Snell package not found: ${LOCAL_FILE}" >&2; exit 1; }; \
        cp "${LOCAL_FILE}" /tmp/s.zip; \
    else \
        echo "Downloading Snell v${MAJOR_VERSION} from official website..."; \
        curl -4 -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -o /tmp/s.zip "${OFFICIAL_URL}" || \
        curl -6 -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -o /tmp/s.zip "${OFFICIAL_URL}" || { \
            [ -n "${GITHUB_REPOSITORY}" ] || { echo "Official downloads failed and GITHUB_REPOSITORY is not set" >&2; exit 1; }; \
            echo "Official downloads failed, trying Version/ backup..."; \
            curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -o /tmp/s.zip "${LOCAL_URL}"; \
        }; \
    fi && \
    EXPECTED_SHA=$(awk -v path="Version/v${V_NUM}/${FILE}" '$2 == path { print $1 }' /tmp/Version/SHA256SUMS) && \
    if [ "${USE_LOCAL_BINARY}" = true ] && [ -z "${EXPECTED_SHA}" ]; then echo "Missing SHA256 entry for ${FILE}" >&2; exit 1; fi && \
    if [ -n "${EXPECTED_SHA}" ]; then printf '%s  %s\n' "${EXPECTED_SHA}" /tmp/s.zip | sha256sum -c -; else echo "No pre-registered SHA256 for new official archive; recording downloaded digest only."; fi && \
    \
    unzip -q /tmp/s.zip -d /tmp/ && \
    sha256sum /tmp/s.zip | cut -d' ' -f1 > /tmp/snell-archive-sha256 && \
    chmod +x /tmp/snell-server && \
    awk -v sn_version="${SNELL_VERSION}" -f /tmp/generate-config-items.awk /tmp/snell-config.yml > /tmp/config-items.sh && \
    echo "${SNELL_VERSION}" > /tmp/snell-version && \
    echo "${MAJOR_VERSION}" > /tmp/snell-major-version

FROM debian:${BASE_TAG}

COPY --from=builder /tmp/snell-version /snell-version
COPY --from=builder /tmp/snell-major-version /snell-major-version
COPY --from=builder /tmp/snell-archive-sha256 /snell-archive-sha256

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        netcat-openbsd \
        openssl \
    && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/*

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY --from=builder /tmp/snell-version .
COPY --from=builder /tmp/snell-major-version .
COPY --from=builder /tmp/config-items.sh .
COPY entrypoint.sh .
RUN groupadd --system snell && useradd --system --gid snell --home-dir /snell --shell /usr/sbin/nologin snell && \
    chmod +x snell-server entrypoint.sh && chown -R snell:snell /snell && chmod 750 /snell

USER snell

STOPSIGNAL SIGTERM
ENTRYPOINT ["/snell/entrypoint.sh"]
