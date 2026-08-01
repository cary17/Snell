#!/usr/bin/env bash
# Snell host/Docker installer and manager.
# Native mode installs the official Snell release archive and manages systemd/OpenRC.

set -Eeuo pipefail

readonly SCRIPT_VERSION="3.0"
readonly SNELL_BIN="/usr/local/bin/snell-server"
readonly SNELL_CONFIG_DIR="/etc/snell"
readonly SNELL_CONFIG_FILE="${SNELL_CONFIG_DIR}/snell.conf"
readonly SNELL_LOGLEVEL_FILE="${SNELL_CONFIG_DIR}/loglevel"
readonly SNELL_SERVICE_FILE="/etc/systemd/system/snell.service"
readonly SNELL_INIT_FILE="/etc/init.d/snell"
readonly SNELL_USER="snell"
readonly SNELL_GROUP="snell"
readonly STATE_DIR="/var/lib/snell"
readonly STATE_FILE="${STATE_DIR}/install-mode"
readonly DOCKER_DIR="/opt/snell"
readonly DOCKER_COMPOSE_FILE="${DOCKER_DIR}/docker-compose.yml"
readonly DOCKER_ENV_FILE="${DOCKER_DIR}/.env"
readonly GITHUB_REPOSITORY="cary17/Snell"
readonly OFFICIAL_BASE="https://dl.nssurge.com/snell"
readonly BACKUP_BASE="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/main/Version"
readonly RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"
readonly IMAGE_GHCR="ghcr.io/cary17/snell"
readonly IMAGE_DOCKERHUB="cary17/snell"

TUI_TOOL="none"
COMPOSE_CMD=()
SERVICE_KIND="manual"
NONINTERACTIVE=0
CLI_ACTION=""
CLI_CONFIG_FILE=""
CLI_CONFIG_STDIN=0
CLI_DRY_RUN=0
CLI_METHOD=""
CLI_VERSION=""
CLI_NETWORK="host"
CLI_REGISTRY="auto"
CLI_PORT=""
CLI_PSK=""
CLI_IPV6="false"
CLI_DNS=""
CLI_DNS_PREF="prefer-ipv4"
CLI_EGRESS=""
CLI_OBFS=""
CLI_HOST=""
CLI_MODE="default"
CLI_LOGLEVEL=""
CLI_ALPINE_FALLBACK="abort"
CLI_YES=0
CLI_SET_IPV6=0
CLI_SET_DNS_PREF=0
CLI_SET_MODE=0
CLI_SET_OBFS=0
CLI_SET_HOST=0
CLI_SET_DNS=0
CLI_SET_EGRESS=0
CLI_SET_PORT=0
CLI_SET_PSK=0
CLI_SET_METHOD=0
CLI_SET_VERSION=0
CLI_SET_NETWORK=0
CLI_SET_LOGLEVEL=0

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    NC=""
fi

info() { printf '%s[INFO]%s %s\n' "$GREEN" "$NC" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
error() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; }
success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*" >&2; }
title() {
    printf '\n%s============================================================%s\n' "$CYAN" "$NC" >&2
    printf '%s  %s%s\n' "$CYAN" "$*" "$NC" >&2
    printf '%s============================================================%s\n' "$CYAN" "$NC" >&2
}
die() { error "$*"; return 1; }

clear_screen() {
    if [[ -t 1 && -n "${TERM:-}" && "${TERM:-dumb}" != "dumb" ]] && command -v clear >/dev/null 2>&1; then
        clear || true
    fi
}

pause_screen() {
    [[ -t 0 ]] || return 0
    printf '\n按任意键继续...' >&2
    IFS= read -r -n 1 -s _pause_key || true
    printf '\n' >&2
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

init_tui() {
    if [[ -t 0 && -t 1 ]] && command_exists whiptail; then
        TUI_TOOL="whiptail"
    elif [[ -t 0 && -t 1 ]] && command_exists dialog; then
        TUI_TOOL="dialog"
    else
        TUI_TOOL="none"
    fi
}

tui_message() {
    local message="$1" heading="${2:-Snell}"
    case "$TUI_TOOL" in
        whiptail) whiptail --title "$heading" --msgbox "$message" 12 78 || true ;;
        dialog) dialog --stdout --title "$heading" --msgbox "$message" 12 78 >/dev/null || true ;;
        *) printf '\n%s\n' "$message" >&2 ;;
    esac
}

tui_yesno() {
    local message="$1" default="${2:-n}" answer
    if ((NONINTERACTIVE)); then
        ((CLI_YES == 1))
        return
    fi
    case "$TUI_TOOL" in
        whiptail)
            if [[ "$default" == "y" ]]; then
                whiptail --title "Snell" --yesno "$message" 10 78
            else
                whiptail --defaultno --title "Snell" --yesno "$message" 10 78
            fi
            ;;
        dialog)
            if [[ "$default" == "y" ]]; then
                dialog --stdout --title "Snell" --yesno "$message" 10 78 >/dev/null
            else
                dialog --stdout --defaultno --title "Snell" --yesno "$message" 10 78 >/dev/null
            fi
            ;;
        *)
            if [[ "$default" == "y" ]]; then
                printf '%s [Y/n]: ' "$message" >&2
            else
                printf '%s [y/N]: ' "$message" >&2
            fi
            IFS= read -r answer || return 1
            answer="${answer:-$default}"
            [[ "$answer" =~ ^[Yy]$ ]]
            ;;
    esac
}

tui_input() {
    local message="$1" default="${2:-}" answer
    case "$TUI_TOOL" in
        whiptail) whiptail --title "Snell" --inputbox "$message" 10 78 "$default" 3>&1 1>&2 2>&3 ;;
        dialog) dialog --stdout --title "Snell" --inputbox "$message" 10 78 "$default" ;;
        *)
            printf '%s' "$message" >&2
            [[ -n "$default" ]] && printf ' [%s]' "$default" >&2
            printf ': ' >&2
            IFS= read -r answer || return 1
            printf '%s\n' "${answer:-$default}"
            ;;
    esac
}

tui_menu() {
    local heading="$1" message="$2" default="$3"
    shift 3
    local options=("$@") answer i
    case "$TUI_TOOL" in
        whiptail)
            whiptail --title "$heading" --default-item "$default" --menu "$message" 18 82 8 "${options[@]}" 3>&1 1>&2 2>&3
            ;;
        dialog)
            dialog --stdout --title "$heading" --default-item "$default" --menu "$message" 18 82 8 "${options[@]}"
            ;;
        *)
            printf '\n%s\n' "$message" >&2
            for ((i = 0; i < ${#options[@]}; i += 2)); do
                printf '  %s) %s\n' "${options[i]}" "${options[i + 1]}" >&2
            done
            printf '请选择 [%s]: ' "$default" >&2
            IFS= read -r answer || return 1
            answer="${answer:-$default}"
            for ((i = 0; i < ${#options[@]}; i += 2)); do
                if [[ "$answer" == "${options[i]}" ]]; then
                    printf '%s\n' "$answer"
                    return 0
                fi
            done
            error "无效选择: $answer"
            return 1
            ;;
    esac
}

normalize_version() {
    local value="${1#v}"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+[[:alnum:]._-]*$ ]] || return 1
    printf 'v%s\n' "$value"
}

is_exact_version() {
    local value="${1#v}"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+[[:alnum:]._-]*$ ]]
}

is_docker_tag() {
    local value="${1:-}"
    [[ "$value" == "latest" || "$value" =~ ^v?[0-9]+$ ]] && return 0
    is_exact_version "$value"
}

version_major() {
    local value="${1#v}"
    printf '%s\n' "${value%%.*}"
}

version_minor() {
    local value="${1#v}" rest
    if [[ "$value" == *.* ]]; then
        rest="${value#*.}"
        printf '%s\n' "${rest%%.*}"
    else
        printf '0\n'
    fi
}

version_supports_dns() {
    local value="$1" major minor
    major=$(version_major "$value")
    minor=$(version_minor "$value")
    ((major > 4 || (major == 4 && minor >= 1)))
}

version_supports_ipv6_flag() {
    local major
    major=$(version_major "$1")
    ((major >= 3 && major <= 5))
}

version_supports_egress() {
    local major
    major=$(version_major "$1")
    ((major >= 5))
}

version_supports_obfs() {
    local major
    major=$(version_major "$1")
    ((major >= 3 && major <= 6))
}

version_supports_v6_options() {
    local major
    major=$(version_major "$1")
    ((major >= 6))
}

get_latest_version() {
    local body version
    body=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "$RELEASE_NOTES_URL" 2>/dev/null || true)
    version=$(printf '%s' "$body" \
        | grep -Eo 'snell-server-v[0-9]+\.[0-9]+\.[0-9]+[[:alnum:]._-]*' \
        | sed 's/.*-v//' \
        | sort -V \
        | tail -n 1 || true)
    if [[ -z "$version" ]]; then
        body=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 \
            "https://api.github.com/repos/${GITHUB_REPOSITORY}/contents/Version" 2>/dev/null || true)
        version=$(printf '%s' "$body" \
            | grep -Eo '"name"[[:space:]]*:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+[[:alnum:]._-]*"' \
            | sed -E 's/.*"(v[^" ]+)"/\1/; s/^v//' \
            | sort -V \
            | tail -n 1 || true)
    fi
    [[ -n "$version" ]] && printf '%s\n' "$version"
}

get_arch() {
    local machine="${SNELL_ARCH_OVERRIDE:-$(uname -m)}"
    case "$machine" in
        x86_64|amd64) printf 'amd64\n' ;;
        i386|i686) printf 'i386\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;;
        armv7l|armv7|armv8l|armv8) printf 'armv7l\n' ;;
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac
}

get_package_manager() {
    if command_exists apt-get; then printf 'apt\n'
    elif command_exists dnf; then printf 'dnf\n'
    elif command_exists yum; then printf 'yum\n'
    elif command_exists pacman; then printf 'pacman\n'
    elif command_exists zypper; then printf 'zypper\n'
    elif command_exists apk; then printf 'apk\n'
    else printf 'unknown\n'
    fi
}

is_musl_system() {
    case "${SNELL_LIBC_OVERRIDE:-}" in
        musl) return 0 ;;
        glibc) return 1 ;;
    esac
    [[ -f /etc/alpine-release ]] || ldd --version 2>&1 | grep -qi musl
}

install_packages() {
    local pm="$1"
    shift
    case "$pm" in
        apt) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        pacman) pacman -Sy --noconfirm "$@" ;;
        zypper) zypper --non-interactive install "$@" ;;
        apk) apk add --no-cache "$@" ;;
        *) return 1 ;;
    esac
}

ensure_native_dependencies() {
    local missing=() pm
    command_exists curl || missing+=(curl)
    command_exists unzip || missing+=(unzip)
    command_exists ip || missing+=(ip)
    command_exists openssl || missing+=(openssl)
    command_exists pgrep || missing+=(pgrep)
    if ((${#missing[@]} == 0)); then
        return 0
    fi
    pm=$(get_package_manager)
    case "$pm" in
        apt) install_packages "$pm" ca-certificates curl unzip iproute2 openssl procps ;;
        dnf|yum) install_packages "$pm" ca-certificates curl unzip iproute openssl procps-ng ;;
        pacman) install_packages "$pm" ca-certificates curl unzip iproute2 openssl procps-ng ;;
        zypper) install_packages "$pm" ca-certificates curl unzip iproute2 openssl procps ;;
        apk) install_packages "$pm" ca-certificates curl unzip iproute2 openssl procps ;;
        *) error "缺少依赖 (${missing[*]})，且无法识别包管理器。"; return 1 ;;
    esac
    for command_name in curl unzip ip openssl pgrep; do
        command_exists "$command_name" || { error "依赖安装后仍缺少: $command_name"; return 1; }
    done
}

port_in_use() {
    local port="$1"
    if command_exists ss; then
        ss -H -ltnu 2>/dev/null | awk -v port=":${port}" '$5 ~ port "$" {found=1} END {exit !found}'
    elif command_exists netstat; then
        netstat -lnt 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" {found=1} END {exit !found}'
    elif command_exists lsof; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN -iUDP:"${port}" >/dev/null 2>&1
    else
        return 1
    fi
}

wait_for_native() {
    local port="$1" attempts=30
    while ((attempts > 0)); do
        if port_in_use "$port"; then
            return 0
        fi
        sleep 1
        attempts=$((attempts - 1))
    done
    return 1
}

random_port() {
    local port i
    for ((i = 0; i < 100; i++)); do
        port=$((RANDOM % 55536 + 10000))
        if ! port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    printf '20000\n'
}

generate_psk() {
    if [[ -r /dev/urandom ]]; then
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
    else
        printf '%s' "$(date +%s)-$$" | sha256sum | cut -c1-48
    fi
}

is_valid_psk() {
    local value="$1" byte_length allowed_pattern='^[A-Za-z0-9._+=/-]+$'
    [[ "$value" =~ $allowed_pattern ]] || return 1
    byte_length=$(LC_ALL=C printf '%s' "$value" | LC_ALL=C wc -c)
    ((byte_length >= 16 && byte_length <= 180))
}

is_valid_dns() {
    local pattern='^[A-Za-z0-9:., _-]+$'
    [[ -z "$1" || "$1" =~ $pattern ]]
}

is_valid_interface() {
    [[ -z "$1" || "$1" =~ ^[A-Za-z0-9_.-]+$ ]]
}

is_valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]
}

is_valid_loglevel() {
    case "$1" in
        trace|verbose|info|notify|warning|error) return 0 ;;
        *) return 1 ;;
    esac
}

config_value() {
    local key="$1" file="$2"
    awk -F= -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value=$0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            print value
            exit
        }
    ' "$file"
}

dotenv_value() {
    local key="$1" file="$2"
    [[ -f "$file" ]] || return 0
    awk -v key="$key" '
        index($0, key "=") == 1 {
            value=substr($0, length(key) + 2)
            if (value ~ /^".*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
            print value
            exit
        }
    ' "$file"
}

apply_agent_config() {
    local key="$1" value="$2"
    case "$key" in
        METHOD) CLI_METHOD="$value"; CLI_SET_METHOD=1 ;;
        VERSION) CLI_VERSION="$value"; CLI_SET_VERSION=1 ;;
        NETWORK) CLI_NETWORK="$value"; CLI_SET_NETWORK=1 ;;
        REGISTRY) CLI_REGISTRY="$value" ;;
        PORT|LISTEN) CLI_PORT="$value"; CLI_SET_PORT=1 ;;
        PSK) CLI_PSK="$value"; CLI_SET_PSK=1 ;;
        IPV6) CLI_IPV6="$value"; CLI_SET_IPV6=1 ;;
        DNS) CLI_DNS="$value"; CLI_SET_DNS=1 ;;
        DNS_IP_PREFERENCE) CLI_DNS_PREF="$value"; CLI_SET_DNS_PREF=1 ;;
        EGRESS_INTERFACE) CLI_EGRESS="$value"; CLI_SET_EGRESS=1 ;;
        OBFS) CLI_OBFS="$value"; CLI_SET_OBFS=1 ;;
        HOST) CLI_HOST="$value"; CLI_SET_HOST=1 ;;
        MODE) CLI_MODE="$value"; CLI_SET_MODE=1 ;;
        LOGLEVEL) CLI_LOGLEVEL="$value"; CLI_SET_LOGLEVEL=1 ;;
        ALPINE_FALLBACK) CLI_ALPINE_FALLBACK="$value" ;;
        *) error "不支持的 agent 配置项: $key"; return 1 ;;
    esac
}

load_agent_config() {
    local file="${1:-}" line key value
    if [[ -n "$file" ]]; then
        [[ -r "$file" ]] || { error "无法读取配置文件: $file"; return 1; }
        exec 9< "$file"
    elif ((CLI_CONFIG_STDIN)); then
        exec 9<&0
    else
        return 0
    fi
    while IFS= read -r line <&9 || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || { error "配置行格式无效: $line"; exec 9<&-; return 1; }
        key="${line%%=*}"
        value="${line#*=}"
        apply_agent_config "$key" "$value" || { exec 9<&-; return 1; }
    done
    exec 9<&-
}

validate_agent_config() {
    [[ "$CLI_METHOD" == native || "$CLI_METHOD" == docker ]] || { error "--method 必须是 native 或 docker。"; return 1; }
    [[ -n "$CLI_VERSION" ]] || { error "缺少 VERSION/--version。"; return 1; }
    if [[ "$CLI_METHOD" == native ]]; then
        is_exact_version "$CLI_VERSION" || { error "native 的 VERSION 必须是完整版本号。"; return 1; }
        [[ "$CLI_NETWORK" == host ]] || { error "native 不支持 NETWORK=bridge。"; return 1; }
    else
        is_docker_tag "$CLI_VERSION" || { error "Docker VERSION 必须是 latest、主版本标签或完整版本号。"; return 1; }
    fi
    [[ "$CLI_PORT" =~ ^[0-9]+$ ]] && ((10#$CLI_PORT >= 10000 && 10#$CLI_PORT <= 65535)) || { error "PORT 必须在 10000-65535。"; return 1; }
    is_valid_psk "$CLI_PSK" || { error "PSK 必须为 16-180 字节且只含安全字符。"; return 1; }
    [[ -z "$CLI_LOGLEVEL" ]] || is_valid_loglevel "$CLI_LOGLEVEL" || { error "LOGLEVEL 必须是 trace、verbose、info、notify、warning 或 error。"; return 1; }
    [[ "$CLI_NETWORK" == host || "$CLI_NETWORK" == bridge ]] || { error "NETWORK 必须是 host 或 bridge。"; return 1; }
    [[ "$CLI_REGISTRY" == auto || "$CLI_REGISTRY" == ghcr || "$CLI_REGISTRY" == dockerhub ]] || { error "REGISTRY 无效。"; return 1; }
    [[ -z "$CLI_DNS" ]] || is_valid_dns "$CLI_DNS" || { error "DNS 格式无效。"; return 1; }
    [[ -z "$CLI_EGRESS" ]] || is_valid_interface "$CLI_EGRESS" || { error "EGRESS_INTERFACE 格式无效。"; return 1; }
    [[ -z "$CLI_HOST" ]] || is_valid_host "$CLI_HOST" || { error "HOST 格式无效。"; return 1; }
    [[ "$CLI_ALPINE_FALLBACK" == abort || "$CLI_ALPINE_FALLBACK" == docker ]] || { error "ALPINE_FALLBACK 必须是 abort 或 docker。"; return 1; }
    local major
    major=$(version_major "$CLI_VERSION")
    if ((CLI_SET_DNS)) && ! version_supports_dns "$CLI_VERSION"; then
        error "DNS 仅支持 v4.1+。"
        return 1
    fi
    if ((CLI_SET_IPV6)); then
        [[ "$CLI_IPV6" == false || "$CLI_IPV6" == true ]] || { error "IPV6 必须是 true 或 false。"; return 1; }
        ((major <= 5)) || { error "IPV6 仅支持 v3-v5。v6+ 使用 DNS_IP_PREFERENCE。"; return 1; }
    fi
    if ((CLI_SET_DNS_PREF)); then
        [[ "$major" -ge 6 ]] || { error "DNS_IP_PREFERENCE 仅支持 v6+。"; return 1; }
        [[ "$CLI_DNS_PREF" == default || "$CLI_DNS_PREF" == prefer-ipv4 || "$CLI_DNS_PREF" == prefer-ipv6 || "$CLI_DNS_PREF" == ipv4-only || "$CLI_DNS_PREF" == ipv6-only ]] || { error "DNS_IP_PREFERENCE 取值无效。"; return 1; }
    fi
    if ((CLI_SET_MODE)); then
        [[ "$major" -ge 6 ]] || { error "MODE 仅支持 v6+。"; return 1; }
        [[ "$CLI_MODE" == default || "$CLI_MODE" == unshaped || "$CLI_MODE" == unsafe-raw ]] || { error "MODE 取值无效。"; return 1; }
    fi
    if ((CLI_SET_EGRESS)) && ((major < 5)); then
        error "EGRESS_INTERFACE 仅支持 v5+。"
        return 1
    fi
    if ((CLI_SET_OBFS)); then
        ((major >= 3 && major <= 6)) || { error "OBFS/HOST 仅支持 v3-v6。"; return 1; }
        if ((major == 3)); then
            [[ "$CLI_OBFS" == none || "$CLI_OBFS" == http || "$CLI_OBFS" == tls ]] || { error "v3 OBFS 取值必须是 none、http 或 tls。"; return 1; }
        else
            [[ "$CLI_OBFS" == none || "$CLI_OBFS" == http ]] || { error "v4-v6 OBFS 取值必须是 none 或 http。"; return 1; }
        fi
        if [[ "$CLI_OBFS" != none && -z "$CLI_HOST" ]]; then
            error "启用 OBFS 时必须同时设置 HOST。"
            return 1
        fi
        if [[ "$CLI_OBFS" == none && "$CLI_SET_HOST" == 1 ]]; then
            error "OBFS=none 时不能设置 HOST。"
            return 1
        fi
    fi
    if ((CLI_SET_HOST)) && ((CLI_SET_OBFS == 0)); then
        error "HOST 只有在 OBFS 启用时才可设置。"
        return 1
    fi
}

agent_help() {
    cat <<'EOF'
Snell.sh agent interface v1

直接运行进入用户 TUI：
  bash Snell.sh

AI agent 无配置文件安装：
  bash Snell.sh --agent-install --method docker --version v5.0.1 --port 20000 --psk 'your-16-byte-psk'

AI agent 使用标准输入配置：
  printf 'PORT=20000\nPSK=your-16-byte-psk\n' | bash Snell.sh --agent-install --method docker --version v5.0.1 --config-stdin

AI agent 使用配置文件：
  bash Snell.sh --agent-install --method docker --version v5.0.1 --config-file ./snell.agent.conf

只检查不执行：
  ... --agent-install ... --dry-run

管理命令：
  bash Snell.sh --agent-config
  bash Snell.sh --agent-status
  bash Snell.sh --agent-start | --agent-stop | --agent-restart
  bash Snell.sh --agent-reconfigure --yes
  bash Snell.sh --agent-update --yes
  bash Snell.sh --agent-uninstall --yes

配置键：METHOD VERSION NETWORK REGISTRY PORT PSK IPV6 DNS DNS_IP_PREFERENCE
      EGRESS_INTERFACE OBFS HOST MODE LOGLEVEL ALPINE_FALLBACK

日志等级（可选；省略时使用 Snell 默认等级）：trace verbose info notify warning error
日志等级不是 Snell 的 snell.conf 配置项，不要写入 "log = ..."。
原生安装通过服务命令参数 -l 设置；Docker 使用 .env 中的 LOGLEVEL。
EOF
}

backup_file() {
    local file="$1" backup
    [[ -e "$file" ]] || return 0
    backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp -a "$file" "$backup"
    info "已备份: $backup"
}

render_snell_config() {
    local version="${1#v}" port="$2" psk="$3" ipv6="${4:-false}" dns="${5:-}"
    local dns_pref="${6:-}" egress="${7:-}" obfs="${8:-}" host="${9:-}" mode="${10:-}"
    local major
    major=$(version_major "$version")
    printf '[snell-server]\n'
    if ((major >= 6)); then
        printf 'listen = 0.0.0.0:%s, [::]:%s\n' "$port" "$port"
    else
        printf 'listen = :::%s\n' "$port"
    fi
    printf 'psk = %s\n' "$psk"
    if version_supports_ipv6_flag "$version"; then
        printf 'ipv6 = %s\n' "$ipv6"
    fi
    if [[ -n "$dns" ]] && version_supports_dns "$version"; then
        printf 'dns = %s\n' "$dns"
    fi
    if [[ -n "$dns_pref" ]] && version_supports_v6_options "$version"; then
        printf 'dns-ip-preference = %s\n' "$dns_pref"
    fi
    if [[ -n "$egress" ]] && version_supports_egress "$version"; then
        printf 'egress-interface = %s\n' "$egress"
    fi
    if [[ -n "$obfs" && -n "$host" ]] && version_supports_obfs "$version"; then
        printf 'obfs = %s\nhost = %s\n' "$obfs" "$host"
    fi
    if [[ -n "$mode" ]] && version_supports_v6_options "$version"; then
        printf 'mode = %s\n' "$mode"
    fi
}

render_native_command() {
    local loglevel="${cfg_loglevel:-}"
    printf '%s' "$SNELL_BIN"
    [[ -n "$loglevel" ]] && printf ' -l %s' "$loglevel"
    printf ' -c %s\n' "$SNELL_CONFIG_FILE"
}

render_compose() {
    local image="$1" network="$2" port="$3" dns="${4:-}" dns_pref="${5:-}"
    local ipv6="${6:-}" egress="${7:-}" obfs="${8:-}" host="${9:-}" mode="${10:-}" loglevel="${11:-}"
    printf 'services:\n'
    printf '  snell:\n'
    printf '    image: %s\n' "$image"
    printf '    container_name: snell\n'
    printf '    restart: unless-stopped\n'
    if [[ "$network" == "host" ]]; then
        printf '    network_mode: host\n'
    else
        printf '    ports:\n'
        printf '      - "${LISTEN}:${LISTEN}"\n'
    fi
    printf '    environment:\n'
    printf '      LISTEN: "${LISTEN}"\n'
    printf '      PSK: "${PSK}"\n'
    [[ -n "$dns" ]] && printf '      DNS: "${DNS}"\n'
    [[ -n "$dns_pref" ]] && printf '      DNS_IP_PREFERENCE: "${DNS_IP_PREFERENCE}"\n'
    [[ -n "$ipv6" ]] && printf '      IPV6: "${IPV6}"\n'
    [[ -n "$egress" ]] && printf '      EGRESS_INTERFACE: "${EGRESS_INTERFACE}"\n'
    [[ -n "$obfs" ]] && printf '      OBFS: "${OBFS}"\n'
    [[ -n "$host" ]] && printf '      HOST: "${HOST}"\n'
    [[ -n "$mode" ]] && printf '      MODE: "${MODE}"\n'
    [[ -n "$loglevel" ]] && printf '      LOGLEVEL: "${LOGLEVEL}"\n'
    return 0
}

render_env_file() {
    local port="$1" psk="$2" dns="${3:-}" dns_pref="${4:-}" ipv6="${5:-}"
    local egress="${6:-}" obfs="${7:-}" host="${8:-}" mode="${9:-}" loglevel="${10:-}"
    printf 'LISTEN=%s\nPSK=%s\n' "$port" "$psk"
    [[ -n "$dns" ]] && printf 'DNS=%s\n' "$dns"
    [[ -n "$dns_pref" ]] && printf 'DNS_IP_PREFERENCE=%s\n' "$dns_pref"
    [[ -n "$ipv6" ]] && printf 'IPV6=%s\n' "$ipv6"
    [[ -n "$egress" ]] && printf 'EGRESS_INTERFACE=%s\n' "$egress"
    [[ -n "$obfs" ]] && printf 'OBFS=%s\n' "$obfs"
    [[ -n "$host" ]] && printf 'HOST=%s\n' "$host"
    [[ -n "$mode" ]] && printf 'MODE=%s\n' "$mode"
    [[ -n "$loglevel" ]] && printf 'LOGLEVEL=%s\n' "$loglevel"
    return 0
}

docker_option_values() {
    docker_dns=""
    docker_dns_pref=""
    docker_ipv6=""
    docker_egress=""
    docker_obfs=""
    docker_host=""
    docker_mode=""
    docker_loglevel="${cfg_loglevel:-}"

    if [[ -z "${cfg_effective_version:-}" || "$cfg_effective_version" == "latest" ]]; then
        return 0
    fi
    if version_supports_dns "$cfg_effective_version"; then docker_dns="${cfg_dns:-}"; fi
    if version_supports_v6_options "$cfg_effective_version"; then
        docker_dns_pref="${cfg_dns_pref:-}"
        docker_mode="${cfg_mode:-}"
    fi
    if version_supports_ipv6_flag "$cfg_effective_version"; then docker_ipv6="${cfg_ipv6:-false}"; fi
    if version_supports_egress "$cfg_effective_version"; then docker_egress="${cfg_egress:-}"; fi
    if version_supports_obfs "$cfg_effective_version"; then
        docker_obfs="${cfg_obfs:-}"
        docker_host="${cfg_host:-}"
    fi
}

collect_config() {
    local method="$1" version_hint="$2" network="$3"
    local default_port="${4:-}" default_psk="${5:-}" default_ipv6="${6:-false}"
    local default_dns="${7:-}" default_pref="${8:-prefer-ipv4}" default_egress="${9:-}"
    local default_obfs="${10:-}" default_host="${11:-}" default_mode="${12:-default}"
    local default_loglevel="${13:-}"
    local value numeric effective="" major=0 obfs_choice

    cfg_effective_version="$version_hint"
    if [[ "$version_hint" == "latest" ]]; then
        effective=$(get_latest_version || true)
        cfg_effective_version="$effective"
    fi
    if [[ -n "$cfg_effective_version" && "$cfg_effective_version" != "latest" ]]; then
        major=$(version_major "$cfg_effective_version")
    fi

    if ((NONINTERACTIVE)); then
        cfg_port="$CLI_PORT"
        cfg_psk="$CLI_PSK"
        cfg_ipv6="$CLI_IPV6"
        cfg_dns="$CLI_DNS"
        cfg_dns_pref="$CLI_DNS_PREF"
        cfg_egress="$CLI_EGRESS"
        cfg_obfs="$CLI_OBFS"
        cfg_host="$CLI_HOST"
        cfg_mode="$CLI_MODE"
        cfg_loglevel="$CLI_LOGLEVEL"
        validate_agent_config
        return 0
    fi

    cfg_port="${default_port:-$(random_port)}"
    while true; do
        value=$(tui_input "监听端口（10000-65535）" "$cfg_port") || return 1
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            numeric=$((10#$value))
            if ((numeric >= 10000 && numeric <= 65535)); then
                if port_in_use "$numeric"; then
                    warn "端口 $numeric 已被占用。"
                else
                    cfg_port="$numeric"
                    break
                fi
            else
                error "端口必须在 10000-65535 范围内。"
            fi
        else
            error "端口必须是数字。"
        fi
    done

    cfg_psk="${default_psk:-$(generate_psk)}"
    while true; do
        value=$(tui_input "PSK 密钥（仅允许字母、数字和 . _ + = / -）" "$cfg_psk") || return 1
        if is_valid_psk "$value"; then
            cfg_psk="$value"
            break
        fi
        error "PSK 为空、过长或包含 Docker Compose/配置文件不安全字符。"
    done

    cfg_ipv6=""
    cfg_dns=""
    cfg_dns_pref=""
    cfg_egress=""
    cfg_obfs=""
    cfg_host=""
    cfg_mode=""

    if ((major >= 3 && major <= 5)); then
        cfg_ipv6="false"
        if tui_yesno "是否启用 IPv6 监听？" "$([[ "$default_ipv6" == "true" ]] && printf y || printf n)"; then
            cfg_ipv6="true"
        fi
    elif ((major >= 6)); then
        cfg_dns_pref=$(tui_menu "IPv4/IPv6 偏好" "选择 Snell v6+ 的 DNS/IP 偏好。" "${default_pref:-prefer-ipv4}" \
            default "默认" prefer-ipv4 "优先 IPv4" prefer-ipv6 "优先 IPv6" ipv4-only "仅 IPv4" ipv6-only "仅 IPv6") || return 1
        cfg_mode=$(tui_menu "v6+ 工作模式" "选择 Snell v6+ 工作模式。" "${default_mode:-default}" \
            default "default" unshaped "unshaped" unsafe-raw "unsafe-raw") || return 1
    fi

    cfg_loglevel=$(tui_menu "日志等级" "通过 snell-server -l 设置；选择默认则不传递日志参数。" "${default_loglevel:-default}" \
        default "Snell 默认" trace "trace" verbose "verbose" info "info" notify "notify" warning "warning" error "error") || return 1
    [[ "$cfg_loglevel" == default ]] && cfg_loglevel=""

    if [[ -n "$cfg_effective_version" && "$cfg_effective_version" != "latest" ]] && version_supports_dns "$cfg_effective_version"; then
        while true; do
            value=$(tui_input "DNS 服务器（可选，多个地址用逗号分隔）" "$default_dns") || return 1
            if is_valid_dns "$value"; then
                cfg_dns="$value"
                break
            fi
            error "DNS 只允许地址、逗号、空格和常见域名字符。"
        done
    elif [[ "$version_hint" == "latest" ]]; then
        warn "无法确认 latest 镜像版本，跳过版本专属配置；镜像仍会自动生成 LISTEN/PSK。"
    fi

    if [[ -n "$cfg_effective_version" && "$cfg_effective_version" != "latest" ]] && version_supports_egress "$cfg_effective_version"; then
        while true; do
            value=$(tui_input "出口网卡（可选，例如 eth0）" "$default_egress") || return 1
            if is_valid_interface "$value"; then
                cfg_egress="$value"
                [[ -n "$value" && ! -e "/sys/class/net/$value" ]] && warn "当前主机未发现网卡 $value，配置仍会写入。"
                break
            fi
            error "网卡名称包含不支持的字符。"
        done
    fi

    if [[ -n "$cfg_effective_version" && "$cfg_effective_version" != "latest" ]] && version_supports_obfs "$cfg_effective_version"; then
        if ((major <= 3)); then
            obfs_choice=$(tui_menu "混淆模式" "选择混淆模式。" "${default_obfs:-none}" \
                none "不启用" http "http" tls "tls") || return 1
        else
            obfs_choice=$(tui_menu "混淆模式" "选择混淆模式。" "${default_obfs:-none}" \
                none "不启用" http "http") || return 1
        fi
        if [[ "$obfs_choice" != "none" ]]; then
            cfg_obfs="$obfs_choice"
            while true; do
                value=$(tui_input "混淆域名（例如 www.example.com）" "$default_host") || return 1
                if is_valid_host "$value" && [[ -n "$value" ]]; then
                    cfg_host="$value"
                    break
                fi
                error "混淆域名不能为空，且只能包含字母、数字、点和连字符。"
            done
        fi
    fi


    if [[ "$method" == "docker" && "$network" == "bridge" && -n "$cfg_egress" ]]; then
        warn "bridge 模式下出口网卡由容器网络决定，请确认镜像能访问该接口。"
    fi
    return 0
}

show_summary() {
    local method="$1" version="$2" network="${3:-}" image="${4:-}"
    printf '\n安装配置摘要:\n' >&2
    printf '  安装方式: %s\n' "$method" >&2
    printf '  镜像/版本: %s\n' "${image:-$version}" >&2
    [[ -n "$network" ]] && printf '  网络模式: %s\n' "$network" >&2
    printf '  监听端口: %s\n' "$cfg_port" >&2
    printf '  PSK: %s\n' "$cfg_psk" >&2
    [[ -n "$cfg_ipv6" ]] && printf '  IPv6: %s\n' "$cfg_ipv6" >&2
    [[ -n "$cfg_dns" ]] && printf '  DNS: %s\n' "$cfg_dns" >&2
    [[ -n "$cfg_dns_pref" ]] && printf '  DNS/IP 偏好: %s\n' "$cfg_dns_pref" >&2
    [[ -n "$cfg_egress" ]] && printf '  出口网卡: %s\n' "$cfg_egress" >&2
    [[ -n "$cfg_obfs" ]] && printf '  混淆: %s -> %s\n' "$cfg_obfs" "$cfg_host" >&2
    [[ -n "$cfg_mode" ]] && printf '  v6+ 模式: %s\n' "$cfg_mode" >&2
    [[ -n "${cfg_loglevel:-}" ]] && printf '  日志等级: %s\n' "$cfg_loglevel" >&2
    return 0
}

systemd_usable() {
    command_exists systemctl && [[ -d /run/systemd/system ]]
}

openrc_usable() {
    command_exists rc-service && [[ -d /etc/init.d ]]
}

create_system_user() {
    local nologin
    if ! getent group "$SNELL_GROUP" >/dev/null 2>&1; then
        if command_exists groupadd; then
            groupadd --system "$SNELL_GROUP"
        elif command_exists addgroup; then
            addgroup -S "$SNELL_GROUP"
        else
            error "找不到 groupadd/addgroup，无法创建 Snell 用户组。"
            return 1
        fi
    fi
    if ! id -u "$SNELL_USER" >/dev/null 2>&1; then
        nologin=$(command -v nologin || printf '/usr/sbin/nologin')
        if command_exists useradd; then
            useradd --system --gid "$SNELL_GROUP" --home-dir /nonexistent --no-create-home --shell "$nologin" "$SNELL_USER"
        elif command_exists adduser; then
            adduser -S -D -H -G "$SNELL_GROUP" -s "$nologin" "$SNELL_USER"
        else
            error "找不到 useradd/adduser，无法创建 Snell 用户。"
            return 1
        fi
    fi
}

write_native_config() {
    local version="$1" tmp
    mkdir -p "$SNELL_CONFIG_DIR"
    tmp=$(mktemp "${SNELL_CONFIG_DIR}/snell.conf.tmp.XXXXXX")
    render_snell_config "$version" "$cfg_port" "$cfg_psk" "$cfg_ipv6" "$cfg_dns" "$cfg_dns_pref" \
        "$cfg_egress" "$cfg_obfs" "$cfg_host" "$cfg_mode" > "$tmp"
    chown "$SNELL_USER:$SNELL_GROUP" "$tmp"
    chmod 640 "$tmp"
    mv -f "$tmp" "$SNELL_CONFIG_FILE"
}

write_native_loglevel() {
    local tmp
    if [[ -z "${cfg_loglevel:-}" ]]; then
        rm -f "$SNELL_LOGLEVEL_FILE"
        return 0
    fi
    tmp=$(mktemp "${SNELL_CONFIG_DIR}/loglevel.tmp.XXXXXX")
    printf '%s\n' "$cfg_loglevel" > "$tmp"
    chown "$SNELL_USER:$SNELL_GROUP" "$tmp"
    chmod 640 "$tmp"
    mv -f "$tmp" "$SNELL_LOGLEVEL_FILE"
}

write_service_files() {
    local runtime_args="-c $SNELL_CONFIG_FILE"
    [[ -n "${cfg_loglevel:-}" ]] && runtime_args="-l $cfg_loglevel $runtime_args"
    SERVICE_KIND="manual"
    if systemd_usable; then
        cat > "$SNELL_SERVICE_FILE" <<EOF
[Unit]
Description=Snell Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SNELL_USER}
Group=${SNELL_GROUP}
WorkingDirectory=${SNELL_CONFIG_DIR}
ExecStart=${SNELL_BIN} ${runtime_args}
Restart=on-failure
RestartSec=3
LimitNOFILE=32768
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        SERVICE_KIND="systemd"
        return 0
    fi
    if openrc_usable; then
        local openrc_run
        openrc_run=$(command -v openrc-run || printf '/sbin/openrc-run')
        touch /var/log/snell.log
        chown "$SNELL_USER:$SNELL_GROUP" /var/log/snell.log
        chmod 640 /var/log/snell.log
        {
            printf '#!%s\n' "$openrc_run"
            printf 'name="snell"\ncommand="%s"\ncommand_args="%s"\n' "$SNELL_BIN" "$runtime_args"
            printf 'command_user="%s:%s"\ncommand_background=true\npidfile="/run/$RC_SVCNAME.pid"\n' "$SNELL_USER" "$SNELL_GROUP"
            printf 'output_log="/var/log/snell.log"\nerror_log="/var/log/snell.log"\n'
            printf 'depend() {\n    need net\n    after firewall\n}\n'
        } > "$SNELL_INIT_FILE"
        chmod 755 "$SNELL_INIT_FILE"
        SERVICE_KIND="openrc"
        return 0
    fi
    warn "未检测到正在运行的 systemd 或 OpenRC，将只安装文件，不自动启动服务。"
}

native_service_action() {
    local action="$1"
    if [[ "$SERVICE_KIND" == "systemd" ]]; then
        systemctl "$action" snell
    elif [[ "$SERVICE_KIND" == "openrc" ]]; then
        rc-service snell "$action"
    elif [[ -f "$SNELL_SERVICE_FILE" ]] && systemd_usable; then
        systemctl "$action" snell
    elif [[ -x "$SNELL_INIT_FILE" ]] && openrc_usable; then
        rc-service snell "$action"
    else
        warn "当前系统没有可用的服务管理器。"
        return 1
    fi
}

native_start() {
    local listen_port="${cfg_port:-}"
    if [[ "$SERVICE_KIND" == "systemd" ]] || { [[ "$SERVICE_KIND" == "manual" ]] && [[ -f "$SNELL_SERVICE_FILE" ]] && systemd_usable; }; then
        SERVICE_KIND="systemd"
        systemctl enable --now snell
    elif [[ "$SERVICE_KIND" == "openrc" ]] || { [[ "$SERVICE_KIND" == "manual" ]] && [[ -x "$SNELL_INIT_FILE" ]] && openrc_usable; }; then
        SERVICE_KIND="openrc"
        command_exists rc-update && rc-update add snell default >/dev/null 2>&1 || true
        rc-service snell start
    else
        warn "原生 Snell 已安装，请手动运行: ${SNELL_BIN} -c ${SNELL_CONFIG_FILE}"
    fi
    if [[ -z "$listen_port" && -f "$SNELL_CONFIG_FILE" ]]; then
        listen_port=$(config_value listen "$SNELL_CONFIG_FILE" | grep -Eo '[0-9]+$' | tail -n 1 || true)
    fi
    if [[ "$SERVICE_KIND" != "manual" && -n "$listen_port" ]] && ! wait_for_native "$listen_port"; then
        error "Snell 服务启动命令返回，但端口 ${listen_port} 未开始监听。"
        return 1
    fi
}

native_stop() {
    if [[ -f "$SNELL_SERVICE_FILE" ]] && systemd_usable; then
        systemctl disable --now snell >/dev/null 2>&1 || true
    elif [[ -x "$SNELL_INIT_FILE" ]] && openrc_usable; then
        rc-service snell stop >/dev/null 2>&1 || true
    fi
}

get_native_version() {
    [[ -x "$SNELL_BIN" ]] || return 1
    "$SNELL_BIN" -v 2>&1 \
        | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+[[:alnum:]._-]*' \
        | head -n 1 \
        | sed 's/^v//' \
        || true
}

download_native_binary() {
    local version="$1" arch file official backup temp extract stage
    version="${version#v}"
    arch=$(get_arch)
    file="snell-server-v${version}-linux-${arch}.zip"
    official="${OFFICIAL_BASE}/${file}"
    backup="${BACKUP_BASE}/v${version}/${file}"
    temp=$(mktemp -d)
    extract="${temp}/extract"
    stage=$(mktemp "${SNELL_BIN}.new.XXXXXX")
    rm -f "$stage"
    mkdir -p "$extract"

    info "下载 Snell v${version} (${arch})..."
    if ! curl -fL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 -o "${temp}/snell.zip" "$official"; then
        info "官方源失败，尝试 GitHub 备份源..."
        if ! curl -fL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 -o "${temp}/snell.zip" "$backup"; then
            rm -rf "$temp"
            error "Snell v${version} 下载失败。"
            return 1
        fi
    fi
    unzip -t "${temp}/snell.zip" >/dev/null
    unzip -q "${temp}/snell.zip" -d "$extract"
    [[ -f "${extract}/snell-server" ]] || {
        rm -rf "$temp"
        error "压缩包中未找到 snell-server。"
        return 1
    }
    install -m 0755 "${extract}/snell-server" "$stage"
    rm -rf "$temp"
    printf '%s\n' "$stage"
}

native_install() {
    local version="$1" stage old_binary network registry
    title "安装 Snell 原生版本"
    if is_musl_system; then
        warn "当前系统是 Alpine/musl，官方 Snell 二进制无法直接进行源码安装。"
        if tui_yesno "是否改用 Docker 安装 Snell v${version}？" "y"; then
            network=$(choose_network) || return 1
            registry=$(choose_registry) || return 1
            docker_install "$version" "$network" "$registry" || return 1
        else
            info "已取消安装，未写入原生配置或服务文件。"
        fi
        return 0
    fi
    ensure_native_dependencies
    create_system_user
    stage=$(download_native_binary "$version") || return 1
    native_stop
    backup_file "$SNELL_BIN"
    mv -f "$stage" "$SNELL_BIN"
    backup_file "$SNELL_CONFIG_FILE"
    write_native_config "$version"
    write_native_loglevel
    write_service_files
    if ! native_start; then
        error "Snell 文件已安装，但服务启动失败。"
        return 1
    fi
    mkdir -p "$STATE_DIR"
    printf 'native\n' > "$STATE_FILE"
    success "Snell 原生安装完成。"
    show_install_result "native" "$version"
}

ensure_docker() {
    if ! command_exists docker; then
        if ! tui_yesno "未检测到 Docker，是否使用 Docker 官方安装脚本安装？" "y"; then
            error "Docker 未安装。"
            return 1
        fi
        install_docker_official require-compose || return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        if systemd_usable; then
            systemctl enable --now docker >/dev/null 2>&1 || true
        elif openrc_usable && command_exists rc-service; then
            rc-service docker start >/dev/null 2>&1 || true
        fi
    fi
    docker info >/dev/null 2>&1 || { error "Docker daemon 未运行或当前用户无权访问 Docker。"; return 1; }

    ensure_compose
}

compose_available() {
    docker compose version >/dev/null 2>&1 || {
        command_exists docker-compose && docker-compose version >/dev/null 2>&1
    }
}

run_docker_install_script() {
    local mirror="${1:-}" command timeout_seconds=600
    if [[ "$mirror" == "aliyun" ]]; then
        command='curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 https://get.docker.com | bash -s docker --mirror Aliyun'
    else
        command='curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 https://get.docker.com | bash -s docker'
    fi
    if command_exists timeout; then
        timeout "$timeout_seconds" bash -o pipefail -c "$command"
    else
        warn "当前系统没有 timeout，将直接运行 Docker 官方安装脚本。"
        bash -o pipefail -c "$command"
    fi
}

install_docker_official() {
    local requirement="${1:-docker}" target="Docker"
    [[ "$requirement" == "require-compose" ]] && target="Docker 和 Compose"
    info "使用 Docker 官方安装脚本安装 ${target}..."
    if run_docker_install_script official && command_exists docker \
        && { [[ "$requirement" != "require-compose" ]] || compose_available; }; then
        success "Docker 官方源安装成功。"
        return 0
    fi
    warn "Docker 官方源安装失败或超时，改用 Aliyun 镜像源重试。"
    if run_docker_install_script aliyun && command_exists docker \
        && { [[ "$requirement" != "require-compose" ]] || compose_available; }; then
        success "Docker Aliyun 镜像源安装成功。"
        return 0
    fi
    error "Docker/Compose 安装失败。"
    return 1
}

ensure_compose() {
    COMPOSE_CMD=()
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker compose)
    elif command_exists docker-compose && docker-compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker-compose)
    else
        warn "未找到 Docker Compose，使用 Docker 官方安装脚本补装。"
        install_docker_official require-compose || return 1
        if docker compose version >/dev/null 2>&1; then
            COMPOSE_CMD=(docker compose)
        elif command_exists docker-compose && docker-compose version >/dev/null 2>&1; then
            COMPOSE_CMD=(docker-compose)
        else
            error "无法安装 Docker Compose v2 插件或 docker-compose v1。"
            return 1
        fi
    fi
}

compose() {
    (cd "$DOCKER_DIR" && "${COMPOSE_CMD[@]}" "$@")
}

docker_container_exists() {
    command_exists docker && docker inspect snell >/dev/null 2>&1
}

pull_docker_image() {
    local tag="$1" registry="${2:-auto}" base
    selected_image=""
    case "$registry" in
        ghcr) base="$IMAGE_GHCR"; docker pull "${base}:${tag}" && selected_image="${base}:${tag}" ;;
        dockerhub) base="$IMAGE_DOCKERHUB"; docker pull "${base}:${tag}" && selected_image="${base}:${tag}" ;;
        auto)
            if docker pull "${IMAGE_GHCR}:${tag}"; then
                selected_image="${IMAGE_GHCR}:${tag}"
            elif docker pull "${IMAGE_DOCKERHUB}:${tag}"; then
                selected_image="${IMAGE_DOCKERHUB}:${tag}"
            fi
            ;;
        *) error "未知镜像仓库选择: $registry"; return 1 ;;
    esac
    [[ -n "$selected_image" ]] || { error "镜像拉取失败: ${tag}"; return 1; }
    info "使用镜像: $selected_image"
}

write_docker_files() {
    local image="$1" network="$2" temp_env temp_compose
    mkdir -p "$DOCKER_DIR"
    backup_file "$DOCKER_ENV_FILE"
    backup_file "$DOCKER_COMPOSE_FILE"
    docker_option_values
    umask 077
    temp_env=$(mktemp "${DOCKER_DIR}/.env.tmp.XXXXXX")
    render_env_file "$cfg_port" "$cfg_psk" "$docker_dns" "$docker_dns_pref" "$docker_ipv6" \
        "$docker_egress" "$docker_obfs" "$docker_host" "$docker_mode" "$docker_loglevel" > "$temp_env"
    chmod 600 "$temp_env"
    mv -f "$temp_env" "$DOCKER_ENV_FILE"
    umask 022
    temp_compose=$(mktemp "${DOCKER_DIR}/docker-compose.yml.tmp.XXXXXX")
    render_compose "$image" "$network" "$cfg_port" "$docker_dns" "$docker_dns_pref" "$docker_ipv6" \
        "$docker_egress" "$docker_obfs" "$docker_host" "$docker_mode" "$docker_loglevel" > "$temp_compose"
    chmod 644 "$temp_compose"
    mv -f "$temp_compose" "$DOCKER_COMPOSE_FILE"
}

wait_for_docker_container() {
    local i status restarts previous_restarts="" stable=0
    for ((i = 0; i < 15; i++)); do
        status=$(docker inspect --format '{{.State.Status}}' snell 2>/dev/null || true)
        restarts=$(docker inspect --format '{{.RestartCount}}' snell 2>/dev/null || true)
        if [[ "$status" == "running" ]]; then
            if [[ -n "$previous_restarts" && "$restarts" == "$previous_restarts" ]]; then
                stable=$((stable + 1))
            else
                stable=1
            fi
            previous_restarts="$restarts"
            if ((stable >= 3)); then
                return 0
            fi
        else
            stable=0
            previous_restarts="$restarts"
        fi
        sleep 1
    done
    docker logs --tail 50 snell 2>/dev/null || true
    return 1
}

docker_apply() {
    local image="$1" network="$2" recreate="${3:-false}"
    ensure_docker
    if docker_container_exists && ! has_docker_install; then
        error "检测到现有 snell 容器；本脚本不迁移旧容器，请先手动清理后重试。"
        return 1
    fi
    write_docker_files "$image" "$network"
    compose config >/dev/null
    if [[ "$recreate" == "true" ]]; then
        compose down --remove-orphans
    fi
    compose up -d --remove-orphans
    wait_for_docker_container || { error "Docker 容器启动失败。"; return 1; }
    mkdir -p "$STATE_DIR"
    printf 'docker\n' > "$STATE_FILE"
    success "Snell Docker 安装/更新完成。"
    show_install_result "docker" "${cfg_effective_version:-latest}" "$image"
}

docker_install() {
    local tag="$1" network="$2" registry="$3" recreate=false
    title "安装 Snell Docker 版本"
    ensure_docker
    has_docker_install && recreate=true
    pull_docker_image "$tag" "$registry"
    docker_apply "$selected_image" "$network" "$recreate"
}

has_native_install() {
    [[ -x "$SNELL_BIN" && -f "$SNELL_CONFIG_FILE" ]]
}

docker_files_exist() {
    [[ -f "$DOCKER_COMPOSE_FILE" && -f "$DOCKER_ENV_FILE" ]]
}

has_docker_install() {
    [[ -f "$STATE_FILE" ]] || return 1
    [[ "$(tr -d '[:space:]' < "$STATE_FILE")" == "docker" ]] || return 1
    docker_files_exist
}

get_mode() {
    local saved native=false docker=false choice
    if [[ -f "$STATE_FILE" ]]; then
        saved=$(tr -d '[:space:]' < "$STATE_FILE")
        if [[ "$saved" == "native" ]] && has_native_install; then printf 'native\n'; return 0; fi
        if [[ "$saved" == "docker" ]] && has_docker_install; then printf 'docker\n'; return 0; fi
    fi
    has_native_install && native=true
    has_docker_install && docker=true
    if [[ "$native" == true && "$docker" == false ]]; then printf 'native\n'; return 0; fi
    if [[ "$docker" == true && "$native" == false ]]; then printf 'docker\n'; return 0; fi
    if [[ "$native" == false && "$docker" == false ]]; then
        error "未检测到 Snell 安装。"
        return 1
    fi
    choice=$(tui_menu "选择 Snell 实例" "检测到原生和 Docker 两种安装，请选择操作对象。" native native docker docker) || return 1
    printf '%s\n' "$choice"
}

choose_native_version() {
    local latest choice value
    latest=$(get_latest_version || true)
    choice=$(tui_menu "原生安装版本" "选择要安装的 Snell 版本。" 1 \
        1 "最新稳定版 ${latest:+(v${latest})}" 2 "手动输入完整版本号") || return 1
    if [[ "$choice" == 1 ]]; then
        [[ -n "$latest" ]] || { error "无法获取最新版本，请改用手动输入。"; return 1; }
        printf '%s\n' "$latest"
        return 0
    fi
    while true; do
        value=$(tui_input "输入版本号，例如 5.0.1 或 v5.0.1" "") || return 1
        if is_exact_version "$value"; then
            value=$(normalize_version "$value")
            printf '%s\n' "${value#v}"
            return 0
        fi
        error "版本格式无效。"
    done
}

choose_docker_tag() {
    local choice value
    choice=$(tui_menu "Docker 镜像版本" "latest 使用项目发布的 latest 标签；也可指定完整版本或主版本标签。" 1 \
        1 "latest" 2 "指定版本/主版本标签") || return 1
    [[ "$choice" == 1 ]] && { printf 'latest\n'; return 0; }
    while true; do
        value=$(tui_input "输入 latest、v6、5.0.1 或 v5.0.1" "latest") || return 1
        if [[ "$value" != "latest" && "$value" =~ ^[0-9]+$ ]]; then value="v${value}"; fi
        if is_docker_tag "$value"; then
            if [[ "$value" != latest && "$value" =~ ^[0-9] ]]; then value="v$value"; fi
            printf '%s\n' "$value"
            return 0
        fi
        error "Docker 标签格式无效。"
    done
}

choose_registry() {
    if ((NONINTERACTIVE)); then
        printf '%s\n' "$CLI_REGISTRY"
        return 0
    fi
    tui_menu "Docker 镜像仓库" "选择镜像拉取仓库。自动模式会先尝试 GHCR，再尝试 Docker Hub。" auto \
        auto "自动选择" ghcr "GitHub Container Registry" dockerhub "Docker Hub"
}

choose_network() {
    if ((NONINTERACTIVE)); then
        printf '%s\n' "$CLI_NETWORK"
        return 0
    fi
    tui_menu "Docker 网络模式" "host 模式与项目 README 一致；bridge 模式会映射单个监听端口。" host \
        host "host（推荐）" bridge "bridge（端口映射）"
}

show_applied_config() {
    local mode="$1" config_file
    title "Snell 已生效配置"
    if [[ "$mode" == native ]]; then
        config_file="${SNELL_CONFIG_TEST_FILE:-$SNELL_CONFIG_FILE}"
        cat "$config_file"
        if [[ -f "$SNELL_LOGLEVEL_FILE" ]]; then
            printf '运行时日志等级: %s\n' "$(cat "$SNELL_LOGLEVEL_FILE")"
        fi
    elif [[ -n "${SNELL_CONFIG_TEST_FILE:-}" ]]; then
        cat "$SNELL_CONFIG_TEST_FILE"
    elif docker_container_exists && docker exec snell cat /snell/snell.conf 2>/dev/null; then
        :
    else
        cat "$DOCKER_ENV_FILE"
    fi
}

show_agent_install_details() {
    local mode="$1"
    ((NONINTERACTIVE)) || return 0
    printf '\nAgent 安装信息:\n'
    if [[ "$mode" == native ]]; then
        printf '安装方式: 原生二进制\n持久化配置: %s\n' "$SNELL_CONFIG_FILE"
    else
        printf '安装方式: Docker\n持久化配置: %s\n' "$DOCKER_ENV_FILE"
    fi
}

show_install_result() {
    local mode="$1" version="$2" image="${3:-}" host_ip host_ipv6 client_version
    title "Snell 安装完成"
    printf '版本/标签: %s\n' "$version"
    [[ -n "$image" ]] && printf '镜像: %s\n' "$image"
    printf '监听端口: %s\nPSK: %s\n' "$cfg_port" "$cfg_psk"
    [[ -n "$cfg_dns" ]] && printf 'DNS: %s\n' "$cfg_dns"
    [[ -n "$cfg_obfs" ]] && printf '混淆: %s -> %s\n' "$cfg_obfs" "$cfg_host"
    [[ -n "${cfg_loglevel:-}" ]] && printf '日志等级: %s\n' "$cfg_loglevel"
    printf '\n客户端配置:\n'
    client_version="latest"
    if is_exact_version "$version"; then client_version="$(version_major "$version")"; elif [[ "$version" =~ ^v?[0-9]+$ ]]; then client_version="$(version_major "$version")"; fi
    host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' || true)
    [[ -z "$host_ip" ]] && host_ip=$(curl -4 -fsSL --connect-timeout 3 https://api.ipify.org 2>/dev/null || true)
    host_ipv6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {sub(/\/.*$/, "", $2); if ($2 !~ /^fe80|^::1/) {print $2; exit}}' || true)
    if [[ -n "$host_ip" ]]; then
        printf 'Snell = snell, %s, %s, psk="%s", version=%s, reuse=true\n' "$host_ip" "$cfg_port" "$cfg_psk" "$client_version"
    fi
    if [[ -n "$host_ipv6" ]]; then
        printf 'Snell = snell, [%s], %s, psk="%s", version=%s, reuse=true\n' "$host_ipv6" "$cfg_port" "$cfg_psk" "$client_version"
    fi
    if [[ "$mode" == native ]]; then
        printf '服务命令: systemctl {start|stop|restart|status} snell（OpenRC 请使用 rc-service snell ...）\n'
        printf '日志命令: journalctl -u snell -f\n'
    else
        printf '\n日志命令: cd %s && %s logs -f snell\n' "$DOCKER_DIR" "${COMPOSE_CMD[*]}"
    fi
    show_agent_install_details "$mode"
    show_applied_config "$mode"
}

native_config_defaults() {
    cfg_default_port=$(config_value listen "$SNELL_CONFIG_FILE" | grep -Eo '[0-9]+$' | tail -n 1 || true)
    cfg_default_psk=$(config_value psk "$SNELL_CONFIG_FILE" || true)
    cfg_default_ipv6=$(config_value ipv6 "$SNELL_CONFIG_FILE" || printf 'false')
    cfg_default_dns=$(config_value dns "$SNELL_CONFIG_FILE" || true)
    cfg_default_pref=$(config_value dns-ip-preference "$SNELL_CONFIG_FILE" || printf 'prefer-ipv4')
    cfg_default_egress=$(config_value egress-interface "$SNELL_CONFIG_FILE" || true)
    cfg_default_obfs=$(config_value obfs "$SNELL_CONFIG_FILE" || true)
    cfg_default_host=$(config_value host "$SNELL_CONFIG_FILE" || true)
    cfg_default_mode=$(config_value mode "$SNELL_CONFIG_FILE" || printf 'default')
    cfg_default_loglevel=$(cat "$SNELL_LOGLEVEL_FILE" 2>/dev/null || true)

}

docker_config_defaults() {
    cfg_image=$(awk '/^[[:space:]]*image:/ {print $2; exit}' "$DOCKER_COMPOSE_FILE")
    cfg_tag="${cfg_image##*:}"
    cfg_network="bridge"
    grep -q '^[[:space:]]*network_mode:[[:space:]]*host' "$DOCKER_COMPOSE_FILE" && cfg_network="host"
    cfg_default_port=$(dotenv_value LISTEN "$DOCKER_ENV_FILE")
    cfg_default_psk=$(dotenv_value PSK "$DOCKER_ENV_FILE")
    cfg_default_ipv6=$(dotenv_value IPV6 "$DOCKER_ENV_FILE")
    cfg_default_dns=$(dotenv_value DNS "$DOCKER_ENV_FILE")
    cfg_default_pref=$(dotenv_value DNS_IP_PREFERENCE "$DOCKER_ENV_FILE")
    cfg_default_egress=$(dotenv_value EGRESS_INTERFACE "$DOCKER_ENV_FILE")
    cfg_default_obfs=$(dotenv_value OBFS "$DOCKER_ENV_FILE")
    cfg_default_host=$(dotenv_value HOST "$DOCKER_ENV_FILE")
    cfg_default_mode=$(dotenv_value MODE "$DOCKER_ENV_FILE")
    cfg_default_loglevel=$(dotenv_value LOGLEVEL "$DOCKER_ENV_FILE")

}

view_config() {
    local mode config_file="${SNELL_CONFIG_TEST_FILE:-$SNELL_CONFIG_FILE}"
    mode=$(get_mode) || return 1
    title "Snell 配置"
    if [[ "$mode" == native ]]; then
        cat "$config_file"
        if [[ -f "$SNELL_LOGLEVEL_FILE" ]]; then
            printf '运行时日志等级: %s\n' "$(cat "$SNELL_LOGLEVEL_FILE")"
        fi
    elif docker_container_exists; then
        if ! docker exec snell cat /snell/snell.conf 2>/dev/null; then
            if [[ -f "$DOCKER_ENV_FILE" ]]; then
                cat "$DOCKER_ENV_FILE"
            else
                cat "$DOCKER_COMPOSE_FILE"
            fi
        fi
    else
        warn "容器未运行，显示 Docker 环境配置。"
        if [[ -f "$DOCKER_ENV_FILE" ]]; then
            cat "$DOCKER_ENV_FILE"
        else
            cat "$DOCKER_COMPOSE_FILE"
        fi
    fi
}

show_status() {
    local mode
    mode=$(get_mode) || return 1
    title "Snell 状态"
    if [[ "$mode" == native ]]; then
        if systemd_usable && [[ -f "$SNELL_SERVICE_FILE" ]]; then
            systemctl --no-pager --full status snell || true
        elif openrc_usable && [[ -x "$SNELL_INIT_FILE" ]]; then
            rc-service snell status || true
        else
            pgrep -af snell-server || printf '原生进程未运行。\n'
        fi
    else
        ensure_docker || return 1
        compose ps || true
        printf '\n最近日志:\n'
        docker logs --tail 30 snell 2>/dev/null || true
    fi
}

manage_service() {
    local action="$1" mode
    mode=$(get_mode) || return 1
    if [[ "$mode" == native ]]; then
        native_service_action "$action" || return 1
    else
        ensure_docker || return 1
        case "$action" in
            start) compose up -d ;;
            stop) compose stop ;;
            restart) compose restart ;;
        esac
    fi
    success "操作完成: $action"
}

reconfigure() {
    local mode version network image registry
    mode=$(get_mode) || return 1
    if [[ "$mode" == native ]]; then
        version=$(get_native_version) || { error "无法识别原生 Snell 版本。"; return 1; }
        native_config_defaults
        collect_config native "$version" "" "$cfg_default_port" "$cfg_default_psk" "$cfg_default_ipv6" \
            "$cfg_default_dns" "$cfg_default_pref" "$cfg_default_egress" "$cfg_default_obfs" "$cfg_default_host" "$cfg_default_mode" "$cfg_default_loglevel" || return 1
        show_summary "原生二进制" "$version"
        tui_yesno "确认写入新配置并重启 Snell？" "y" || return 0
        backup_file "$SNELL_CONFIG_FILE"
        write_native_config "$version"
        write_native_loglevel
        write_service_files
        native_service_action restart || return 1
        show_install_result native "$version"
        return 0
    fi

    docker_config_defaults
    version="$cfg_tag"
    network="$cfg_network"
    collect_config docker "$version" "$network" "$cfg_default_port" "$cfg_default_psk" "$cfg_default_ipv6" \
        "$cfg_default_dns" "$cfg_default_pref" "$cfg_default_egress" "$cfg_default_obfs" "$cfg_default_host" "$cfg_default_mode" "$cfg_default_loglevel" || return 1
    show_summary "Docker" "$version" "$network" "$cfg_image"
    tui_yesno "确认更新 Docker Compose 配置并重建容器？" "y" || return 0
    ensure_docker
    registry=auto
    [[ "$cfg_image" == "$IMAGE_GHCR:"* ]] && registry=ghcr
    [[ "$cfg_image" == "$IMAGE_DOCKERHUB:"* ]] && registry=dockerhub
    pull_docker_image "$version" "$registry"
    image="$selected_image"
    docker_apply "$image" "$network" true
}

update_snell() {
    local mode current latest stage old_binary
    mode=$(get_mode) || return 1
    if [[ "$mode" == docker ]]; then
        docker_config_defaults
        ensure_docker
        compose pull
        compose up -d --remove-orphans
        wait_for_docker_container || { error "Docker 更新后容器未运行。"; return 1; }
        success "Docker 镜像更新完成。"
        return 0
    fi

    current=$(get_native_version || true)
    latest=$(get_latest_version || true)
    [[ -n "$latest" ]] || { error "无法获取最新版本。"; return 1; }
    printf '当前版本: %s\n最新版本: %s\n' "${current:-未知}" "$latest"
    [[ "$current" == "$latest" ]] && { info "当前已经是最新版本。"; return 0; }
    tui_yesno "是否更新到 v${latest}？" "n" || return 0
    stage=$(download_native_binary "$latest") || return 1
    old_binary="${SNELL_BIN}.rollback"
    native_stop
    [[ -f "$SNELL_BIN" ]] && cp -a "$SNELL_BIN" "$old_binary"
    mv -f "$stage" "$SNELL_BIN"
    if native_start; then
        rm -f "$old_binary"
        success "原生 Snell 更新完成。"
    else
        error "新版本启动失败，正在回滚。"
        native_stop
        [[ -f "$old_binary" ]] && mv -f "$old_binary" "$SNELL_BIN"
        native_start || true
        return 1
    fi
}

agent_reconfigure() {
    local mode version network image registry
    mode=$(get_mode) || return 1
    if [[ "$mode" == native ]]; then
        version=$(get_native_version) || { error "无法识别原生 Snell 版本。"; return 1; }
        native_config_defaults
        [[ "$CLI_SET_METHOD" == 0 || "$CLI_METHOD" == native ]] || { error "不能通过 reconfigure 切换安装方式。"; return 1; }
        [[ "$CLI_SET_VERSION" == 0 || "$CLI_VERSION" == "$version" ]] || { error "reconfigure 不能修改版本，请使用 --agent-update。"; return 1; }
        [[ "$CLI_SET_NETWORK" == 0 || "$CLI_NETWORK" == host ]] || { error "native 不支持 NETWORK=bridge。"; return 1; }
        CLI_METHOD=native
        CLI_VERSION="$version"
        CLI_NETWORK=host
        ((CLI_SET_PORT)) || CLI_PORT="$cfg_default_port"
        ((CLI_SET_PSK)) || CLI_PSK="$cfg_default_psk"
        ((CLI_SET_IPV6)) || CLI_IPV6="$cfg_default_ipv6"
        ((CLI_SET_DNS)) || CLI_DNS="$cfg_default_dns"
        ((CLI_SET_DNS_PREF)) || CLI_DNS_PREF="$cfg_default_pref"
        ((CLI_SET_EGRESS)) || CLI_EGRESS="$cfg_default_egress"
        ((CLI_SET_OBFS)) || CLI_OBFS="${cfg_default_obfs:-none}"
        ((CLI_SET_HOST)) || CLI_HOST="$cfg_default_host"
        ((CLI_SET_MODE)) || CLI_MODE="$cfg_default_mode"
        ((CLI_SET_LOGLEVEL)) || CLI_LOGLEVEL="$cfg_default_loglevel"
        if ((CLI_SET_OBFS)) && [[ "$CLI_OBFS" == none ]] && ((CLI_SET_HOST == 0)); then CLI_HOST=""; fi
        collect_config native "$version" host "$CLI_PORT" "$CLI_PSK" "$CLI_IPV6" "$CLI_DNS" "$CLI_DNS_PREF" \
            "$CLI_EGRESS" "$CLI_OBFS" "$CLI_HOST" "$CLI_MODE" "$CLI_LOGLEVEL" || return 1
        if ((CLI_DRY_RUN)); then
            agent_dry_run
            return 0
        fi
        backup_file "$SNELL_CONFIG_FILE"
        write_native_config "$version"
        write_native_loglevel
        write_service_files
        native_service_action restart || return 1
        show_install_result native "$version"
        return 0
    fi

    docker_config_defaults
    [[ "$CLI_SET_METHOD" == 0 || "$CLI_METHOD" == docker ]] || { error "不能通过 reconfigure 切换安装方式。"; return 1; }
    [[ "$CLI_SET_VERSION" == 0 || "$CLI_VERSION" == "$cfg_tag" ]] || { error "reconfigure 不能修改版本，请使用 --agent-update。"; return 1; }
    [[ "$CLI_SET_NETWORK" == 0 || "$CLI_NETWORK" == "$cfg_network" ]] || { error "reconfigure 不能修改网络模式，请重新安装或使用 TUI。"; return 1; }
    CLI_METHOD=docker
    CLI_VERSION="$cfg_tag"
    CLI_NETWORK="$cfg_network"
    ((CLI_SET_PORT)) || CLI_PORT="$cfg_default_port"
    ((CLI_SET_PSK)) || CLI_PSK="$cfg_default_psk"
    ((CLI_SET_IPV6)) || CLI_IPV6="${cfg_default_ipv6:-false}"
    ((CLI_SET_DNS)) || CLI_DNS="$cfg_default_dns"
    ((CLI_SET_DNS_PREF)) || CLI_DNS_PREF="${cfg_default_pref:-prefer-ipv4}"
    ((CLI_SET_EGRESS)) || CLI_EGRESS="$cfg_default_egress"
    ((CLI_SET_OBFS)) || CLI_OBFS="${cfg_default_obfs:-none}"
    ((CLI_SET_HOST)) || CLI_HOST="$cfg_default_host"
    ((CLI_SET_MODE)) || CLI_MODE="${cfg_default_mode:-default}"
    ((CLI_SET_LOGLEVEL)) || CLI_LOGLEVEL="$cfg_default_loglevel"

    if ((CLI_SET_OBFS)) && [[ "$CLI_OBFS" == none ]] && ((CLI_SET_HOST == 0)); then CLI_HOST=""; fi
    collect_config docker "$CLI_VERSION" "$CLI_NETWORK" "$CLI_PORT" "$CLI_PSK" "$CLI_IPV6" "$CLI_DNS" "$CLI_DNS_PREF" \
        "$CLI_EGRESS" "$CLI_OBFS" "$CLI_HOST" "$CLI_MODE" "$CLI_LOGLEVEL" || return 1
    if ((CLI_DRY_RUN)); then
        agent_dry_run
        return 0
    fi
    image="$cfg_image"
    registry=auto
    [[ "$image" == "$IMAGE_GHCR:"* ]] && registry=ghcr
    [[ "$image" == "$IMAGE_DOCKERHUB:"* ]] && registry=dockerhub
    pull_docker_image "$CLI_VERSION" "$registry"
    docker_apply "$selected_image" "$CLI_NETWORK" true
}

uninstall_native() {
    native_stop
    if systemd_usable; then
        systemctl disable snell >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$SNELL_SERVICE_FILE" "$SNELL_INIT_FILE" "$SNELL_BIN" "$SNELL_LOGLEVEL_FILE" "${SNELL_BIN}.rollback" \
        "${SNELL_BIN}.backup."* "${SNELL_CONFIG_FILE}.backup."*
    rm -rf "$SNELL_CONFIG_DIR"
    if command_exists userdel; then userdel "$SNELL_USER" >/dev/null 2>&1 || true; fi
    if command_exists groupdel; then groupdel "$SNELL_GROUP" >/dev/null 2>&1 || true; fi
    success "原生 Snell 已卸载。"
}

uninstall_docker() {
    local image=""
    if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
        image=$(awk '/^[[:space:]]*image:/ {print $2; exit}' "$DOCKER_COMPOSE_FILE")
        ensure_docker || true
        if ((${#COMPOSE_CMD[@]} > 0)); then
            compose down --remove-orphans >/dev/null 2>&1 || true
        fi
    fi
    [[ -n "$image" ]] && docker image rm "$image" >/dev/null 2>&1 || true
    rm -rf "$DOCKER_DIR"
    success "Docker Snell 已卸载；未执行全局 Docker prune。"
}

uninstall_snell() {
    local native=false docker=false
    has_native_install && native=true
    has_docker_install && docker=true
    [[ "$native" == false && "$docker" == false ]] && { error "未检测到 Snell 安装。"; return 1; }
    tui_yesno "确认卸载检测到的 Snell 安装？配置、容器和服务文件都会删除。" "n" || return 0
    [[ "$native" == true ]] && uninstall_native
    [[ "$docker" == true ]] && uninstall_docker
    rm -rf "$STATE_DIR"
    success "Snell 卸载完成。"
}

install_wizard() {
    local method version network registry
    method=$(tui_menu "Snell 安装方式" "选择安装方式。" native \
        native "原生二进制（systemd/OpenRC）" docker "Docker 容器（项目镜像）") || return 1
    if [[ "$method" == native ]]; then
        version=$(choose_native_version) || return 1
        collect_config native "$version" "" "" "" "false" "" "prefer-ipv4" "" "" "" "default" "" || return 1
        show_summary "原生二进制" "$version"
        tui_yesno "确认安装？" "y" || return 0
        native_install "$version"
        return
    fi

    version=$(choose_docker_tag) || return 1
    network=$(choose_network) || return 1
    registry=$(choose_registry) || return 1
    collect_config docker "$version" "$network" "" "" "false" "" "prefer-ipv4" "" "" "" "default" "" || return 1
    show_summary "Docker" "$version" "$network"
    tui_yesno "确认安装？" "y" || return 0
    docker_install "$version" "$network" "$registry"
}

agent_dry_run() {
    local image
    printf 'DRY-RUN\nMETHOD=%s\nVERSION=%s\nNETWORK=%s\n' "$CLI_METHOD" "$CLI_VERSION" "$CLI_NETWORK"
    if [[ "$CLI_METHOD" == native ]]; then
        printf '%s\n' '--- snell.conf ---'
        render_snell_config "$CLI_VERSION" "$cfg_port" "$cfg_psk" "$cfg_ipv6" "$cfg_dns" "$cfg_dns_pref" \
            "$cfg_egress" "$cfg_obfs" "$cfg_host" "$cfg_mode"
        printf 'LOGLEVEL=%s\n' "${cfg_loglevel:-<snell-default>}"
        printf 'COMMAND='
        render_native_command
        return 0
    fi
    docker_option_values
    case "$CLI_REGISTRY" in
        dockerhub) image="${IMAGE_DOCKERHUB}:${CLI_VERSION}" ;;
        *) image="${IMAGE_GHCR}:${CLI_VERSION}" ;;
    esac
    printf '%s\n' '--- .env ---'
    render_env_file "$cfg_port" "$cfg_psk" "$docker_dns" "$docker_dns_pref" "$docker_ipv6" \
        "$docker_egress" "$docker_obfs" "$docker_host" "$docker_mode" "$docker_loglevel"
    printf '%s\n' '--- docker-compose.yml ---'
    render_compose "$image" "$CLI_NETWORK" "$cfg_port" "$docker_dns" "$docker_dns_pref" "$docker_ipv6" \
        "$docker_egress" "$docker_obfs" "$docker_host" "$docker_mode" "$docker_loglevel"
}

agent_install() {
    local method="$CLI_METHOD"
    NONINTERACTIVE=1
    validate_agent_config
    if [[ "$method" == native && "$CLI_VERSION" == latest ]]; then
        error "native 安装必须使用完整版本号。"
        return 1
    fi
    if [[ "$method" == native ]] && is_musl_system; then
        if [[ "$CLI_ALPINE_FALLBACK" == docker ]]; then
            warn "Alpine/musl 不支持原生 Snell，改用 Docker。"
            method=docker
            CLI_METHOD=docker
        else
            error "当前是 Alpine/musl，原生 Snell 不可用；请设置 --alpine-fallback docker。"
            return 1
        fi
    fi
    collect_config "$method" "$CLI_VERSION" "$CLI_NETWORK" "$CLI_PORT" "$CLI_PSK" "$CLI_IPV6" \
        "$CLI_DNS" "$CLI_DNS_PREF" "$CLI_EGRESS" "$CLI_OBFS" "$CLI_HOST" "$CLI_MODE" "$CLI_LOGLEVEL" || return 1
    if ((CLI_DRY_RUN)); then
        agent_dry_run
        return 0
    fi
    if [[ "$method" == native ]]; then
        native_install "$CLI_VERSION"
    else
        docker_install "$CLI_VERSION" "$CLI_NETWORK" "$CLI_REGISTRY"
    fi
}

parse_agent_args() {
    local args=("$@") arg value
    local i
    NONINTERACTIVE=1
    for ((i = 0; i < ${#args[@]}; i++)); do
        arg="${args[i]}"
        case "$arg" in
            --config-file) ((i + 1 < ${#args[@]})) || { error "$arg 缺少值"; return 2; }; CLI_CONFIG_FILE="${args[++i]}" ;;
            --config-stdin) CLI_CONFIG_STDIN=1 ;;
        esac
    done
    load_agent_config "$CLI_CONFIG_FILE" || return 1
    for ((i = 0; i < ${#args[@]}; i++)); do
        arg="${args[i]}"
        case "$arg" in
            --agent-install) CLI_ACTION=install ;;
            --agent-config) CLI_ACTION=config ;;
            --agent-status) CLI_ACTION=status ;;
            --agent-start) CLI_ACTION=start ;;
            --agent-stop) CLI_ACTION=stop ;;
            --agent-restart) CLI_ACTION=restart ;;
            --agent-reconfigure) CLI_ACTION=reconfigure ;;
            --agent-update) CLI_ACTION=update ;;
            --agent-uninstall) CLI_ACTION=uninstall ;;
            --config-file|--config-stdin) [[ "$arg" == --config-file ]] && ((i++)) ;;
            --dry-run) CLI_DRY_RUN=1 ;;
            --yes) CLI_YES=1 ;;
            --method|--version|--network|--registry|--port|--psk|--ipv6|--dns|--dns-ip-preference|--egress-interface|--obfs|--host|--mode|--loglevel|--alpine-fallback)
                ((i + 1 < ${#args[@]})) || { error "$arg 缺少值"; return 2; }
                value="${args[++i]}"
                case "$arg" in
                    --method) CLI_METHOD="$value"; CLI_SET_METHOD=1 ;;
                    --version) CLI_VERSION="$value"; CLI_SET_VERSION=1 ;;
                    --network) CLI_NETWORK="$value"; CLI_SET_NETWORK=1 ;;
                    --registry) CLI_REGISTRY="$value" ;;
                    --port) CLI_PORT="$value"; CLI_SET_PORT=1 ;;
                    --psk) CLI_PSK="$value"; CLI_SET_PSK=1 ;;
                    --ipv6) CLI_IPV6="$value"; CLI_SET_IPV6=1 ;;
                    --dns) CLI_DNS="$value"; CLI_SET_DNS=1 ;;
                    --dns-ip-preference) CLI_DNS_PREF="$value"; CLI_SET_DNS_PREF=1 ;;
                    --egress-interface) CLI_EGRESS="$value"; CLI_SET_EGRESS=1 ;;
                    --obfs) CLI_OBFS="$value"; CLI_SET_OBFS=1 ;;
                    --host) CLI_HOST="$value"; CLI_SET_HOST=1 ;;
                    --mode) CLI_MODE="$value"; CLI_SET_MODE=1 ;;
                    --loglevel) CLI_LOGLEVEL="$value"; CLI_SET_LOGLEVEL=1 ;;
                    --alpine-fallback) CLI_ALPINE_FALLBACK="$value" ;;
                esac
                ;;
            --agent-help) agent_help; return 0 ;;
            *) error "未知 agent 参数: $arg"; return 2 ;;
        esac
    done
    [[ -n "$CLI_ACTION" ]] || { error "缺少 --agent-* 操作。"; return 2; }
}

agent_main() {
    parse_agent_args "$@" || return $?
    if [[ "$CLI_ACTION" != install && "$CLI_ACTION" != config && "$CLI_ACTION" != status && "$CLI_YES" != 1 ]]; then
        error "此 agent 操作需要显式提供 --yes。"
        return 2
    fi
    if [[ "$CLI_ACTION" == install && "$CLI_DRY_RUN" == 1 ]]; then
        agent_install
        return
    fi
    if [[ "$CLI_ACTION" == config ]]; then
        [[ "$EUID" -eq 0 ]] || { error "查看已安装配置需要 root。"; return 1; }
        view_config
        return
    fi
    [[ "$EUID" -eq 0 ]] || { error "安装和管理操作需要 root。"; return 1; }
    case "$CLI_ACTION" in
        install) agent_install ;;
        config) view_config ;;
        status) show_status ;;
        start|stop|restart) manage_service "$CLI_ACTION" ;;
        reconfigure) agent_reconfigure ;;
        update) update_snell ;;
        uninstall)
            ((CLI_YES == 1)) || { error "卸载必须显式提供 --yes。"; return 2; }
            uninstall_snell
            ;;
        *) error "未知 agent 操作: $CLI_ACTION"; return 2 ;;
    esac
}

show_menu() {
    clear_screen
    title "Snell 一键管理脚本 v${SCRIPT_VERSION}"
    if has_native_install; then printf '检测到: 原生安装\n' >&2; fi
    if has_docker_install; then printf '检测到: Docker 安装\n' >&2; fi
    printf '\n' >&2
    tui_menu "Snell 管理" "请选择操作。" 1 \
        1 "安装 Snell" \
        2 "查看配置" \
        3 "查看状态" \
        4 "修改配置" \
        5 "启动" \
        6 "停止" \
        7 "重启" \
        8 "更新" \
        9 "卸载" \
        0 "退出"
}

self_test() {
    local config compose_text script_path
    script_path="${BASH_SOURCE[0]}"
    [[ "$(version_major v6.0.0b4)" == 6 ]] || { error 'version_major failed'; return 1; }
    version_supports_dns v4.1.0 || { error 'version_supports_dns failed'; return 1; }
    version_supports_dns v5.0.1 || { error 'version_supports_dns v5 failed'; return 1; }
    version_supports_v6_options v6.0.0b4 || { error 'version_supports_v6_options failed'; return 1; }
    ! version_supports_dns v4.0.0 || { error 'version boundary failed'; return 1; }
    is_valid_psk 'Abc123._+=/-abcdef' || { error 'PSK validation failed'; return 1; }
    ! is_valid_psk 'short-psk' || { error 'short PSK rejection failed'; return 1; }
    ! is_valid_psk 'bad value with spaces' || { error 'PSK rejection failed'; return 1; }
    config=$(render_snell_config v5.0.1 20000 'Abc123._+=/-abcdef' false '1.1.1.1, 8.8.8.8' '' eth0 http example.com '')
    if ! grep -q '^listen = :::20000$' <<< "$config"; then error 'native listen rendering failed'; return 1; fi
    if grep -q 'PORT' <<< "$config"; then error 'native config contains PORT'; return 1; fi
    compose_text=$(render_compose ghcr.io/cary17/snell:latest bridge 20000 '1.1.1.1' '' false '' '' '' '')
    if ! grep -Fqx '      LISTEN: "${LISTEN}"' <<< "$compose_text"; then error 'compose LISTEN rendering failed'; return 1; fi
    if grep -q '      PORT:' <<< "$compose_text"; then error 'compose contains obsolete PORT'; return 1; fi
    if grep -q '^    volumes:' <<< "$compose_text"; then error 'compose must not mount snell.conf'; return 1; fi
    if ! grep -Fq 'restart) compose restart ;;' "$script_path"; then error 'docker restart must use compose restart'; return 1; fi
    if ! grep -Fq 'compose down --remove-orphans' "$script_path"; then error 'docker config change must remove old container'; return 1; fi
    if ! grep -Fq 'docker_apply "$image" "$network" true' "$script_path"; then error 'docker config change must recreate container'; return 1; fi
    if ! grep -Fq 'https://get.docker.com | bash -s docker' "$script_path"; then error 'official Docker installer command missing'; return 1; fi
    if ! grep -Fq 'https://get.docker.com | bash -s docker --mirror Aliyun' "$script_path"; then error 'Aliyun Docker installer fallback missing'; return 1; fi
    if ! grep -Fq '当前系统是 Alpine/musl，官方 Snell 二进制无法直接进行源码安装。' "$script_path"; then error 'musl native fallback missing'; return 1; fi
    SNELL_LIBC_OVERRIDE=musl is_musl_system || { error 'musl detection failed'; return 1; }
    if SNELL_LIBC_OVERRIDE=glibc is_musl_system; then error 'glibc detection override failed'; return 1; fi
    clear_screen
    printf 'Snell.sh self-test passed\n'
}

usage() {
    cat <<EOF
用法:
  $0                       进入 TUI
  $0 --self-test           运行自检
  $0 --agent-help          输出 AI agent 接口说明
  $0 --agent-install ...   非交互安装
  $0 --agent-status        查看状态
  $0 --agent-start|--agent-stop|--agent-restart
  $0 --agent-uninstall --yes
EOF
}

main() {
    case "${1:-}" in
        --self-test) self_test; return 0 ;;
        --agent-help) agent_help; return 0 ;;
        --agent-install|--agent-config|--agent-status|--agent-start|--agent-stop|--agent-restart|--agent-reconfigure|--agent-update|--agent-uninstall|--config-file|--config-stdin)
            agent_main "$@"
            return
            ;;
        --help|-h) usage; return 0 ;;
    esac
    [[ "$EUID" -eq 0 ]] || { error "请使用 root 运行此脚本。"; return 1; }
    init_tui
    while true; do
        local choice
        choice=$(show_menu) || return 0
        case "$choice" in
            1) install_wizard ;;
            2) view_config ;;
            3) show_status ;;
            4) reconfigure ;;
            5) manage_service start ;;
            6) manage_service stop ;;
            7) manage_service restart ;;
            8) update_snell ;;
            9) uninstall_snell ;;
            0) return 0 ;;
            *) error "无效选择。" ;;
        esac
        [[ "$TUI_TOOL" == "none" ]] && pause_screen
    done
}

if [[ "${SNELL_SOURCE_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
