#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp)
config_dir=""
result_dir=""
version_fixture=""
config_items=""
trap 'rm -rf "$output" "${config_dir:-}" "${result_dir:-}" "${version_fixture:-}" "${config_items:-}"' EXIT

if ! timeout 3 bash "$root/Snell.sh" --self-test >"$output" 2>&1; then
    printf 'Snell.sh --self-test failed or blocked:\n' >&2
    cat "$output" >&2
    exit 1
fi

grep -qx 'Snell.sh self-test passed' "$output"
agent_help=$(bash "$root/Snell.sh" --agent-help)
grep -Fq 'Snell.sh agent interface v1' <<< "$agent_help"
agent_v6_auto=$(bash "$root/Snell.sh" --agent-install --method docker --version v6.0.0rc2 --port 32000 --psk AgentTestPsk16._-abcdef \
    --ipv6 false --dns-ip-preference prefer-ipv6 --conflict-policy auto --dry-run 2>&1)
grep -Fq 'DNS_IP_PREFERENCE=prefer-ipv6' <<< "$agent_v6_auto"
grep -Fq 'IPV6=true' <<< "$agent_v6_auto"
agent_v6_derived=$(bash "$root/Snell.sh" --agent-install --method docker --version v6.0.0rc2 --port 32000 --psk AgentTestPsk16._-abcdef \
    --dns-ip-preference prefer-ipv6 --conflict-policy resubmit --dry-run 2>&1)
grep -Fq 'DNS_IP_PREFERENCE=prefer-ipv6' <<< "$agent_v6_derived"
grep -Fq 'IPV6=true' <<< "$agent_v6_derived"
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
grep -Fq -- '--agent-config' <<< "$agent_help"
grep -Fq -- 'LOGLEVEL' <<< "$agent_help"
grep -Fq '日志等级不是 Snell 的 snell.conf 配置项' <<< "$agent_help"
config_dir=$(mktemp -d)
printf '[snell-server]\nlisten = :::32000\npsk = AgentTestPsk16._-abcdef\n' > "$config_dir/snell.conf"
config_output=$(SNELL_SOURCE_ONLY=1 SNELL_CONFIG_TEST_FILE="$config_dir/snell.conf" bash -c 'source "$1"; has_native_install(){ return 0; }; get_mode(){ printf "native\\n"; }; view_config' _ "$root/Snell.sh")
grep -Fq 'psk = AgentTestPsk16._-abcdef' <<< "$config_output"
native_result_output=$(SNELL_SOURCE_ONLY=1 SNELL_CONFIG_TEST_FILE="$config_dir/snell.conf" bash -c 'source "$1"; cfg_port=32000; cfg_psk=AgentTestPsk16._-abcdef; cfg_ipv6=false; cfg_dns=""; cfg_dns_pref=""; cfg_egress=""; cfg_obfs=""; cfg_host=""; cfg_mode=""; show_install_result native v5.0.1' _ "$root/Snell.sh" 2>&1)
grep -Fq 'Snell 已生效配置' <<< "$native_result_output"
grep -Fq '[snell-server]' <<< "$native_result_output"
grep -Fq 'listen = :::32000' <<< "$native_result_output"
! grep -Fq '安装方式:' <<< "$native_result_output"
! grep -Fq '配置文件:' <<< "$native_result_output"
result_dir=$(mktemp -d)
printf 'LISTEN=32000\nPSK=AgentTestPsk16._-abcdef\nDNS=1.1.1.1, 8.8.8.8\nEGRESS_INTERFACE=eth0\n' > "$result_dir/.env"
result_output=$(SNELL_SOURCE_ONLY=1 SNELL_CONFIG_TEST_FILE="$result_dir/.env" bash -c 'source "$1"; cfg_port=32000; cfg_psk=AgentTestPsk16._-abcdef; cfg_ipv6=false; cfg_dns="1.1.1.1, 8.8.8.8"; cfg_dns_pref=""; cfg_egress=eth0; cfg_obfs=""; cfg_host=""; cfg_mode=""; show_install_result docker v5.0.1 ghcr.io/cary17/snell:v5.0.1' _ "$root/Snell.sh" 2>&1)
grep -Fq 'Snell 已生效配置' <<< "$result_output"
grep -Fq 'LISTEN=32000' <<< "$result_output"
grep -Fq 'PSK=AgentTestPsk16._-abcdef' <<< "$result_output"
grep -Fq 'EGRESS_INTERFACE=eth0' <<< "$result_output"
! grep -Fq '安装方式:' <<< "$result_output"
! grep -Fq '配置文件:' <<< "$result_output"
agent_result_output=$(SNELL_SOURCE_ONLY=1 SNELL_CONFIG_TEST_FILE="$result_dir/.env" bash -c 'source "$1"; NONINTERACTIVE=1; cfg_port=32000; cfg_psk=AgentTestPsk16._-abcdef; cfg_ipv6=false; cfg_dns=""; cfg_dns_pref=""; cfg_egress=""; cfg_obfs=""; cfg_host=""; cfg_mode=""; show_install_result docker v5.0.1 ghcr.io/cary17/snell:v5.0.1' _ "$root/Snell.sh" 2>&1)
grep -Fq 'Agent 安装信息:' <<< "$agent_result_output"
grep -Fq '安装方式: Docker' <<< "$agent_result_output"
grep -Fq '持久化配置: /opt/snell/.env' <<< "$agent_result_output"
source_output=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; cfg_port=32000; cfg_psk=AgentTestPsk16._-abcdef; cfg_ipv6=false; cfg_dns=""; cfg_dns_pref=""; cfg_egress=""; cfg_obfs=""; cfg_host=""; cfg_mode=""; cfg_loglevel=trace; render_snell_config v5.0.1 32000 AgentTestPsk16._-abcdef false "" "" "" "" "" "" "" trace' _ "$root/Snell.sh")
! grep -Fq '^log =' <<< "$source_output"
grep -Fq -- '-l trace' <<< "$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; cfg_loglevel=trace; render_native_command' _ "$root/Snell.sh")"
default_command=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; cfg_loglevel=""; render_native_command' _ "$root/Snell.sh")
grep -Fqx '/usr/local/bin/snell-server -c /etc/snell/snell.conf' <<< "$default_command"
! grep -Fq -- ' -l ' <<< "$default_command"
docker_output=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; render_env_file 32000 AgentTestPsk16._-abcdef "" "" "" "" "" "" "" trace' _ "$root/Snell.sh")
grep -Fqx 'LOGLEVEL=trace' <<< "$docker_output"
default_docker_output=$(SNELL_SOURCE_ONLY=1 bash -c 'source "$1"; render_env_file 32000 AgentTestPsk16._-abcdef "" "" "" "" "" "" "" ""' _ "$root/Snell.sh")
! grep -Fq '^LOGLEVEL=' <<< "$default_docker_output"
config_items=$(mktemp)
awk -v sn_version=v6.0.0rc2 -f "$root/scripts/generate-config-items.awk" "$root/snell-config.yml" > "$config_items"
for preference in prefer-ipv4 prefer-ipv6 ipv4-only ipv6-only; do
    generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef DNS_IP_PREFERENCE="$preference" \
        CONFIG_FILE="$config_dir/snell.conf" CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
        sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_FILE CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
    grep -Fqx "dns-ip-preference = $preference" <<< "$generated"
    case "$preference" in
        prefer-ipv4|ipv4-only) grep -Fqx 'ipv6 = false' <<< "$generated" ;;
        prefer-ipv6|ipv6-only) grep -Fqx 'ipv6 = true' <<< "$generated" ;;
    esac
done
default_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef DNS_IP_PREFERENCE=default \
    CONFIG_FILE="$config_dir/snell.conf" CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_FILE CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
! grep -Fq 'dns-ip-preference =' <<< "$default_generated"
! grep -Fq 'ipv6 =' <<< "$default_generated"
unset_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef \
    CONFIG_FILE="$config_dir/snell.conf" CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_FILE CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
! grep -Fq 'dns-ip-preference =' <<< "$unset_generated"
! grep -Fq 'ipv6 =' <<< "$unset_generated"
explicit_true=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef IPV6=true DNS_IP_PREFERENCE=default \
    CONFIG_FILE="$config_dir/snell.conf" CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_FILE CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
grep -Fqx 'ipv6 = true' <<< "$explicit_true"
! grep -Fq 'dns-ip-preference =' <<< "$explicit_true"
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
! grep -Fq 'dns-ip-preference =' <<< "$invalid_pref_generated"
! grep -Fq 'ipv6 =' <<< "$invalid_pref_generated"
invalid_mode_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef MODE=banana \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
grep -Fqx 'mode = default' <<< "$invalid_mode_generated"
invalid_listen_generated=$(env -i PATH="$PATH" LISTEN=9999 PSK=AgentTestPsk16._-abcdef \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
! grep -Eq '^listen = .*:9999([, ]|$)' <<< "$invalid_listen_generated"
for invalid_listen in banana bad:port '9999,32000' '32000,'; do
    invalid_listen_generated=$(env -i PATH="$PATH" LISTEN="$invalid_listen" PSK=AgentTestPsk16._-abcdef \
        CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
        sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
    ! grep -Fq "$invalid_listen" <<< "$(grep '^listen =' <<< "$invalid_listen_generated")"
done
invalid_psk_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=short \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
generated_psk=$(awk -F' = ' '/^psk =/{print $2}' <<< "$invalid_psk_generated")
(( ${#generated_psk} >= 16 && ${#generated_psk} <= 180 ))
unknown_env_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef SECRET_TOKEN=redacted-test-value \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh")
! grep -Fq 'secret-token =' <<< "$unknown_env_generated"
grep -Fq 'if [ ! -f "$CONFIG_FILE" ]; then' "$root/entrypoint.sh"
grep -Fq 'Existing config found, using it as-is...' "$root/entrypoint.sh"
psk_lengths=$(env -i PATH="$PATH" SNELL_ENTRYPOINT_TEST_MODE=1 sh -c '. "$1"; i=0; while [ "$i" -lt 200 ]; do value=$(random_psk); printf "%s\n" "${#value}"; i=$((i + 1)); done' _ "$root/entrypoint.sh")
! awk '$1 < 16 || $1 > 180 { exit 1 }' <<< "$psk_lengths"
v6_obfs_generated=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef DNS_IP_PREFERENCE=prefer-ipv4 OBFS=http HOST=example.com \
    CONFIG_ITEMS_FILE="$config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=6; write_config_items' _ "$root/entrypoint.sh" 2>&1)
grep -Fq 'Warning: ignoring OBFS/HOST' <<< "$v6_obfs_generated"
! grep -Eq '^(obfs|host) =' <<< "$v6_obfs_generated"
if bash "$root/Snell.sh" --agent-install --method docker --version v6.0.0rc2 --port 32000 --psk AgentTestPsk16._-abcdef \
    --dns-ip-preference prefer-ipv4 --obfs http --host example.com --dry-run >/dev/null 2>&1; then
    printf 'agent v6 OBFS/HOST unexpectedly succeeded\n' >&2
    exit 1
fi
v5_obfs_items=$(awk -v sn_version=v5.0.1 -f "$root/scripts/generate-config-items.awk" "$root/snell-config.yml")
grep -Fq 'CONFIG_ITEM_NAMES="${CONFIG_ITEM_NAMES} obfs"' <<< "$v5_obfs_items"
grep -Fq 'CONFIG_ITEM_NAMES="${CONFIG_ITEM_NAMES} host"' <<< "$v5_obfs_items"
v6_obfs_items=$(awk -v sn_version=v6.0.0rc2 -f "$root/scripts/generate-config-items.awk" "$root/snell-config.yml")
! grep -Fq 'CONFIG_ITEM_NAMES="${CONFIG_ITEM_NAMES} obfs"' <<< "$v6_obfs_items"
! grep -Fq 'CONFIG_ITEM_NAMES="${CONFIG_ITEM_NAMES} host"' <<< "$v6_obfs_items"
v5_config_items=$(mktemp)
awk -v sn_version=v5.0.1 -f "$root/scripts/generate-config-items.awk" "$root/snell-config.yml" > "$v5_config_items"
v5_bad_obfs=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef OBFS=tls HOST=example.com \
    CONFIG_ITEMS_FILE="$v5_config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=5; write_config_items' _ "$root/entrypoint.sh" 2>&1)
! grep -Eq '^(obfs|host) =' <<< "$v5_bad_obfs"
v5_missing_host=$(env -i PATH="$PATH" LISTEN=32000 PSK=AgentTestPsk16._-abcdef OBFS=http \
    CONFIG_ITEMS_FILE="$v5_config_items" SNELL_ENTRYPOINT_TEST_MODE=1 \
    sh -c '. "$1"; . "$CONFIG_ITEMS_FILE"; unset CONFIG_ITEMS_FILE SNELL_ENTRYPOINT_TEST_MODE; MAJOR_VERSION=5; write_config_items' _ "$root/entrypoint.sh" 2>&1)
! grep -Eq '^(obfs|host) =' <<< "$v5_missing_host"
rm -f "$v5_config_items"
rm -rf "$config_dir" "$result_dir" "$config_items"
config_items=""
config_dir=""
result_dir=""
(( $(grep -Fc 'show_install_result native "$version"' "$root/Snell.sh") >= 2 ))
grep -Fq 'show_install_result "native" "$version"' "$root/Snell.sh"
grep -Fq 'show_applied_config "$mode"' "$root/Snell.sh"
version_fixture=$(mktemp)
printf '%s\n' \
    'https://dl.nssurge.com/snell/snell-server-v6.0.0b4-linux-amd64.zip' \
    'https://dl.nssurge.com/snell/snell-server-v6.0.0rc-linux-amd64.zip' \
    'https://dl.nssurge.com/snell/snell-server-v6.0.0rc2-linux-amd64.zip' \
    'https://dl.nssurge.com/snell/snell-server-v6.0.0rc10-linux-amd64.zip' \
    'https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip' > "$version_fixture"
grep -Fq "grep -oP 'snell-server-v\\K[0-9]+\\.[0-9]+\\.[0-9]+(?:[a-z]+[0-9]*)?'" "$root/.github/workflows/build.yml"
version_output=$(grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+(?:[a-z]+[0-9]*)?' "$version_fixture" | sort -Vu)
expected_versions=$'5.0.1\n6.0.0b4\n6.0.0rc\n6.0.0rc2\n6.0.0rc10'
[[ "$version_output" == "$expected_versions" ]]
if grep -Fqx '6.0.0r' <<< "$version_output"; then exit 1; fi
printf 'test_snell.sh: passed\n'
