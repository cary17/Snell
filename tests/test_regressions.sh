#!/usr/bin/env bash
# Fixture globals are consumed by the sourced installer functions.
# shellcheck disable=SC2034
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../Snell.sh
SNELL_SOURCE_ONLY=1 source "$root/Snell.sh"

[[ "$(printf '%s\n' 6.0.0rc2 6.0.0 6.0.0rc10 6.0.0b4 | sort_snell_versions)" == $'6.0.0b4\n6.0.0rc2\n6.0.0rc10\n6.0.0' ]]
[[ "$(printf '%s\n' 6.0.0 6.0.0-rc1 | sort_snell_versions | tail -n 1)" == 6.0.0 ]]

# Bridge networking must retain UDP for Snell v5 QUIC, not only TCP.
bridge_compose=$(render_compose ghcr.io/fixture/snell:v5.0.1 bridge 32000)
grep -Fxq '      - "${LISTEN}:${LISTEN}/tcp"' <<< "$bridge_compose"
grep -Fxq '      - "${LISTEN}:${LISTEN}/udp"' <<< "$bridge_compose"
host_compose=$(render_compose ghcr.io/fixture/snell:v5.0.1 host 32000)
grep -Fxq '    network_mode: host' <<< "$host_compose"
if grep -q '^    ports:' <<< "$host_compose"; then exit 1; fi

# Management commands must never execute when an unsupported dry-run is requested.
for action in update uninstall start stop restart; do
    (
        update_snell() { echo unexpected-operation; return 99; }
        uninstall_snell() { echo unexpected-operation; return 99; }
        manage_service() { echo unexpected-operation; return 99; }
        status=0
        agent_main "--agent-$action" --yes --dry-run >/dev/null 2>&1 || status=$?
        [[ "$status" == 2 ]]
    )
done

(
    NONINTERACTIVE=1 CLI_DRY_RUN=1 CLI_YES=1
    get_mode() { echo docker; }
    port_in_use() { return 1; }
    docker_config_defaults() {
        cfg_image=ghcr.io/fixture/snell:v6.0.0rc
        cfg_tag=v6.0.0rc cfg_network=host
        cfg_default_port=32000 cfg_default_psk=AgentTestPsk16._-abcdef
        cfg_default_ipv6=true cfg_default_pref=prefer-ipv6
        cfg_default_dns='' cfg_default_egress='' cfg_default_obfs=''
        cfg_default_host='' cfg_default_mode=default cfg_default_loglevel=''
    }
    unset cfg_effective_version
    result=$(agent_reconfigure)
    grep -Fxq 'IPV6=true' <<< "$result"
    grep -Fxq 'DNS_IP_PREFERENCE=prefer-ipv6' <<< "$result"
)

(
    port_in_use() { return 0; }
    has_native_install() { return 0; }
    native_listens_on_port() { return 1; }
    if check_config_port native 32000 >/dev/null 2>&1; then exit 1; fi
    native_listens_on_port() { return 0; }
    check_config_port native 32000
    has_docker_install() { return 1; }
    NONINTERACTIVE=1 CLI_METHOD=docker CLI_VERSION=v5.0.1
    CLI_PORT=32000 CLI_PSK=AgentTestPsk16._-abcdef
    if collect_config docker v5.0.1 host >/dev/null 2>&1; then exit 1; fi
)

(
    systemd_usable() { return 0; }
    systemctl() { [[ "$1" != show ]] || echo 123; }
    ss() { echo 'LISTEN 0 128 0.0.0.0:32000 0.0.0.0:* users:(("other",pid=456,fd=3))'; }
    if native_listens_on_port 32000; then exit 1; fi
    ss() { echo 'LISTEN 0 128 0.0.0.0:32000 0.0.0.0:* users:(("snell",pid=123,fd=3))'; }
    native_listens_on_port 32000
    sleep() { :; }
    systemctl() { return 1; }
    if wait_for_native 32000; then exit 1; fi
)

(
    attempts=$(mktemp)
    trap 'rm -f "$attempts"' EXIT
    printf '0\n' > "$attempts"
    curl() {
        local count
        count=$(< "$attempts")
        printf '%s\n' "$((count + 1))" > "$attempts"
        ((count > 0)) || return 22
        printf '%s\n' 'snell-server-v6.0.0rc10-linux-amd64.zip' 'snell-server-v6.0.0-linux-amd64.zip'
    }
    sleep() { :; }
    [[ "$(get_latest_version)" == 6.0.0 ]]
    [[ "$(< "$attempts")" == 2 ]]
)

# Run the actual publication script, replacing only network and registry commands.
(
    curl() {
        [[ "${FAIL_LOOKUP:-0}" != 1 ]] || return 22
        printf '%s\n' 'snell-server-v5.0.0-linux-amd64.zip' 'snell-server-v5.0.1-linux-amd64.zip' \
            'snell-server-v6.0.0rc10-linux-amd64.zip' 'snell-server-v6.0.0-linux-amd64.zip'
    }
    docker() { printf 'REGISTRY %s\n' "$*"; }
    sleep() { :; }
    export -f curl docker sleep
    export GHCR_OWNER=fixture DOCKER_HUB_USERNAME=fixture
    IMAGE_DIGEST="sha256:$(printf '%064d' 0)"
    export IMAGE_DIGEST
    for version in v5.0.0 v5.0.1 v6.0.0rc10 v6.0.0 v7.0.0; do
        result=$(VERSION="$version" bash "$root/scripts/publish-tags.sh")
        case "$version" in
            v6.0.0)
                [[ "$(grep -c '^REGISTRY ' <<< "$result")" == 4 ]]
                grep -Fq -- '--tag ghcr.io/fixture/snell:latest ' <<< "$result"
                grep -Fq -- '--tag fixture/snell:latest ' <<< "$result"
                grep -Fq -- "snell@$IMAGE_DIGEST" <<< "$result" ;;
            v5.0.1)
                [[ "$(grep -c '^REGISTRY ' <<< "$result")" == 2 ]]
                grep -Fq -- '--tag ghcr.io/fixture/snell:v5 ' <<< "$result"
                ! grep -Fq 'snell:latest' <<< "$result" ;;
            *) ! grep -q '^REGISTRY ' <<< "$result" ;;
        esac
    done
    result=$(VERSION=v6.0.0 DOCKER_HUB_USERNAME='' bash "$root/scripts/publish-tags.sh")
    [[ "$(grep -c '^REGISTRY ' <<< "$result")" == 2 ]]
    status=0
    result=$(VERSION=v6.0.0 FAIL_LOOKUP=1 bash "$root/scripts/publish-tags.sh" 2>&1) || status=$?
    [[ "$status" == 1 ]]
    ! grep -q '^REGISTRY ' <<< "$result"
)

SNELL_ENTRYPOINT_TEST_MODE=1 sh -c '
    . "$1"
    for value in "" "32000," ",32000" "32000,,32001" "999.999.999.999:32000" \
        "[:::]:32000" "[1:2:3:4:5:6:7:8:9]:32000" "[1:2:3]:32000" "[1::2::3]:32000" "65536"; do
        if validate_listen_input "$value"; then echo "Accepted invalid LISTEN=$value" >&2; exit 1; fi
    done
    for value in 10000 65535 "[::]:32000" "[::1]:32000" "[1:2:3:4:5:6:7:8]:32000" \
        "32000,127.0.0.1:32001"; do
        validate_listen_input "$value" || exit 1
    done
    [ "$(parse_listen 6 "32000,127.0.0.1:32001")" = "0.0.0.0:32000, [::]:32000, 127.0.0.1:32001" ]
' _ "$root/entrypoint.sh"

status=0
result=$(bash "$root/download-snell.sh" 2>&1) || status=$?
[[ "$status" == 1 ]]
grep -q '用法:' <<< "$result"
! grep -q 'unbound variable' <<< "$result"
printf 'test_regressions.sh: passed\n'
