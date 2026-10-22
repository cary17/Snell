#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp)
version_fixture=""
config_items=""
v5_config_items=""
trap 'rm -f "$output" "${version_fixture:-}" "${config_items:-}" "${v5_config_items:-}"' EXIT

assert_absent() {
    local status
    if grep "$@"; then
        printf 'Unexpected grep match: %s\n' "$*" >&2
        return 1
    else
        status=$?
        if [ "$status" -ne 1 ]; then
            printf 'grep assertion failed (exit %s): %s\n' "$status" "$*" >&2
            return 1
        fi
    fi
    return 0
}

if ! timeout 3 bash "$root/Snell.sh" --self-test >"$output" 2>&1; then
    printf 'Snell.sh --self-test failed or blocked:\n' >&2
    cat "$output" >&2
    exit 1
fi

agent_v6_auto=$(bash "$root/Snell.sh" --agent-install --method docker --version v6.0.0rc2 --port 32000 --psk AgentTestPsk16._-abcdef \
    --ipv6 false --dns-ip-preference prefer-ipv6 --conflict-policy auto --dry-run 2>&1)
grep -Fq 'DNS_IP_PREFERENCE=prefer-ipv6' <<< "$agent_v6_auto"
grep -Fq 'IPV6=true' <<< "$agent_v6_auto"
if bash "$root/Snell.sh" --agent-install --method docker --version v6.0.0rc2 --port 32000 --psk AgentTestPsk16._-abcdef \
    --ipv6 false --dns-ip-preference prefer-ipv6 --conflict-policy resubmit --dry-run >/dev/null 2>&1; then
    printf 'resubmit policy unexpectedly accepted conflict\n' >&2
    exit 1
fi
if bash "$root/Snell.sh" --agent-install --method docker --version latest --port 32000 --psk AgentTestPsk16._-abcdef \
    --dns-ip-preference prefer-ipv6 --dry-run >/dev/null 2>&1; then
    printf 'latest unexpectedly accepted version-specific config\n' >&2
    exit 1
fi
latest_generic=$(bash "$root/Snell.sh" --agent-install --method docker --version latest --port 32000 --psk AgentTestPsk16._-abcdef --dry-run)
grep -Fq 'VERSION=latest' <<< "$latest_generic"
agent_output=$(printf '%s\n' 'PORT=32000' 'PSK=AgentTestPsk16._-abcdef' | bash "$root/Snell.sh" --agent-install --method docker --version v5.0.1 --config-stdin --dry-run)
grep -Fq 'DRY-RUN' <<< "$agent_output"
grep -Fq 'LISTEN=32000' <<< "$agent_output"
source_output=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; cfg_port=32000; cfg_psk=AgentTestPsk16._-abcdef; cfg_ipv6=false; cfg_dns=""; cfg_dns_pref=""; cfg_egress=""; cfg_obfs=""; cfg_host=""; cfg_mode=""; cfg_loglevel=trace; render_snell_config v5.0.1 32000 AgentTestPsk16._-abcdef false "" "" "" "" "" "" "" trace' _ "$root/Snell.sh")
assert_absent -q '^log =' <<< "$source_output"
grep -Fq -- '-l trace' <<< "$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; cfg_loglevel=trace; render_native_command' _ "$root/Snell.sh")"
default_command=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; cfg_loglevel=""; render_native_command' _ "$root/Snell.sh")
grep -Fqx '/usr/local/bin/snell-server -c /etc/snell/snell.conf' <<< "$default_command"
assert_absent -Fq -- ' -l ' <<< "$default_command"
docker_output=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; render_env_file 32000 AgentTestPsk16._-abcdef "" "" "" "" "" "" "" trace' _ "$root/Snell.sh")
grep -Fqx 'LOGLEVEL=trace' <<< "$docker_output"
default_docker_output=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; render_env_file 32000 AgentTestPsk16._-abcdef "" "" "" "" "" "" "" ""' _ "$root/Snell.sh")
assert_absent -q '^LOGLEVEL=' <<< "$default_docker_output"
config_items=$(mktemp)
awk -v sn_version=v6.0.0rc2 -f "$root/scripts/generate-config-items.awk" "$root/snell-config.yml" > "$config_items"
for preference in prefer-ipv4 prefer-ipv6 ipv4-only ipv6-only; do
    generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef DNS_IP_PREFERENCE="$preference" \
        CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
        sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_FILE CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
    grep -Fqx "dns-ip-preference = $preference" <<< "$generated"
    case "$preference" in
        prefer-ipv4|ipv4-only) grep -Fqx 'ipv6 = false' <<< "$generated" ;;
        prefer-ipv6|ipv6-only) grep -Fqx 'ipv6 = true' <<< "$generated" ;;
    esac
done
default_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef DNS_IP_PREFERENCE=default \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_FILE CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
assert_absent -Fq 'dns-ip-preference =' <<< "$default_generated"
assert_absent -Fq 'ipv6 =' <<< "$default_generated"
unset_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_FILE CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
assert_absent -Fq 'dns-ip-preference =' <<< "$unset_generated"
assert_absent -Fq 'ipv6 =' <<< "$unset_generated"
explicit_true=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef IPV6=true DNS_IP_PREFERENCE=default \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_FILE CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
grep -Fqx 'ipv6 = true' <<< "$explicit_true"
assert_absent -Fq 'dns-ip-preference =' <<< "$explicit_true"
for conflict_case in \
    'false prefer-ipv6' \
    'false ipv6-only' \
    'true prefer-ipv4' \
    'true ipv4-only'; do
    read -r conflict_ipv6 conflict_pref <<< "$conflict_case"
    conflict_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef IPV6="$conflict_ipv6" DNS_IP_PREFERENCE="$conflict_pref" \
        CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
        sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
    grep -Fq "Warning: preserving conflicting IPV6=$conflict_ipv6 and DNS_IP_PREFERENCE=$conflict_pref" <<< "$conflict_generated"
    grep -Fqx "dns-ip-preference = $conflict_pref" <<< "$conflict_generated"
    grep -Fqx "ipv6 = $conflict_ipv6" <<< "$conflict_generated"
done
choice_one_persisted=$(printf '%s\n' 1 true prefer-ipv6 | bash "$root/Snell.sh" --agent-install --method docker --version v6.0.0rc2 \
    --port 32000 --psk AgentTestPsk16._-abcdef --ipv6 false --dns-ip-preference prefer-ipv6 --conflict-policy prompt --dry-run 2>&1)
grep -Fq 'DNS_IP_PREFERENCE=prefer-ipv6' <<< "$choice_one_persisted"
grep -Fq 'IPV6=true' <<< "$choice_one_persisted"
invalid_ipv6_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef IPV6=banana DNS_IP_PREFERENCE=prefer-ipv6 \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
grep -Fqx 'dns-ip-preference = prefer-ipv6' <<< "$invalid_ipv6_generated"
grep -Fqx 'ipv6 = true' <<< "$invalid_ipv6_generated"
invalid_pref_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef DNS_IP_PREFERENCE=banana \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
assert_absent -Fq 'dns-ip-preference =' <<< "$invalid_pref_generated"
assert_absent -Fq 'ipv6 =' <<< "$invalid_pref_generated"
invalid_mode_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef MODE=banana \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
grep -Fqx 'mode = default' <<< "$invalid_mode_generated"
invalid_listen_generated=$(env -i PATH="$PATH" LISTEN=9999 PSK=AgentTestPsk16._-abcdef \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
assert_absent -Eq '^listen = .*:9999([, ]|$)' <<< "$invalid_listen_generated"
for invalid_listen in banana bad:port '9999,32000' '32000,'; do
    invalid_listen_generated=$(env -i PATH="$PATH" LISTEN="$invalid_listen" PSK=AgentTestPsk16._-abcdef \
        CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
        sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
    assert_absent -Fq "$invalid_listen" <<< "$(grep '^listen =' <<< "$invalid_listen_generated")"
done
invalid_psk_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=short \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
generated_psk=$(awk -F' = ' '/^psk =/{print $2}' <<< "$invalid_psk_generated")
(( ${#generated_psk} >= 16 && ${#generated_psk} <= 180 ))
unknown_env_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef SECRET_TOKEN=redacted-test-value \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
assert_absent -Fq 'secret-token =' <<< "$unknown_env_generated"
v6_obfs_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef DNS_IP_PREFERENCE=prefer-ipv4 OBFS=http HOST=example.com \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
grep -Fq 'Warning: ignoring OBFS/HOST' <<< "$v6_obfs_generated"
assert_absent -Eq '^(obfs|host) =' <<< "$v6_obfs_generated"
if bash "$root/Snell.sh" --agent-install --method docker --version v6.0.0rc2 --port 32000 --psk AgentTestPsk16._-abcdef \
    --dns-ip-preference prefer-ipv4 --obfs http --host example.com --dry-run >/dev/null 2>&1; then
    printf 'agent v6 OBFS/HOST unexpectedly succeeded\n' >&2
    exit 1
fi
v5_config_items=$(mktemp)
awk -v sn_version=v5.0.1 -f "$root/scripts/generate-config-items.awk" "$root/snell-config.yml" > "$v5_config_items"
v5_bad_obfs=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef OBFS=tls HOST=example.com \
    CONFIG_ITEMS_FILE="$v5_config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=5; write_config_items' _ "$root/entrypoint.sh" 2>&1)
assert_absent -Eq '^(obfs|host) =' <<< "$v5_bad_obfs"
v5_missing_host=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef OBFS=http \
    CONFIG_ITEMS_FILE="$v5_config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=5; write_config_items' _ "$root/entrypoint.sh" 2>&1)
assert_absent -Eq '^(obfs|host) =' <<< "$v5_missing_host"
rm -f "$v5_config_items"
v5_config_items=""
version_fixture=$(mktemp)
printf '%s\n' \
    'https://dl.nssurge.com/snell/snell-server-v6.0.0b4-linux-amd64.zip' \
    'https://dl.nssurge.com/snell/snell-server-v6.0.0rc-linux-amd64.zip' \
    'https://dl.nssurge.com/snell/snell-server-v6.0.0rc2-linux-amd64.zip' \
    'https://dl.nssurge.com/snell/snell-server-v6.0.0rc10-linux-amd64.zip' \
    'https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip' > "$version_fixture"
version_output=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; fixture=$2; curl(){ cat "$fixture"; }; get_official_versions' _ "$root/Snell.sh" "$version_fixture")
expected_versions=$'5.0.1\n6.0.0b4\n6.0.0rc\n6.0.0rc2\n6.0.0rc10'
[[ "$version_output" == "$expected_versions" ]]
if grep -Fqx '6.0.0r' <<< "$version_output"; then exit 1; fi
bash "$root/tests/test_failure_paths.sh"
bash "$root/tests/test_archive_validation.sh"
bash "$root/tests/test_publish_state.sh"
bash "$root/tests/test_regressions.sh"
printf 'test_snell.sh: passed\n'
