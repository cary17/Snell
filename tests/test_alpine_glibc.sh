#!/usr/bin/env bash
# CI acceptance for one production Dockerfile image (tag or exact manifest digest).
# v3 TLS, v5 QUIC, v6 forwarding and long-term stability/performance are deferred.
set -euo pipefail
: "${SNELL_TEST_IMAGE:?Set SNELL_TEST_IMAGE to the production image}"
platform=${SNELL_TEST_PLATFORM:-linux/amd64}
results=${SNELL_TEST_RESULTS:-$(mktemp -d /tmp/snell-alpine-results.XXXXXX)}
mkdir -p "$results"
results=$(cd "$results" && pwd)
container="snell-alpine-check-$$"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT
printf 'version\tcase\tresult\n' > "$results/results.tsv"
version=$(docker run --rm --platform "$platform" --entrypoint cat "$SNELL_TEST_IMAGE" /snell-version)
[[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._-]*$ ]]
[[ -z "${SNELL_TEST_VERSION:-}" || "${version#v}" == "${SNELL_TEST_VERSION#v}" ]]
version="v${version#v}"
case "$platform" in
    linux/amd64) deb_arch=amd64 ;; linux/386) deb_arch=i386 ;;
    linux/arm64) deb_arch=arm64 ;; linux/arm/v7) deb_arch=armhf ;;
    *) echo "Unsupported test platform: $platform" >&2; exit 1 ;;
esac
docker run --rm --platform "$platform" --entrypoint sh "$SNELL_TEST_IMAGE" -ec '
    . /etc/os-release
    test "$ID" = alpine
    test "$(id -u)" != 0
    grep -Fxq source=debian:bookworm-slim /glibc-source.txt
    grep -Fxq "architecture=$1" /glibc-source.txt
    for package in libc6 libstdc++6 libgcc-s1; do
        awk -v name="$package" -v arch="$1" "\$1 == name || \$1 == name \":\" arch { if (NF == 2) found = 1 } END { exit !found }" /glibc-packages.txt
        test -s "/usr/share/doc/$package/copyright"
    done
    for package in gcompat libstdc++ libgcc; do
        if apk info -e "$package" >/dev/null; then
            echo "Unexpected Alpine compatibility/C++ package: $package" >&2
            exit 1
        fi
    done
    if [ "$1" = amd64 ]; then test -x /lib64/ld-linux-x86-64.so.2; fi
    cat /etc/alpine-release /glibc-source.txt /glibc-packages.txt
    sha256sum /snell/snell-server
' _ "$deb_arch" > "$results/runtime.txt"
cat "$results/runtime.txt"

stop_case() {
    docker logs "$container" > "$results/$version-$case_name.log" 2>&1
    docker stop -t 5 "$container" >/dev/null
    code=$(docker inspect --format '{{.State.ExitCode}}' "$container")
    [[ "$code" == 0 || "$code" == 143 ]] || { echo "Bad stop: $code" >&2; return 1; }
    docker rm "$container" >/dev/null
    printf '%s\t%s\tPASS\n' "$version" "$case_name" | tee -a "$results/results.tsv"
}

start_case() {
    case_name=$1
    shift
    docker run -d --platform "$platform" --name "$container" --network none \
        -e LISTEN=32000 -e PSK=RegressionOnlyPsk16 \
        -e DNS=1.1.1.1 "$@" "$SNELL_TEST_IMAGE" >/dev/null
    ready=0
    for _ in {1..60}; do
        if docker exec "$container" nc -z -w 1 127.0.0.1 32000 2>/dev/null; then ready=1; break; fi
        [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]] || break
        sleep 0.25
    done
    if [[ $ready != 1 ]]; then
        docker logs "$container" > "$results/$version-$case_name.log" 2>&1
        cat "$results/$version-$case_name.log" >&2
        printf '%s\t%s\tFAIL\n' "$version" "$case_name" | tee -a "$results/results.tsv"
        return 1
    fi
    [[ $(docker exec "$container" id -u) != 0 ]]
    docker exec "$container" cat /snell/snell.conf > "$results/$version-$case_name.conf"
}

# CI verifies this image's single version.
version_log="$results/$version-version.log"
if ! docker run --rm --platform "$platform" --entrypoint /snell/snell-server \
    "$SNELL_TEST_IMAGE" --version > "$version_log" 2>&1; then
    cat "$version_log" >&2
    exit 1
fi
cat "$version_log"
start_case baseline
grep -Fxq 'psk = RegressionOnlyPsk16' "$results/$version-baseline.conf"
case "$version" in
    v3.*|v4.0.*)
        if grep -q '^dns = ' "$results/$version-baseline.conf"; then exit 1; fi
        ;;
    *) grep -Fxq 'dns = 1.1.1.1' "$results/$version-baseline.conf" ;;
esac
docker exec "$container" nc -6 -z -w 1 ::1 32000
docker restart -t 5 "$container" >/dev/null
sleep 1
docker exec "$container" cat /snell/snell.conf | cmp - "$results/$version-baseline.conf"
docker exec "$container" nc -z -w 1 127.0.0.1 32000
stop_case

for level in trace verbose info notify warning error; do
    start_case "log-$level" -e "LOGLEVEL=$level"
    stop_case
done
start_case ipv6 -e IPV6=true
grep -Fxq 'ipv6 = true' "$results/$version-ipv6.conf"
stop_case

start_case random-psk -e PSK=
psk=$(sed -n 's/^psk = //p' "$results/$version-random-psk.conf")
[[ ${#psk} -ge 16 && ${#psk} -le 180 ]]
stop_case

start_case invalid-env -e IPV6=banana -e LOGLEVEL=invalid -e UNKNOWN_FIELD=ignored
if grep -Eq 'banana|unknown|log =' "$results/$version-invalid-env.conf"; then exit 1; fi
stop_case

mount_config="$results/$version-mounted.conf"
printf '[snell-server]\nlisten = 0.0.0.0:32000\npsk = MountedConfigPsk16\n' > "$mount_config"
chmod 644 "$mount_config"
start_case readonly-config -v "$mount_config:/snell/snell.conf:ro" -e PSK=ignored
cmp "$mount_config" "$results/$version-readonly-config.conf"
stop_case

case "$version" in
    v3*) obfs_modes=http ;; # TLS is retained in production; testing deferred.
    v4*|v5*) obfs_modes=http ;;
    *) obfs_modes='' ;;
esac
for obfs in $obfs_modes; do
    start_case "obfs-$obfs" -e "OBFS=$obfs" -e HOST=example.com
    grep -Fxq "obfs = $obfs" "$results/$version-obfs-$obfs.conf"
    stop_case
done
case "$version" in
    v5*|v6*)
        start_case egress -e EGRESS_INTERFACE=lo
        grep -Fxq 'egress-interface = lo' "$results/$version-egress.conf"
        stop_case
        ;;
esac
case "$version" in
    v6*)
        start_case multiport -e 'LISTEN=32000, 32001'
        docker exec "$container" nc -z -w 1 127.0.0.1 32001
        docker exec "$container" nc -6 -z -w 1 ::1 32001
        stop_case
        for mode in default unshaped unsafe-raw; do
            start_case "mode-$mode" -e "MODE=$mode"
            grep -Fxq "mode = $mode" "$results/$version-mode-$mode.conf"
            stop_case
        done
        for preference in default prefer-ipv4 prefer-ipv6 ipv4-only ipv6-only; do
            start_case "dns-$preference" -e "DNS_IP_PREFERENCE=$preference"
            if [[ "$preference" != default ]]; then
                grep -Fxq "dns-ip-preference = $preference" "$results/$version-dns-$preference.conf"
            fi
            stop_case
        done
        ;;
esac
printf 'Results: %s\n' "$results"
