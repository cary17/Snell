#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=$(mktemp)
config_dir=""
result_dir=""
trap 'rm -rf "$output" "${config_dir:-}" "${result_dir:-}"' EXIT

if ! timeout 3 bash "$root/Snell.sh" --self-test >"$output" 2>&1; then
    printf 'Snell.sh --self-test failed or blocked:\n' >&2
    cat "$output" >&2
    exit 1
fi

grep -qx 'Snell.sh self-test passed' "$output"
agent_help=$(bash "$root/Snell.sh" --agent-help)
grep -Fqx 'Snell.sh agent interface v1' <<< "$agent_help"
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
rm -rf "$config_dir" "$result_dir"
config_dir=""
result_dir=""
(( $(grep -Fc 'show_install_result native "$version"' "$root/Snell.sh") >= 2 ))
grep -Fq 'show_install_result "native" "$version"' "$root/Snell.sh"
grep -Fq 'show_applied_config "$mode"' "$root/Snell.sh"
printf 'test_snell.sh: passed\n'
