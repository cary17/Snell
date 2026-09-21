#!/usr/bin/env bash
# Fixture globals are consumed by the sourced installer functions.
# shellcheck disable=SC2034
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../Snell.sh
SNELL_SOURCE_ONLY=1 source "$root/Snell.sh"
# shellcheck source=snell-version-output.sh
source "$root/tests/snell-version-output.sh"

[[ "$(printf '%s\n' 6.0.0rc2 6.0.0 6.0.0rc10 6.0.0b4 | sort_snell_versions)" == $'6.0.0b4\n6.0.0rc2\n6.0.0rc10\n6.0.0' ]]
[[ "$(printf '%s\n' 6.0.0 6.0.0-rc1 | sort_snell_versions | tail -n 1)" == 6.0.0 ]]

version_log=$(mktemp)
trap 'rm -f "$version_log"' EXIT
printf '%s\n' '2026-09-20 [server_main] <NOTIFY> snell-server v6.0.0 (Aug  7 2026)' > "$version_log"
snell_binary_reports_version v6.0.0 "$version_log"
snell_binary_reports_version v6.0.0rc2 "$version_log"
for reported in 7.0.0 6.1.0 6.0.1; do
    printf 'snell-server v%s (fixture)\n' "$reported" > "$version_log"
    if snell_binary_reports_version v6.0.0rc2 "$version_log"; then
        echo "Accepted a binary with a different release core: $reported" >&2
        exit 1
    fi
done
printf '%s\n' '2026-09-20 [server_main] <NOTIFY> snell-server v6.0.0rc3 (Aug  7 2026)' > "$version_log"
if snell_binary_reports_version v6.0.0rc2 "$version_log"; then
    echo "Accepted a different binary prerelease suffix" >&2
    exit 1
fi

if snell_binary_reports_version v6.0.0 "$version_log"; then
    echo "Accepted a prerelease binary for a stable request" >&2
    exit 1
fi
printf '%s\n' 'snell-server v6.0.0rc2 (fixture)' > "$version_log"
snell_binary_reports_version v6.0.0rc2 "$version_log"

# A stale stable banner is accepted only for this exact upstream arm64 payload.
known_arm64_sha=a6dceb898ade6da58840bf26499a0747894fb1c6407878139c8d863e7926d297
printf '%s\n' 'snell-server v4.1.0 (fixture)' > "$version_log"
snell_binary_reports_version v4.1.1 "$version_log" linux/arm64 "$known_arm64_sha"
if snell_binary_reports_version v4.1.1 "$version_log"; then
    echo "Accepted stale stable banner without provenance" >&2; exit 1
fi
for wrong_platform in linux/amd64 linux/386 linux/arm/v7; do
    if snell_binary_reports_version v4.1.1 "$version_log" "$wrong_platform" "$known_arm64_sha"; then
        echo "Accepted arm64 banner exception for another platform" >&2; exit 1
    fi
done
if snell_binary_reports_version v4.1.1 "$version_log" linux/arm64 "$(printf '%064d' 0)"; then
    echo "Accepted stale stable banner with another payload" >&2; exit 1
fi
if snell_binary_reports_version v4.1.2 "$version_log" linux/arm64 "$known_arm64_sha"; then
    echo "Applied a known banner exception to another release" >&2; exit 1
fi
printf '%s\n' 'snell-server v4.0.0 (fixture)' > "$version_log"
if snell_binary_reports_version v4.1.1 "$version_log" linux/arm64 "$known_arm64_sha"; then
    echo "Accepted an unrelated banner for the known payload" >&2; exit 1
fi
printf '%s\n' 'snell-server v4.1.1 (fixture)' > "$version_log"
snell_binary_reports_version v4.1.1 "$version_log"

workflow="$root/.github/workflows/build.yml"
triggers=$(sed -n '/^on:/,/^jobs:/p' "$workflow")
grep -Fq '  workflow_dispatch:' <<< "$triggers"
grep -Fq -- "- cron: '0 19 * * *'" <<< "$triggers"
if grep -Eq '^  (push|pull_request|workflow_run|workflow_call):' <<< "$triggers"; then
    echo "Image builds must not be triggered by repository events" >&2; exit 1
fi
test_job=$(sed -n '/^  test:/,/^  check-version:/p' "$workflow")
grep -Fq 'needs: check-version' <<< "$test_job"
grep -Fq "if: needs.check-version.outputs.should_build == 'true'" <<< "$test_job"
build_job=$(sed -n '/^  build-and-push:/,$p' "$workflow")
grep -Fq "if: needs.check-version.outputs.should_build == 'true' && needs.test.result == 'success'" <<< "$build_job"
candidate_stage=$(sed -n '/- name: 准备候选镜像导出/,/- name: 候选镜像摘要/p' "$workflow")
grep -Fq 'push-by-digest=true' <<< "$candidate_stage"
grep -Fq 'name-canonical=true' <<< "$candidate_stage"
grep -Fq 'push=true' <<< "$candidate_stage"
if grep -Eq 'snell:(latest|v[0-9])' <<< "$candidate_stage"; then
    echo "Candidate stage contains a formal tag" >&2
    exit 1
fi
verify_line=$(grep -n -m1 'name: 验证注册表制品' "$workflow" | cut -d: -f1)
publish_line=$(grep -n -m1 'name: 发布正式版本标签' "$workflow" | cut -d: -f1)
((verify_line < publish_line))

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
    registry_calls=$(mktemp)
    export registry_calls
    trap 'rm -f "$registry_calls"' EXIT
    curl() {
        [[ "${FAIL_LOOKUP:-0}" != 1 ]] || return 22
        printf '%s\n' 'snell-server-v5.0.0-linux-amd64.zip' 'snell-server-v5.0.1-linux-amd64.zip' \
            'snell-server-v6.0.0rc10-linux-amd64.zip' 'snell-server-v6.0.0-linux-amd64.zip'
    }
    docker() {
        printf '%s\n' "$*" >> "$registry_calls"
        if [[ "$*" == *'imagetools inspect'* ]]; then
            [[ "${MISSING_CANDIDATE:-0}" != 1 ]] || return 1
            [[ "$*" != *'docker.io/'* || "${DOCKERHUB_MISSING:-0}" != 1 ]] || return 1
            if [[ "$*" != *'docker.io/'* && "${GHCR_MISMATCH:-0}" == 1 ]] || \
                [[ "$*" == *'docker.io/'* && "${DOCKERHUB_MISMATCH:-0}" == 1 ]]; then
                printf 'sha256:%064d\n' 1
            else
                printf '%s\n' "$IMAGE_DIGEST"
            fi
        fi
    }
    sleep() { :; }
    export -f curl docker sleep
    export GHCR_OWNER=fixture DOCKER_HUB_USERNAME=fixture
    IMAGE_DIGEST="sha256:$(printf '%064d' 0)"
    export IMAGE_DIGEST
    write_count() {
        if grep -Fq 'buildx imagetools create' "$registry_calls"; then
            grep -Fc 'buildx imagetools create' "$registry_calls"
        else
            printf '0\n'
        fi
    }
    assert_tag() {
        grep -Fq -- "--tag $1 " "$registry_calls"
    }
    assert_no_tag() {
        if grep -Fq -- "--tag $1 " "$registry_calls"; then
            echo "Unexpected formal tag: $1" >&2
            exit 1
        fi
    }
    assert_no_writes() {
        [[ "$(write_count)" == 0 ]]
    }
    run_publish() {
        : > "$registry_calls"
        VERSION=$1 bash "$root/scripts/publish-tags.sh" >/dev/null
    }

    run_publish v5.0.0
    [[ "$(write_count)" == 2 ]]
    assert_tag ghcr.io/fixture/snell:v5.0.0
    assert_tag docker.io/fixture/snell:v5.0.0
    assert_no_tag ghcr.io/fixture/snell:v5
    assert_no_tag ghcr.io/fixture/snell:latest
    assert_no_tag docker.io/fixture/snell:v5
    assert_no_tag docker.io/fixture/snell:latest

    run_publish v5.0.1
    [[ "$(write_count)" == 2 ]]
    assert_tag ghcr.io/fixture/snell:v5.0.1
    assert_tag ghcr.io/fixture/snell:v5
    assert_tag docker.io/fixture/snell:v5.0.1
    assert_tag docker.io/fixture/snell:v5
    assert_no_tag ghcr.io/fixture/snell:latest

    run_publish v6.0.0
    [[ "$(write_count)" == 2 ]]
    for repository in ghcr.io/fixture/snell docker.io/fixture/snell; do
        assert_tag "$repository:v6.0.0"
        assert_tag "$repository:v6"
        assert_tag "$repository:latest"
    done

    : > "$registry_calls"
    VERSION=v6.0.0 DOCKER_HUB_USERNAME='' bash "$root/scripts/publish-tags.sh" >/dev/null
    [[ "$(write_count)" == 1 ]]
    assert_tag ghcr.io/fixture/snell:v6.0.0
    assert_tag ghcr.io/fixture/snell:v6
    assert_tag ghcr.io/fixture/snell:latest
    if grep -Fq 'docker.io/fixture/snell' "$registry_calls"; then
        echo "Docker Hub was used while disabled" >&2
        exit 1
    fi

    for scenario in invalid-input failed-lookup missing-candidate ghcr-mismatch dockerhub-missing dockerhub-mismatch; do
        : > "$registry_calls"
        status=0
        case "$scenario" in
            invalid-input) VERSION=v6.0.0 IMAGE_DIGEST=invalid bash "$root/scripts/publish-tags.sh" >/dev/null 2>&1 || status=$? ;;
            failed-lookup) VERSION=v6.0.0 FAIL_LOOKUP=1 bash "$root/scripts/publish-tags.sh" >/dev/null 2>&1 || status=$? ;;
            missing-candidate) VERSION=v6.0.0 MISSING_CANDIDATE=1 bash "$root/scripts/publish-tags.sh" >/dev/null 2>&1 || status=$? ;;
            ghcr-mismatch) VERSION=v6.0.0 GHCR_MISMATCH=1 bash "$root/scripts/publish-tags.sh" >/dev/null 2>&1 || status=$? ;;
            dockerhub-missing) VERSION=v6.0.0 DOCKERHUB_MISSING=1 bash "$root/scripts/publish-tags.sh" >/dev/null 2>&1 || status=$? ;;
            dockerhub-mismatch) VERSION=v6.0.0 DOCKERHUB_MISMATCH=1 bash "$root/scripts/publish-tags.sh" >/dev/null 2>&1 || status=$? ;;
        esac
        [[ "$status" == 1 ]]
        assert_no_writes
    done
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
