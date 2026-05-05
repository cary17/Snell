#!/bin/bash

# Snell 一键管理脚本 (v2.3)
# 修复版本提取、IP获取、端口显示等问题

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置
SNELL_INSTALL_DIR="/usr/local/bin"
SNELL_CONFIG_DIR="/etc/snell"
SNELL_CONFIG_FILE="${SNELL_CONFIG_DIR}/snell.conf"
SNELL_SERVICE_FILE="/etc/systemd/system/snell.service"
SNELL_USER="snell"
SNELL_GROUP="snell"
GITHUB_BASE="https://raw.githubusercontent.com/cary17/Snell/main/Version"
GITHUB_API="https://api.github.com/repos/cary17/Snell/contents/Version"

DOCKER_IMAGE_GHCR="ghcr.io/cary17/snell"
DOCKER_IMAGE_DOCKERHUB="cary17/snell"
DOCKER_COMPOSE_DIR="/opt/snell"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_DIR}/docker-compose.yml"

TMP_DIR="/tmp/snell_install"

EXCLUDED_PORTS=(
    22 23 25 53 80 110 111 135 139 143 443 445 993 995 1723 3306 3389 5432 5900 6379 8080 8443 8888 9200 27017
)

# 输出函数（均输出到 stderr，避免污染命令替换）
print_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
print_title() {
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}" >&2
    echo -e "${CYAN}  $1${NC}" >&2
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}" >&2
}
print_success() { echo -e "${GREEN}✓${NC} $1" >&2; }

# 读取输入（stdout 返回）
read_with_default() {
    local prompt="$1" default="$2" result
    [ -n "$default" ] && prompt="${prompt} [${default}]: " || prompt="${prompt}: "
    read -p "$prompt" result
    [ -z "$result" ] && result="$default"
    echo "$result"
}

read_yes_no() {
    local prompt="$1" default="$2" result
    if [ "$default" = "y" ] || [ "$default" = "Y" ]; then
        prompt="${prompt} [Y/n]: "
    else
        prompt="${prompt} [y/N]: "
    fi
    read -p "$prompt" result
    [ -z "$result" ] && result="$default"
    echo "$result"
}

# 版本号处理
format_version_with_v() {
    local v; v=$(echo "$1" | tr -d '[:space:]')
    [[ "$v" =~ ^v ]] && echo "$v" || echo "v${v}"
}
format_version_without_v() {
    echo "$1" | tr -d '[:space:]' | sed 's/^v//'
}

check_version_exists() {
    local ver="$1" arch=$(get_arch)
    local v_with=$(format_version_with_v "$ver") v_without=$(format_version_without_v "$ver")
    curl --head -sf --output /dev/null "https://dl.nssurge.com/snell/snell-server-${v_with}-linux-${arch}.zip" 2>/dev/null && return 0
    curl --head -sf --output /dev/null "${GITHUB_BASE}/v${v_without}/snell-server-${v_with}-linux-${arch}.zip" 2>/dev/null && return 0
    return 1
}

get_version_url() {
    local ver="$1" arch=$(get_arch)
    local v_with=$(format_version_with_v "$ver") v_without=$(format_version_without_v "$ver")
    if curl --head -sf --output /dev/null "https://dl.nssurge.com/snell/snell-server-${v_with}-linux-${arch}.zip" 2>/dev/null; then
        echo "https://dl.nssurge.com/snell/snell-server-${v_with}-linux-${arch}.zip"
    else
        echo "${GITHUB_BASE}/v${v_without}/snell-server-${v_with}-linux-${arch}.zip"
    fi
}

get_official_latest_version() {
    local v; v=$(curl -fsSL https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell 2>/dev/null | grep -oP 'snell-server-v\K\d+\.\d+\.\d+' | head -1)
    [ -z "$v" ] && v=$(curl -fsSL "${GITHUB_API}" 2>/dev/null | grep -oP '"name": "v\K\d+\.\d+\.\d+"' | sed 's/"//g' | sort -V | tail -1)
    echo "$v"
}

get_major_version() {
    local v; v=$(format_version_without_v "$1")
    echo "$v" | grep -oP '^\d+' || echo "0"
}

resolve_major_version() {
    case $1 in
        3|4|5) curl -fsSL "${GITHUB_API}" 2>/dev/null | grep -oP '"name": "v\K'"$1"'\.[0-9]+\.[0-9]+"' | sed 's/"//g' | sort -V | tail -1 ;;
        *) return 1 ;;
    esac
}

# 获取已安装的版本号（修复提取逻辑）
get_installed_version() {
    if [ -x "${SNELL_INSTALL_DIR}/snell-server" ]; then
        ${SNELL_INSTALL_DIR}/snell-server -v 2>/dev/null | grep -oP '\bv?\K\d+\.\d+\.\d+[a-z0-9]*' | head -1 || echo "未知"
    else
        echo "未知"
    fi
}

# 混淆支持检查
check_obfs_support() {
    local major=$(get_major_version "$1")
    [ -z "$major" ] && return 1
    [ "$2" = "tls" ] && [ "$major" -gt 3 ] 2>/dev/null && return 1
    return 0
}
get_supported_obfs() {
    local major=$(get_major_version "$1")
    [ "$major" -le 3 ] 2>/dev/null && echo "http/tls" || echo "http"
}

# 判断私有 IPv4
is_private_ipv4() {
    [[ "$1" =~ ^127\. ]] && return 0
    [[ "$1" =~ ^10\. ]] && return 0
    [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$1" =~ ^192\.168\. ]] && return 0
    return 1
}

# 获取物理接口 IPv4（排除虚拟接口）
get_host_ipv4() {
    # 遍历所有接口，排除 docker*, br-*, veth*, tun*, tap*, lo, 及它们的子接口
    local phys_ip=""
    while IFS= read -r line; do
        local iface ip
        iface=$(echo "$line" | awk '{print $2}' | sed 's/://')
        ip=$(echo "$line" | grep -oP 'inet \K[\d.]+')
        # 排除虚拟接口
        [[ "$iface" =~ ^(lo|docker|br-|veth|tun|tap) ]] && continue
        # 排除私有地址
        is_private_ipv4 "$ip" && continue
        phys_ip="$ip"
        break
    done <<< "$(ip -4 addr show scope global)"

    [ -n "$phys_ip" ] && { echo "$phys_ip"; return 0; }

    # 公网查询后备
    local public; public=$(curl -s4 --connect-timeout 3 ifconfig.me 2>/dev/null) || public=$(curl -s4 --connect-timeout 3 ip.sb 2>/dev/null)
    [ -n "$public" ] && { echo "$public"; return 0; }

    # 最后回退（仍排除虚拟接口）
    while IFS= read -r line; do
        local iface ip
        iface=$(echo "$line" | awk '{print $2}' | sed 's/://')
        ip=$(echo "$line" | grep -oP 'inet \K[\d.]+')
        [[ "$iface" =~ ^(lo|docker|br-|veth|tun|tap) ]] && continue
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    done <<< "$(ip -4 addr show scope global)"

    return 1
}

# 获取 IPv6 全球单播地址
get_host_ipv6() {
    ip -6 addr show scope global | grep -v '^fe80' | grep -oP 'inet6 \K[0-9a-f:]+(?=/)' | grep -v '^::1' | head -1
}

# 架构获取
get_arch() {
    case $(uname -m) in
        x86_64|amd64) echo "amd64" ;;
        i386|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv8l|armv7|armv8) echo "armv7l" ;;
        *) print_error "不支持的架构" ; exit 1 ;;
    esac
}

# 包管理器检测
detect_package_manager() {
    if   command -v apt &>/dev/null; then echo "apt"
    elif command -v yum &>/dev/null; then echo "yum"
    elif command -v dnf &>/dev/null; then echo "dnf"
    elif command -v pacman &>/dev/null; then echo "pacman"
    elif command -v zypper &>/dev/null; then echo "zypper"
    else echo "unknown"
    fi
}

install_dependencies() {
    local pm=$(detect_package_manager)
    print_info "安装依赖..."
    case $pm in
        apt) apt update; apt install -y wget unzip curl iproute2 openssl procps ;;
        yum) yum install -y wget unzip curl iproute openssl procps-ng ;;
        dnf) dnf install -y wget unzip curl iproute openssl procps-ng ;;
        pacman) pacman -S --noconfirm wget unzip curl iproute2 openssl procps-ng ;;
        zypper) zypper install -y wget unzip curl iproute2 openssl procps ;;
        *) print_warning "未知包管理器，需手动安装依赖" ;;
    esac
}

version_compare() {
    local v1=$(format_version_without_v "$1") v2=$(format_version_without_v "$2")
    [ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -1)" = "$v2" ]
}

is_port_used() {
    local p=$1
    if command -v ss &>/dev/null; then
        ss -tln | grep -q ":${p} " && return 0
        ss -uln | grep -q ":${p} " && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tln | grep -q ":${p} " && return 0
        netstat -uln | grep -q ":${p} " && return 0
    else
        timeout 1 bash -c "echo >/dev/tcp/localhost/${p}" 2>/dev/null && return 0
    fi
    return 1
}

is_port_excluded() {
    for e in "${EXCLUDED_PORTS[@]}"; do [ "$1" -eq "$e" ] 2>/dev/null && return 0; done
    return 1
}

generate_random_port() {
    for ((i=0; i<100; i++)); do
        local p=$((RANDOM % 55536 + 10000))
        is_port_excluded "$p" && continue
        if ! is_port_used "$p"; then echo "$p"; return 0; fi
    done
    print_warning "使用默认端口 20000"
    echo "20000"
}

generate_psk() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 16 | tr -d '\n\r' | tr '+/' '-_' | cut -c1-24
    else
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
    fi
}

detect_interface() {
    ip route | grep default | awk '{print $5}' | head -1
}

download_snell_binary() {
    local ver="$1" arch=$(get_arch) url=$(get_version_url "$ver")
    print_info "下载 Snell $(format_version_with_v "$ver") ..."
    rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"; cd "$TMP_DIR"
    wget -q --show-progress --timeout=30 --tries=3 "$url" -O snell.zip || { print_error "下载失败"; cd /; rm -rf "$TMP_DIR"; return 1; }
    unzip -t snell.zip &>/dev/null || { print_error "文件损坏"; cd /; rm -rf "$TMP_DIR"; return 1; }
    unzip -q snell.zip
    [ -f snell-server ] || { print_error "未找到 snell-server"; cd /; rm -rf "$TMP_DIR"; return 1; }
    mv snell-server "${SNELL_INSTALL_DIR}/snell-server"
    chmod +x "${SNELL_INSTALL_DIR}/snell-server"
    cd /; rm -rf "$TMP_DIR"
    print_success "下载完成"
}

create_system_user() {
    id -u ${SNELL_USER} &>/dev/null || { useradd -r -s /usr/sbin/nologin ${SNELL_USER}; print_info "创建用户 ${SNELL_USER}"; }
}

create_binary_config() {
    local ver="$1" port="$2" psk="$3" ipv6="$4" dns="$5" egress="$6" obfs="$7" host="$8"
    mkdir -p "${SNELL_CONFIG_DIR}"
    cat > "${SNELL_CONFIG_FILE}" <<EOF
[snell-server]
listen = ::0:${port}
psk = ${psk}
ipv6 = ${ipv6}
EOF
    [ -n "$dns" ] && version_compare "$ver" "4.1.0" && echo "dns = ${dns}" >> "${SNELL_CONFIG_FILE}"
    [ -n "$egress" ] && version_compare "$ver" "5.0.0" && echo "egress-interface = ${egress}" >> "${SNELL_CONFIG_FILE}"
    if [ -n "$obfs" ] && [ -n "$host" ] && check_obfs_support "$ver" "$obfs"; then
        echo "obfs = ${obfs}" >> "${SNELL_CONFIG_FILE}"
        echo "host = ${host}" >> "${SNELL_CONFIG_FILE}"
        print_info "已启用混淆: ${obfs}"
    fi
    chown -R ${SNELL_USER}:${SNELL_GROUP} "${SNELL_CONFIG_DIR}"
    chmod 640 "${SNELL_CONFIG_FILE}"
}

create_binary_service() {
    cat > "${SNELL_SERVICE_FILE}" <<EOF
[Unit]
Description=Snell Service
After=network.target

[Service]
Type=simple
User=${SNELL_USER}
Group=${SNELL_GROUP}
LimitNOFILE=32768
ExecStart=${SNELL_INSTALL_DIR}/snell-server -c ${SNELL_CONFIG_FILE}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 生成单条 Surge 配置
generate_surge_config() {
    local ip="$1" port="$2" psk="$3" ver="$4" obfs="$5" obfs_host="$6"
    local major=$(get_major_version "$ver")
    local conf="Snell = snell, ${ip}, ${port}, psk=\"${psk}\", version=${major}, reuse=true"
    if [ -n "$obfs" ] && [ -n "$obfs_host" ] && check_obfs_support "$ver" "$obfs"; then
        conf="${conf}, obfs=${obfs}, obfs-host=${obfs_host}"
    fi
    echo "$conf"
}

# 显示配置（精简版，双栈支持）
show_full_config() {
    local install_type="$1" version="$2" port="$3" psk="$4" ipv6="$5" dns="$6" egress="$7" obfs="$8" host="$9"
    local network_mode="${10:-}" docker_user="${11:-}" docker_image="${12:-}"

    local ipv4=$(get_host_ipv4)
    local ipv6_addr=$(get_host_ipv6)
    local v_with=$(format_version_with_v "$version")

    clear
    print_title "Snell 安装成功！"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  配置信息${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  安装方式: ${install_type}"
    echo -e "  Version: ${v_with}"
    echo -e "  PORT: ${port:-未知}"
    echo -e "  PSK: ${psk}"
    echo -ne "  IPv6 : ${ipv6}"
    [ -n "$dns" ] && echo -ne " | DNS: ${dns}"
    [ -n "$egress" ] && echo -ne " | EGRESS-INTERFACE: ${egress}"
    [ -n "$obfs" ] && [ -n "$host" ] && echo -ne " | OBFS: ${obfs} -> ${host}"
    echo ""
    echo ""

    if [ "$install_type" = "二进制" ]; then
        if systemctl is-active snell &>/dev/null; then
            echo -e "  服务状态: ${GREEN}运行中${NC}"
        else
            echo -e "  服务状态: ${RED}未运行${NC}"
        fi
        echo -e "  服务管理: systemctl {start|stop|restart|status} snell"
    else
        if docker ps | grep -q snell 2>/dev/null; then
            echo -e "  容器状态: ${GREEN}运行中${NC}"
        else
            echo -e "  容器状态: ${RED}未运行${NC}"
        fi
        echo -e "  容器管理: cd ${DOCKER_COMPOSE_DIR} && docker-compose {up -d|down|restart}"
    fi

    echo ""
    echo -e "${GREEN}════════ Surge 客户端配置（可直接复制） ════════${NC}"
    echo ""
    [ -n "$ipv4" ] && echo -e "${CYAN}IPv4:${NC}\n${GREEN}$(generate_surge_config "$ipv4" "$port" "$psk" "$version" "$obfs" "$host")${NC}\n"
    [ -n "$ipv6_addr" ] && echo -e "${CYAN}IPv6:${NC}\n${GREEN}$(generate_surge_config "$ipv6_addr" "$port" "$psk" "$version" "$obfs" "$host")${NC}\n"
    [ -z "$ipv4" ] && [ -z "$ipv6_addr" ] && echo -e "${RED}未获取到任何 IP 地址${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    [ "$install_type" = "二进制" ] && echo -e "配置文件: ${SNELL_CONFIG_FILE}\n日志查看: journalctl -u snell -f" || echo -e "配置文件: ${DOCKER_COMPOSE_FILE}\n日志查看: docker logs -f snell"
    echo -e "\n${YELLOW}提示: 请保存好以上配置信息，特别是密码！${NC}"
}

# 版本选择菜单
show_version_menu() {
    {
        local latest=$(get_official_latest_version)
        echo -e "\n${CYAN}请选择版本：${NC}"
        echo -e "  ${GREEN}1${NC}) 最新稳定版 - v${latest}"
        echo -e "  ${GREEN}2${NC}) 手动输入版本"
        local selected=""
        while true; do
            local choice=$(read_with_default "请选择" "1")
            case $choice in
                1) [ -z "$latest" ] && { print_error "无法获取最新版本"; continue; }; selected="$latest"; break ;;
                2)
                    while true; do
                        local custom=$(read_with_default "输入版本号" "")
                        custom=$(echo "$custom" | sed 's/^v//;s/ //g')
                        [ -z "$custom" ] && { print_error "版本不能为空"; continue; }
                        if [[ "$custom" =~ ^[0-9]+$ ]]; then
                            local resolved=$(resolve_major_version "$custom")
                            [ -n "$resolved" ] && { selected="$resolved"; break 2; } || { print_error "找不到版本 ${custom}.x 系列"; continue; }
                        fi
                        check_version_exists "$custom" && { selected="$custom"; break 2; } || { print_error "版本 v${custom} 不存在"; }
                    done ;;
                *) print_warning "无效选择" ;;
            esac
        done
    } >&2
    echo "$selected"
}

install_binary() {
    print_title "二进制安装 Snell"
    install_dependencies
    create_system_user
    download_snell_binary "$1" || return 1
    create_binary_config "$@"
    create_binary_service
    systemctl enable snell
    systemctl start snell
    print_success "安装完成"
    show_full_config "二进制" "$@"
}

install_docker() {
    local version="$1" port="$2" psk="$3" ipv6="$4" dns="$5" egress="$6" obfs="$7" host="$8" network_mode="$9" docker_user="${10}"
    print_title "Docker 安装 Snell"
    command -v docker &>/dev/null || { print_warning "安装 Docker..."; curl -fsSL https://get.docker.com | bash; systemctl enable --now docker; }
    command -v docker-compose &>/dev/null || { curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose; chmod +x /usr/local/bin/docker-compose; }
    local image; [ "$version" = "latest" ] && image="$(select_best_docker_registry):latest" || image="$(select_best_docker_registry):$(format_version_with_v "$version")"
    mkdir -p "$DOCKER_COMPOSE_DIR"
    cat > "${DOCKER_COMPOSE_FILE}" <<EOF
services:
  snell:
    image: ${image}
    container_name: snell
    restart: unless-stopped
EOF
    [ "$network_mode" = "host" ] && echo "    network_mode: host" >> "${DOCKER_COMPOSE_FILE}" || { echo "    ports:" >> "${DOCKER_COMPOSE_FILE}"; echo "      - \"${port}:${port}\"" >> "${DOCKER_COMPOSE_FILE}"; }
    [ -n "$docker_user" ] && echo "    user: \"${docker_user}\"" >> "${DOCKER_COMPOSE_FILE}"
    cat >> "${DOCKER_COMPOSE_FILE}" <<EOF
    environment:
      - PSK=${psk}
      - PORT=${port}
      - IPV6=${ipv6}
EOF
    [ -n "$dns" ] && echo "      - DNS=${dns}" >> "${DOCKER_COMPOSE_FILE}"
    [ -n "$egress" ] && echo "      - EGRESS_INTERFACE=${egress}" >> "${DOCKER_COMPOSE_FILE}"
    [ -n "$obfs" ] && echo "      - OBFS=${obfs}" >> "${DOCKER_COMPOSE_FILE}"
    [ -n "$host" ] && echo "      - HOST=${host}" >> "${DOCKER_COMPOSE_FILE}"
    cd "$DOCKER_COMPOSE_DIR"
    docker-compose pull 2>/dev/null
    docker-compose up -d
    print_success "Docker 安装完成"
    show_full_config "Docker" "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" "$network_mode" "$docker_user" "$image"
}

install_wizard() {
    print_title "Snell 安装向导"
    echo "1) 二进制安装 (systemd) [默认]"
    echo "2) Docker 安装"
    local method=$(read_with_default "请选择" "1")
    local version=$(show_version_menu)
    [ -z "$version" ] && { print_error "版本选择失败"; return 1; }
    local v_with=$(format_version_with_v "$version")
    print_success "版本: ${v_with}"
    
    local network_mode="host" docker_user=""
    if [ "$method" = "2" ]; then
        print_title "Docker 网络配置"
        echo "1) host 模式 [默认]  2) bridge 模式"
        local nc=$(read_with_default "请选择" "1"); [ "$nc" = "2" ] && network_mode="bridge"
        local setu=$(read_yes_no "是否指定运行用户" "n")
        [[ "$setu" =~ ^[Yy]$ ]] && docker_user=$(read_with_default "用户 ID/名" "")
    fi

    # 端口
    local port=""
    if [[ "$(read_yes_no "手动指定端口?" "n")" =~ ^[Yy]$ ]]; then
        while :; do
            port=$(read_with_default "输入端口" "")
            [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 10000 ] && [ "$port" -le 65535 ] || { print_error "端口范围 10000-65535"; continue; }
            is_port_used "$port" && { print_warning "端口被占用"; continue; }
            is_port_excluded "$port" && { [[ "$(read_yes_no "常用端口，继续?" "n")" =~ ^[Yy]$ ]] && break || continue; }
            break
        done
    else
        port=$(generate_random_port)
        print_success "随机端口: $port"
    fi

    # PSK
    local psk=""
    if [[ "$(read_yes_no "手动设置密码?" "n")" =~ ^[Yy]$ ]]; then
        psk=$(read_with_default "输入密码" "")
        [ -z "$psk" ] && psk=$(generate_psk)
    else
        psk=$(generate_psk)
        print_success "密码: $psk"
    fi

    # IPv6
    local ipv6="false"; [[ "$(read_yes_no "启用 IPv6?" "n")" =~ ^[Yy]$ ]] && ipv6="true"

    # DNS
    local dns=$(read_with_default "DNS 服务器（逗号分隔，回车跳过）" "")
    [ -z "$dns" ] && print_info "跳过 DNS"

    # 出口网卡
    local egress=""; local defif=$(detect_interface)
    egress=$(read_with_default "出口网卡（回车跳过）" "")
    [ -n "$egress" ] && [ ! -d "/sys/class/net/$egress" ] && { print_warning "网卡不存在，忽略"; egress=""; }

    # 混淆
    local obfs="" obfs_host=""
    if [[ "$(read_yes_no "启用混淆?" "n")" =~ ^[Yy]$ ]]; then
        local major=$(get_major_version "$version")
        if [ "$major" -le 3 ] 2>/dev/null; then
            local c=$(read_with_default "混淆类型: 1) http  2) tls" "1")
            [ "$c" = "2" ] && obfs="tls" || obfs="http"
        else
            obfs="http"
        fi
        obfs_host=$(read_with_default "混淆域名" "")
        [ -z "$obfs_host" ] && { print_warning "未设置域名，跳过混淆"; obfs=""; }
    fi

    # 汇总
    echo -e "\n${CYAN}安装配置摘要${NC}"
    echo "安装方式: $([ "$method" = "1" ] && echo 二进制 || echo Docker)"
    echo "版本: ${v_with}"
    echo "端口: ${port}"
    echo "密码: ${psk}"
    echo "IPv6: ${ipv6}"
    [ -n "$dns" ] && echo "DNS: ${dns}"
    [ -n "$egress" ] && echo "出口网卡: ${egress}"
    [ -n "$obfs" ] && echo "混淆: ${obfs} -> ${obfs_host}" || echo "混淆: 未启用"
    [ "$method" = "2" ] && echo "网络模式: ${network_mode}" && [ -n "$docker_user" ] && echo "用户: ${docker_user}"

    [[ ! "$(read_yes_no "确认安装?" "y")" =~ ^[Yy]$ ]] && { print_info "取消安装"; return 0; }

    if [ "$method" = "1" ]; then
        install_binary "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$obfs_host"
    else
        install_docker "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$obfs_host" "$network_mode" "$docker_user"
    fi
}

# 查看配置
view_config() {
    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        local ver=$(get_installed_version)
        local port=$(grep -oP 'listen = :::\K\d+' "${SNELL_CONFIG_FILE}" || echo "")
        local psk=$(grep 'psk = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        local ipv6=$(grep 'ipv6 = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        local dns=$(grep 'dns = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2- | xargs)
        local egress=$(grep 'egress-interface = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        local obfs=$(grep 'obfs = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        local host=$(grep 'host = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        show_full_config "二进制" "$ver" "${port:-未知}" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
    elif docker ps | grep -q snell; then
        local conf=$(docker exec snell cat /snell/snell.conf 2>/dev/null)
        if [ -n "$conf" ]; then
            local ver=$(docker exec snell ./snell-server -v 2>/dev/null | grep -oP '\bv?\K\d+\.\d+\.\d+[a-z0-9]*' | head -1)
            local port=$(echo "$conf" | grep -oP 'listen = :::\K\d+')
            local psk=$(echo "$conf" | grep 'psk = ' | cut -d'=' -f2 | xargs)
            local ipv6=$(echo "$conf" | grep 'ipv6 = ' | cut -d'=' -f2 | xargs)
            local dns=$(echo "$conf" | grep 'dns = ' | cut -d'=' -f2- | xargs)
            local egress=$(echo "$conf" | grep 'egress-interface = ' | cut -d'=' -f2 | xargs)
            local obfs=$(echo "$conf" | grep 'obfs = ' | cut -d'=' -f2 | xargs)
            local host=$(echo "$conf" | grep 'host = ' | cut -d'=' -f2 | xargs)
            local net=$(grep "network_mode:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}' || echo "host")
            local user=$(grep "user:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}' | sed 's/"//g')
            local img=$(grep "image:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}')
            show_full_config "Docker" "$ver" "${port:-未知}" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" "$net" "$user" "$img"
        fi
    else
        print_error "未检测到 Snell"
    fi
}

# 服务管理
manage_service() {
    if systemctl list-unit-files | grep -q snell.service; then
        systemctl "$1" snell
        print_info "Snell $2 完成"
        [ "$1" = "start" ] || [ "$1" = "restart" ] && { sleep 2; view_config; }
    elif docker ps -a | grep -q snell; then
        cd "$DOCKER_COMPOSE_DIR"
        case $1 in
            start) docker-compose up -d ;;
            stop) docker-compose stop ;;
            restart) docker-compose restart ;;
        esac
        print_info "Snell $2 完成"
        [ "$1" = "start" ] || [ "$1" = "restart" ] && { sleep 2; view_config; }
    else
        print_error "未安装"
    fi
}

# 更新
update_snell() {
    if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
        local cur=$(get_installed_version) lat=$(get_official_latest_version)
        echo "当前: ${cur}  最新: ${lat}"
        [ "$cur" = "$lat" ] && { print_info "已是最新"; return; }
        [[ ! "$(read_yes_no "更新到 v${lat}?" "n")" =~ ^[Yy]$ ]] && return
        cp "${SNELL_CONFIG_FILE}" "${SNELL_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M)"
        systemctl stop snell
        [ -f "${SNELL_INSTALL_DIR}/snell-server" ] && mv "${SNELL_INSTALL_DIR}/snell-server" "${SNELL_INSTALL_DIR}/snell-server.old"
        if download_snell_binary "$lat"; then
            chmod +x "${SNELL_INSTALL_DIR}/snell-server"
            systemctl start snell
            sleep 2
            if systemctl is-active snell &>/dev/null; then
                print_success "更新完成"; rm -f "${SNELL_INSTALL_DIR}/snell-server.old"; view_config
            else
                print_error "启动失败，回滚"; mv "${SNELL_INSTALL_DIR}/snell-server.old" "${SNELL_INSTALL_DIR}/snell-server"; systemctl start snell
            fi
        else
            print_error "下载失败"; [ -f "${SNELL_INSTALL_DIR}/snell-server.old" ] && mv "${SNELL_INSTALL_DIR}/snell-server.old" "${SNELL_INSTALL_DIR}/snell-server"; systemctl start snell
        fi
    elif docker ps | grep -q snell; then
        cd "$DOCKER_COMPOSE_DIR"
        docker-compose pull; docker-compose up -d; docker image prune -f
        print_success "Docker 更新完成"; view_config
    else
        print_error "未安装"
    fi
}

# 卸载
uninstall_snell() {
    print_title "彻底卸载 Snell"
    [[ ! "$(read_yes_no "确认卸载?" "n")" =~ ^[Yy]$ ]] && return
    if systemctl list-unit-files | grep -q snell.service; then
        systemctl stop snell; systemctl disable snell
        rm -f "${SNELL_SERVICE_FILE}" "${SNELL_INSTALL_DIR}/snell-server" "${SNELL_INSTALL_DIR}/snell-server.old"
        rm -rf "${SNELL_CONFIG_DIR}"
        userdel ${SNELL_USER} 2>/dev/null
        systemctl daemon-reload
        print_success "二进制已卸载"
    fi
    if docker ps -a | grep -q snell; then
        cd "$DOCKER_COMPOSE_DIR"; docker-compose down -v 2>/dev/null
        docker images | grep "snell" | awk '{print $3}' | xargs docker rmi 2>/dev/null || true
        rm -rf "$DOCKER_COMPOSE_DIR"
        docker image prune -f 2>/dev/null
        print_success "Docker 已卸载"
    fi
}

# 主菜单
show_menu() {
    clear
    print_title "Snell 一键管理脚本"
    echo "  1) 安装 Snell"
    echo "  2) 查看配置"
    echo "  3) 查看状态"
    echo "  4) 修改配置"
    echo "  5) 停止 Snell"
    echo "  6) 启动 Snell"
    echo "  7) 重启 Snell"
    echo "  8) 更新 Snell"
    echo "  9) 彻底卸载"
    echo "  0) 退出"
    echo "────────────────────────────────────────"
    if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
        local ver=$(get_installed_version)
        if systemctl is-active snell &>/dev/null; then
            echo -e "状态: ${GREEN}● 二进制已安装 (v${ver}) | 运行中${NC}"
        else
            echo -e "状态: ${YELLOW}● 二进制已安装 (v${ver}) | 未运行${NC}"
        fi
    elif docker ps -a | grep -q snell 2>/dev/null; then
        if docker ps | grep -q snell; then
            echo -e "状态: ${GREEN}● Docker 已安装 | 运行中${NC}"
        else
            echo -e "状态: ${YELLOW}● Docker 已安装 | 已停止${NC}"
        fi
    else
        echo -e "状态: ${RED}○ 未安装${NC}"
    fi
    echo ""
}

main() {
    [ "$EUID" -ne 0 ] && { print_error "需要 root 权限"; exit 1; }
    while :; do
        show_menu
        local c=$(read_with_default "请选择" "")
        case $c in
            1) install_wizard ;;
            2) view_config ;;
            3) show_status ;;
            4) change_config ;;
            5) manage_service stop 停止 ;;
            6) manage_service start 启动 ;;
            7) manage_service restart 重启 ;;
            8) update_snell ;;
            9) uninstall_snell ;;
            0) print_info "再见"; exit 0 ;;
            *) [ -n "$c" ] && print_warning "无效选择" ;;
        esac
        [ -n "$c" ] && { echo ""; read -p "按回车键继续..."; }
    done
}

main
