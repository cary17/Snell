FROM debian:bookworm-slim AS builder

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl unzip libc6 libstdc++6 libgcc-s1 && \
    mkdir /runtime && \
    printf 'source=debian:bookworm-slim\narchitecture=%s\n' "$(dpkg --print-architecture)" > /runtime/glibc-source.txt && \
    dpkg-query -W libc6 libstdc++6 libgcc-s1 > /runtime/glibc-packages.txt && \
    dpkg-query -L libc6 libstdc++6 libgcc-s1 | \
    grep -E '^/(usr/)?lib(64)?/' | while IFS= read -r path; do \
        if [ -f "$path" ] || [ -L "$path" ]; then printf '%s\n' "$path"; fi; \
    done > /tmp/libraries && \
    test -s /tmp/libraries && \
    tar -chf /tmp/runtime.tar -T /tmp/libraries && \
    tar -xf /tmp/runtime.tar -C /runtime && rm /tmp/runtime.tar && \
    mkdir -p /runtime/usr/share/doc && \
    cp -aL /usr/share/doc/libc6 /usr/share/doc/libstdc++6 /usr/share/doc/libgcc-s1 /runtime/usr/share/doc/ && \
    rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
ARG SNELL_VERSION

COPY snell-config.yml /tmp/snell-config.yml
COPY scripts/generate-config-items.awk /tmp/generate-config-items.awk
COPY Version /tmp/Version

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
    OFFICIAL_URL="https://dl.nssurge.com/snell/${FILE}" && \
    if [ -f "${LOCAL_FILE}" ]; then \
        echo "Using repository package: ${LOCAL_FILE}"; \
        cp "${LOCAL_FILE}" /tmp/s.zip; \
    else \
        echo "Repository package not found, downloading from official website: ${OFFICIAL_URL}"; \
        curl -4 -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -o /tmp/s.zip "${OFFICIAL_URL}" || \
        curl -6 -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 5 -o /tmp/s.zip "${OFFICIAL_URL}"; \
    fi && \
    unzip -q /tmp/s.zip -d /tmp/ && \
    sha256sum /tmp/s.zip | cut -d' ' -f1 > /tmp/snell-archive-sha256 && \
    chmod +x /tmp/snell-server && \
    awk -v sn_version="${SNELL_VERSION}" -f /tmp/generate-config-items.awk /tmp/snell-config.yml > /tmp/config-items.sh && \
    echo "${SNELL_VERSION}" > /tmp/snell-version && \
    echo "${MAJOR_VERSION}" > /tmp/snell-major-version

FROM alpine:latest

RUN apk add --no-cache ca-certificates netcat-openbsd openssl
# Preserve Debian library paths (including /lib64 on amd64), not Alpine substitutes.
COPY --from=builder /runtime/ /

COPY --from=builder /tmp/snell-version /snell-version
COPY --from=builder /tmp/snell-major-version /snell-major-version
COPY --from=builder /tmp/snell-archive-sha256 /snell-archive-sha256

WORKDIR /snell
COPY --from=builder /tmp/snell-server .
COPY --from=builder /tmp/snell-version .
COPY --from=builder /tmp/snell-major-version .
COPY --from=builder /tmp/config-items.sh .
COPY entrypoint.sh .
RUN addgroup -S snell && adduser -S -G snell -H -h /snell -s /sbin/nologin snell && \
    chmod +x snell-server entrypoint.sh && chown -R snell:snell /snell && chmod 750 /snell

USER snell

STOPSIGNAL SIGTERM
ENTRYPOINT ["/snell/entrypoint.sh"]
