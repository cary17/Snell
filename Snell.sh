#!/bin/bash

# Snell 一键管理脚本 (v2.5.1)
# 修复下载地址拼接错误、端口/版本提取、状态显示

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 配置路径
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

# 输出函数（均输出到 stderr）
print_info()    { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
print_title()   { echo -e "${CYAN}════════════════════════════════════════════════════════${NC}" >&2; echo -e "${CYAN}  $1${NC}" >&2; echo -e "${CYAN}════════════════════════════════════════════════════════${NC}" >&2; }
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
clean_version() { echo "$1" | tr -d '\r\n[:space:]'; }

format_version_with_v() {
    local v; v=$(clean_version "$1")
    [[ "$v" =~ ^v ]] && echo "$v" || echo "v${v}"
}

format_version_without_v() {
    local v; v=$(clean_version "$1")
    echo "${v#v}"
}

check_version_exists() {
    local ver="$1" arch=$(get_arch)
    local v_with=$(format_version_with_v "$ver")
    local v_without=$(format_version_without_v "$ver")
    # 检查官方源
    curl --head -sf --output /dev/null "https://dl.nssurge.com/snell/snell-server-${v_with}-linux-${arch}.zip" 2>/dev/null && return 0
    # 检查 GitHub 备份源
    curl --head -sf --output /dev/null "${GITHUB_BASE}/${v_with}/snell-server-${v_with}-linux-${arch}.zip" 2>/dev/null && return 0
    return 1
}

get_version_url() {
    local ver="$1" arch=$(get_arch)
    local v_with=$(format_version_with_v "$ver")
    # 优先使用官方源
    if curl --head -sf --output /dev/null "https://dl.nssurge.com/snell/snell-server-${v_with}-linux-${arch}.zip" 2>/dev/null; then
        echo "https://dl.nssurge.com/snell/snell-server-${v_with}-linux-${arch}.zip"
    else
        # 使用 GitHub 备份源
        echo "${GITHUB_BASE}/${v_with}/snell-server-${v_with}-linux-${arch}.zip"
    fi
}

get_official_latest_version() {
    local v; v=$(curl -fsSL https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell 2>/dev/null | grep -oP 'snell-server-v\K\d+\.\d+\.\d+' | head -1)
    [ -z "$v" ] && v=$(curl -fsSL "${GITHUB_API}" 2>/dev/null | grep -oP '"name": "v\K\d+\.\d+\.\d+"' | sed 's/"//g' | sort -V | tail -1)
    clean_version "$v"
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

get_installed_version() {
    if [ -x "${SNELL_INSTALL_DIR}/snell-server" ]; then
        ${SNELL_INSTALL_DIR}/snell-server -v 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+[a-z0-9]*' | head -1 | sed 's/^v//' || echo "未知"
    else
        echo "未知"
    fi
}

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

is_private_ipv4() {
    [[ "$1" =~ ^127\. ]] && return 0
    [[ "$1" =~ ^10\. ]] && return 0
    [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$1" =~ ^192\.168\. ]] && return 0
    return 1
}

get_host_ipv4() {
    local phys_ip=""
    while IFS= read -r line; do
        local iface ip
        iface=$(echo "$line" | awk '{print $2}' | sed 's/://')
        ip=$(echo "$line" | grep -oP 'inet \K[\d.]+')
        [[ "$iface" =~ ^(lo|docker|br-|veth|tun|tap) ]] && continue
        is_private_ipv4 "$ip" && continue
        phys_ip="$ip"
        break
    done <<< "$(ip -4 addr show scope global)"
    [ -n "$phys_ip" ] && { echo "$phys_ip"; return 0; }

    local public; public=$(curl -s4 --connect-timeout 3 ifconfig.me 2>/dev/null) || public=$(curl -s4 --connect-timeout 3 ip.sb 2>/dev/null)
    [ -n "$public" ] && { echo "$public"; return 0; }

    while IFS= read -r line; do
        local iface ip
        iface=$(echo "$line" | awk '{print $2}' | sed 's/://')
        ip=$(echo "$line" | grep -oP 'inet \K[\d.]+')
        [[ "$iface" =~ ^(lo|docker|br-|veth|tun|tap) ]] && continue
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    done <<< "$(ip -4 addr show scope global)"
    return 1
}

get_host_ipv6() {
    ip -6 addr show scope global | grep -v '^fe80' | grep -oP 'inet6 \K[0-9a-f:]+(?=/)' | grep -v '^::1' | head -1
}

get_arch() {
    case $(uname -m) in
        x86_64|amd64) echo "amd64" ;;
        i386|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv8l|armv7|armv8) echo "armv7l" ;;
        *) print_error "不支持的架构"; exit 1 ;;
    esac
}

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
    print_info "检测到包管理器: $pm"
    print_info "正在安装依赖..."
    case $pm in
        apt) apt update; apt install -y wget unzip curl iproute2 openssl procps ;;
        yum) yum install -y wget unzip curl iproute openssl procps-ng ;;
        dnf) dnf install -y wget unzip curl iproute openssl procps-ng ;;
        pacman) pacman -S --noconfirm wget unzip curl iproute2 openssl procps-ng ;;
        zypper) zypper install -y wget unzip curl iproute2 openssl procps ;;
        *) print_warning "未知包管理器，请手动安装依赖" ;;
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
    local min_port=10000 max_port=65535
    for ((i=0; i<100; i++)); do
        local port=$((RANDOM % (max_port - min_port + 1) + min_port))
        is_port_excluded "$port" && continue
        if ! is_port_used "$port"; then echo "$port"; return 0; fi
    done
    print_warning "未找到合适的随机端口，使用默认端口 20000"
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
    ls /sys/class/net 2>/dev/null | grep -v lo | head -1
}

download_snell_binary() {
    local ver=$(clean_version "$1") arch=$(get_arch) url=$(get_version_url "$ver")
    local v_with=$(format_version_with_v "$ver")
    print_info "正在下载 Snell ${v_with} for ${arch}..."
    print_info "下载地址: ${url}"
    rm -rf "$TMP_DIR"; mkdir -p "$TMP_DIR"; cd "$TMP_DIR"
    wget -q --show-progress --timeout=30 --tries=3 "$url" -O snell.zip || { print_error "下载失败"; cd /; rm -rf "$TMP_DIR"; return 1; }
    if ! unzip -t snell.zip &>/dev/null; then print_error "下载的文件损坏"; cd /; rm -rf "$TMP_DIR"; return 1; fi
    print_info "正在解压..."
    unzip -q snell.zip
    [ ! -f snell-server ] && { print_error "解压后未找到 snell-server 文件"; cd /; rm -rf "$TMP_DIR"; return 1; }
    mv snell-server "${SNELL_INSTALL_DIR}/snell-server"
    chmod +x "${SNELL_INSTALL_DIR}/snell-server"
    cd /; rm -rf "$TMP_DIR"
    print_success "二进制安装完成"
}

create_system_user() {
    if ! id -u ${SNELL_USER} &>/dev/null; then
        useradd -r -s /usr/sbin/nologin ${SNELL_USER}
        print_info "创建系统用户: ${SNELL_USER}"
    fi
}

create_binary_config() {
    local version="$1" port="$2" psk="$3" ipv6="$4" dns="$5" egress="$6" obfs="$7" host="$8"
    local version_without_v=$(format_version_without_v "$version")
    mkdir -p "${SNELL_CONFIG_DIR}"
    cat > "${SNELL_CONFIG_FILE}" <<EOF
[snell-server]
listen = ::0:${port}
psk = ${psk}
ipv6 = ${ipv6}
EOF
    if [ -n "$dns" ] && version_compare "$version_without_v" "4.1.0"; then
        echo "dns = ${dns}" >> "${SNELL_CONFIG_FILE}"
    fi
    if [ -n "$egress" ] && version_compare "$version_without_v" "5.0.0"; then
        echo "egress-interface = ${egress}" >> "${SNELL_CONFIG_FILE}"
    fi
    if [ -n "$obfs" ] && [ -n "$host" ] && check_obfs_support "$version_without_v" "$obfs"; then
        echo "obfs = ${obfs}" >> "${SNELL_CONFIG_FILE}"
        echo "host = ${host}" >> "${SNELL_CONFIG_FILE}"
        print_info "已启用混淆模式: ${obfs}"
    else
        local major_version=$(get_major_version "$version_without_v")
        [ -n "$obfs" ] && print_warning "Snell v${major_version} 不支持 ${obfs} 混淆，已跳过"
    fi
    chown -R ${SNELL_USER}:${SNELL_GROUP} "${SNELL_CONFIG_DIR}"
    chmod 640 "${SNELL_CONFIG_FILE}"
    print_info "配置文件已创建"
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
    print_info "systemd 服务已创建"
}

generate_surge_config() {
    local host_ip="$1" port="$2" psk="$3" version="$4" obfs="$5" obfs_host="$6"
    local version_without_v=$(format_version_without_v "$version")
    local major_version=$(get_major_version "$version_without_v")
    local config="Snell = snell, ${host_ip}, ${port}, psk=\"${psk}\", version=${major_version}, reuse=true"
    if [ -n "$obfs" ] && [ -n "$obfs_host" ] && check_obfs_support "$version_without_v" "$obfs"; then
        config="${config}, obfs=${obfs}, obfs-host=${obfs_host}"
    fi
    echo "$config"
}

show_full_config() {
    local install_type="$1" version="$2" port="$3" psk="$4" ipv6="$5" dns="$6" egress="$7" obfs="$8" host="$9"
    local network_mode="${10:-}" docker_user="${11:-}" docker_image="${12:-}"

    [ -z "$port" ] && port=$(grep -oP 'listen = ::0:\K\d+' "${SNELL_CONFIG_FILE}" 2>/dev/null || echo "未知")

    local host_ipv4=$(get_host_ipv4)
    local host_ipv6=$(get_host_ipv6)
    local version_with_v=$(format_version_with_v "$version")

    clear
    print_title "Snell 安装成功！"

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  配置信息${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  安装方式: ${install_type}"
    echo -e "  Version: ${version_with_v}"
    echo -e "  PORT: ${port}"
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
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Surge 客户端配置（可直接复制）${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""

    if [ -n "$host_ipv4" ]; then
        local surge_v4=$(generate_surge_config "$host_ipv4" "$port" "$psk" "$version" "$obfs" "$host")
        echo -e "${CYAN}IPv4:${NC}"
        echo -e "${GREEN}${surge_v4}${NC}"
        echo ""
    fi

    if [ -n "$host_ipv6" ]; then
        local surge_v6=$(generate_surge_config "$host_ipv6" "$port" "$psk" "$version" "$obfs" "$host")
        echo -e "${CYAN}IPv6:${NC}"
        echo -e "${GREEN}${surge_v6}${NC}"
        echo ""
    fi

    if [ -z "$host_ipv4" ] && [ -z "$host_ipv6" ]; then
        echo -e "${RED}未获取到任何 IP 地址，请检查网络配置。${NC}"
    fi

    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"

    if [ "$install_type" = "二进制" ]; then
        echo -e "${CYAN}配置文件:${NC} ${SNELL_CONFIG_FILE}"
        echo -e "${CYAN}日志查看:${NC} journalctl -u snell -f"
    else
        echo -e "${CYAN}配置文件:${NC} ${DOCKER_COMPOSE_FILE}"
        echo -e "${CYAN}日志查看:${NC} docker logs -f snell"
    fi

    echo ""
    echo -e "${YELLOW}提示: 请保存好以上配置信息，特别是密码！${NC}"
}

test_docker_registry() { curl -s -o /dev/null --connect-timeout 2 "https://${1}/v2/" 2>/dev/null && echo "0" || echo "1"; }

select_best_docker_registry() {
    print_info "正在测试镜像仓库连接..."
    [ "$(test_docker_registry ghcr.io)" = "0" ] && echo "$DOCKER_IMAGE_GHCR" || echo "$DOCKER_IMAGE_DOCKERHUB"
}

show_version_menu() {
    {
        local latest_version=$(get_official_latest_version)
        echo ""
        echo -e "${CYAN}请选择要安装的版本：${NC}"
        echo -e "  ${GREEN}1${NC}) 最新稳定版 - v${latest_version}"
        echo -e "  ${GREEN}2${NC}) 手动输入指定版本"
        echo ""
        echo -e "${YELLOW}提示：${NC}"
        echo "  • 手动输入支持完整版本号 (如: 5.0.1, v5.0.0b2, 4.1.1)"
        echo "  • 也支持大版本号 (如: 3, 4, 5) 自动选择对应最新稳定版"
        echo "  • 脚本会自动验证版本是否存在于官方源或 GitHub 备份"
        echo ""

        local selected=""
        while true; do
            choice=$(read_with_default "请选择" "1")
            case $choice in
                1)
                    if [ -z "$latest_version" ]; then
                        print_error "无法获取最新版本信息"
                        continue
                    fi
                    selected="$latest_version"
                    break
                    ;;
                2)
                    while true; do
                        custom_version=$(read_with_default "请输入版本号" "")
                        custom_version=$(echo "$custom_version" | sed 's/^v//' | tr -d '[:space:]')
                        if [ -z "$custom_version" ]; then
                            print_error "版本号不能为空"
                            continue
                        fi
                        if [[ "$custom_version" =~ ^[0-9]+$ ]]; then
                            local resolved=$(resolve_major_version "$custom_version")
                            if [ -n "$resolved" ]; then
                                selected="$resolved"
                                break 2
                            else
                                print_error "找不到版本 ${custom_version}.x 系列的最新稳定版"
                                continue
                            fi
                        fi
                        if check_version_exists "$custom_version"; then
                            selected="$custom_version"
                            break 2
                        else
                            print_error "版本 v${custom_version} 不存在于官方源或 GitHub 备份"
                            print_info "请检查版本号是否正确，支持测试版如 5.0.0b2"
                        fi
                    done
                    ;;
                *) print_warning "无效选择，请输入 1 或 2" ;;
            esac
        done
    } >&2
    echo "$selected"
}

# 交互式收集配置（不包含安装方式和版本选择）
collect_config() {
    local version="$1" install_method="$2"

    # 端口
    echo ""
    print_title "端口配置"
    echo -e "${CYAN}说明: 端口范围 10000-65535，默认自动生成随机可用端口${NC}"
    manual_port=$(read_yes_no "是否手动指定端口" "n")
    if [[ "$manual_port" =~ ^[Yy]$ ]]; then
        while true; do
            port=$(read_with_default "请输入端口号" "")
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 10000 ] 2>/dev/null && [ "$port" -le 65535 ] 2>/dev/null; then
                if is_port_used "$port"; then
                    print_warning "端口 ${port} 已被占用，请重新输入"
                else
                    if is_port_excluded "$port"; then
                        print_warning "端口 ${port} 是常用服务端口，建议更换"
                        confirm_port=$(read_yes_no "是否继续使用" "n")
                        if [[ "$confirm_port" =~ ^[Yy]$ ]]; then break; fi
                    else
                        break
                    fi
                fi
            else
                print_error "端口号必须在 10000-65535 之间"
            fi
        done
    else
        port=$(generate_random_port)
        print_success "已自动生成随机端口: ${port}"
    fi

    # PSK
    echo ""
    print_title "密码配置"
    echo -e "${CYAN}说明: 密码用于客户端连接认证，默认随机生成 24 位强密码${NC}"
    manual_psk=$(read_yes_no "是否手动设置密码" "n")
    if [[ "$manual_psk" =~ ^[Yy]$ ]]; then
        psk=$(read_with_default "请输入密码" "")
        if [ -z "$psk" ]; then
            psk=$(generate_psk)
            print_success "已自动生成密码: ${psk}"
        fi
    else
        psk=$(generate_psk)
        print_success "已自动生成密码: ${psk}"
    fi

    # IPv6
    echo ""
    print_title "IPv6 配置"
    echo -e "${CYAN}说明: 是否启用 IPv6 监听，默认关闭 (false)${NC}"
    ipv6_choice=$(read_yes_no "是否启用 IPv6" "n")
    local ipv6="false"
    if [[ "$ipv6_choice" =~ ^[Yy]$ ]]; then
        ipv6="true"
        print_info "已启用 IPv6"
    else
        print_info "IPv6 保持关闭（默认）"
    fi

    # DNS
    local dns=""
    echo ""
    print_title "DNS 配置 (可选)"
    echo -e "${CYAN}说明:${NC}"
    echo "  • 多个 DNS 请用逗号分隔，例如: 1.1.1.1, 8.8.8.8"
    echo "  • 支持 IPv4 和 IPv6 DNS 服务器"
    echo "  • 不配置则使用系统默认 DNS"
    echo -e "  • ${YELLOW}直接按回车键跳过此项配置${NC}"
    echo ""
    dns=$(read_with_default "请输入 DNS 服务器" "")
    if [ -n "$dns" ]; then
        print_info "已设置 DNS: ${dns}"
    else
        print_info "跳过 DNS 配置（使用系统默认）"
    fi

    # 出口网卡
    local egress="" default_iface=$(detect_interface)
    echo ""
    print_title "出口网卡配置 (可选)"
    echo -e "${CYAN}说明:${NC}"
    echo "  • 用于指定 Snell 服务使用的网络出口接口"
    echo "  • 可用的网络接口列表:"
    if [ -d "/sys/class/net" ]; then
        ls /sys/class/net | grep -v lo | sed 's/^/    - /'
    else
        echo "    (无法获取网络接口列表)"
    fi
    echo "  • 不配置则使用系统默认路由"
    echo -e "  • ${YELLOW}直接按回车键跳过此项配置${NC}"
    echo ""
    [ -n "$default_iface" ] && echo -e "检测到的默认网卡: ${YELLOW}${default_iface}${NC}"
    egress=$(read_with_default "请输入出口网卡名称" "")
    if [ -n "$egress" ]; then
        if [ -d "/sys/class/net/${egress}" ]; then
            print_info "已设置出口网卡: ${egress}"
        else
            print_warning "网卡 ${egress} 不存在，将跳过配置"
            egress=""
        fi
    else
        print_info "跳过出口网卡配置（使用默认路由）"
    fi

    # 混淆
    local obfs="" obfs_host=""
    echo ""
    print_title "混淆配置 (可选)"
    echo -e "${CYAN}说明:${NC}"
    echo "  • 混淆用于隐藏协议特征"
    echo "  • http 混淆所有版本支持"
    echo "  • tls 混淆仅 v3 及以下版本支持"
    echo -e "  • ${YELLOW}直接按回车键跳过此项配置${NC}"
    echo ""
    if [ "$install_method" = "1" ]; then
        local version_without_v=$(format_version_without_v "$version")
        local supported_obfs=$(get_supported_obfs "$version_without_v")
        echo -e "当前版本支持的混淆: ${CYAN}${supported_obfs}${NC}"
    fi
    enable_obfs=$(read_yes_no "是否启用混淆" "n")
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        local version_without_v=$(format_version_without_v "$version")
        local major_ver=$(get_major_version "$version_without_v")
        if [ "$install_method" = "1" ] && [ -n "$major_ver" ] && [ "$major_ver" -le 3 ] 2>/dev/null; then
            echo "请选择混淆模式:"
            echo "  1) http"
            echo "  2) tls"
            obfs_choice=$(read_with_default "请选择" "1")
            case $obfs_choice in
                1) obfs="http" ;;
                2) obfs="tls" ;;
                *) obfs="http" ;;
            esac
        else
            obfs="http"
            print_info "使用 http 混淆"
        fi
        obfs_host=$(read_with_default "请输入混淆域名 (例如: bing.com)" "")
        if [ -z "$obfs_host" ]; then
            print_warning "未设置混淆域名，将跳过混淆配置"
            obfs=""
        else
            print_info "已启用混淆: ${obfs} -> ${obfs_host}"
        fi
    fi

    # 导出到全局变量供调用者使用
    cfg_port="$port"
    cfg_psk="$psk"
    cfg_ipv6="$ipv6"
    cfg_dns="$dns"
    cfg_egress="$egress"
    cfg_obfs="$obfs"
    cfg_host="$obfs_host"
}

install_binary() {
    local version=$(clean_version "$1") port="$2" psk="$3" ipv6="$4" dns="$5" egress="$6" obfs="$7" host="$8"
    print_title "二进制安装 Snell"
    install_dependencies
    create_system_user
    download_snell_binary "$version" || return 1
    create_binary_config "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" || return 1
    create_binary_service
    systemctl enable snell
    systemctl start snell
    print_success "二进制安装完成"
    show_full_config "二进制" "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
}

install_docker() {
    local version=$(clean_version "$1") port="$2" psk="$3" ipv6="$4" dns="$5" egress="$6" obfs="$7" host="$8" network_mode="$9" docker_user="${10}"
    print_title "Docker 方式安装 Snell"

    if ! command -v docker &>/dev/null; then
        print_warning "Docker 未安装，正在安装..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable --now docker
    fi
    if ! command -v docker-compose &>/dev/null; then
        print_warning "docker-compose 未安装，正在安装..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi

    local docker_image=""
    local image_tag=""
    if [ "$version" = "latest" ]; then
        docker_image=$(select_best_docker_registry)
        image_tag="latest"
    else
        local version_with_v=$(format_version_with_v "$version")
        docker_image=$(select_best_docker_registry)
        image_tag="${version_with_v}"
    fi
    local full_image="${docker_image}:${image_tag}"
    print_info "使用镜像: ${full_image}"

    mkdir -p "${DOCKER_COMPOSE_DIR}"
    cat > "${DOCKER_COMPOSE_FILE}" <<EOF
services:
  snell:
    image: ${full_image}
    container_name: snell
    restart: unless-stopped
EOF
    if [ "$network_mode" = "host" ]; then
        echo "    network_mode: host" >> "${DOCKER_COMPOSE_FILE}"
    else
        echo "    ports:" >> "${DOCKER_COMPOSE_FILE}"
        echo "      - \"${port}:${port}\"" >> "${DOCKER_COMPOSE_FILE}"
    fi
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

    cd "${DOCKER_COMPOSE_DIR}"
    if [ "$version" = "latest" ]; then
        print_info "正在拉取最新镜像..."
        docker-compose pull
    fi
    docker-compose up -d
    print_success "Docker 安装完成"

    local display_version="${version}"
    [ "$version" != "latest" ] && display_version=$(format_version_with_v "$version")
    show_full_config "Docker" "$display_version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" "$network_mode" "$docker_user" "$full_image"
}

install_wizard() {
    print_title "Snell 安装向导"

    echo "请选择安装方式："
    echo "  1) 二进制安装 (systemd，性能最优) 【默认】"
    echo "  2) Docker 安装 (容器化，便于管理)"
    install_method=$(read_with_default "请选择" "1")

    version=$(show_version_menu)
    if [ -z "$version" ]; then
        print_error "版本选择失败"
        return 1
    fi
    local version_with_v=$(format_version_with_v "$version")
    print_success "将安装版本: ${version_with_v}"

    local network_mode="host" docker_user=""
    if [ "$install_method" = "2" ]; then
        echo ""
        print_title "Docker 网络配置"
        echo "请选择网络模式："
        echo "  1) host 模式 (默认，性能最佳) 【默认】"
        echo "  2) bridge 模式 (需要映射端口)"
        network_choice=$(read_with_default "请选择" "1")
        if [ "$network_choice" = "2" ]; then
            network_mode="bridge"
            print_info "将使用 bridge 模式"
        else
            network_mode="host"
            print_info "将使用 host 模式"
        fi
        echo ""
        set_user=$(read_yes_no "是否指定运行用户" "n")
        if [[ "$set_user" =~ ^[Yy]$ ]]; then
            docker_user=$(read_with_default "请输入用户 ID 或用户名" "")
            [ -n "$docker_user" ] && print_info "将使用用户: ${docker_user}"
        fi
    fi

    # 收集配置
    collect_config "$version" "$install_method"

    # 使用全局变量
    local port="$cfg_port" psk="$cfg_psk" ipv6="$cfg_ipv6" dns="$cfg_dns" egress="$cfg_egress" obfs="$cfg_obfs" host="$cfg_host"

    # 摘要
    echo ""
    print_title "安装配置摘要"
    echo -e "安装方式: ${CYAN}$([ "$install_method" = "1" ] && echo "二进制" || echo "Docker")${NC}"
    echo -e "版本: ${CYAN}${version_with_v}${NC}"
    echo -e "端口: ${CYAN}${port}${NC}"
    echo -e "密码: ${CYAN}${psk}${NC}"
    echo -e "IPv6: ${CYAN}${ipv6}${NC}"
    [ -n "$dns" ] && echo -e "DNS: ${CYAN}${dns}${NC}"
    [ -n "$egress" ] && echo -e "出口网卡: ${CYAN}${egress}${NC}"
    if [ -n "$obfs" ] && [ -n "$host" ]; then
        echo -e "混淆: ${CYAN}${obfs} -> ${host}${NC}"
    else
        echo -e "混淆: ${YELLOW}未启用${NC}"
    fi
    [ "$install_method" = "2" ] && echo -e "网络模式: ${CYAN}${network_mode}${NC}" && [ -n "$docker_user" ] && echo -e "运行用户: ${CYAN}${docker_user}${NC}"
    echo ""

    confirm=$(read_yes_no "确认安装" "y")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "取消安装"
        return 0
    fi

    if [ "$install_method" = "1" ]; then
        install_binary "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
    else
        install_docker "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" "$network_mode" "$docker_user"
    fi
}

view_config() {
    print_title "Snell 配置信息"
    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        local ver=$(get_installed_version)
        local port=$(grep -oP 'listen = ::0:\K\d+' "${SNELL_CONFIG_FILE}" 2>/dev/null || echo "")
        local psk=$(grep 'psk = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        local ipv6=$(grep 'ipv6 = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        local dns=$(grep 'dns = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2- | xargs)
        local egress=$(grep 'egress-interface = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        local obfs=$(grep 'obfs = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        local host=$(grep 'host = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | xargs)
        show_full_config "二进制" "$ver" "${port:-未知}" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
    elif docker ps | grep -q snell 2>/dev/null; then
        local config=$(docker exec snell cat /snell/snell.conf 2>/dev/null)
        if [ -n "$config" ]; then
            local ver=$(docker exec snell ./snell-server -v 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+[a-z0-9]*' | sed 's/^v//')
            local port=$(echo "$config" | grep -oP 'listen = ::0:\K\d+')
            local psk=$(echo "$config" | grep 'psk = ' | cut -d'=' -f2 | xargs)
            local ipv6=$(echo "$config" | grep 'ipv6 = ' | cut -d'=' -f2 | xargs)
            local dns=$(echo "$config" | grep 'dns = ' | cut -d'=' -f2- | xargs)
            local egress=$(echo "$config" | grep 'egress-interface = ' | cut -d'=' -f2 | xargs)
            local obfs=$(echo "$config" | grep 'obfs = ' | cut -d'=' -f2 | xargs)
            local host=$(echo "$config" | grep 'host = ' | cut -d'=' -f2 | xargs)
            local net=$(grep "network_mode:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}' || echo "host")
            local user=$(grep "user:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}' | sed 's/"//g')
            local img=$(grep "image:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}')
            show_full_config "Docker" "$ver" "${port:-未知}" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" "$net" "$user" "$img"
        else
            print_error "无法获取容器配置"
        fi
    else
        print_error "未检测到 Snell 安装"
        return 1
    fi
}

show_status() {
    print_title "Snell 运行状态"
    if systemctl is-active snell &>/dev/null; then
        echo -e "${BLUE}服务状态:${NC}"; systemctl status snell --no-pager -l
        echo -e "\n${BLUE}进程信息:${NC}"; ps aux | grep snell-server | grep -v grep
        echo -e "\n${BLUE}端口监听:${NC}"
        local port=$(grep -oP 'listen = ::0:\K\d+' "${SNELL_CONFIG_FILE}" 2>/dev/null | head -1)
        [ -n "$port" ] && ss -tlnp 2>/dev/null | grep "$port" || netstat -tlnp 2>/dev/null | grep "$port" || echo "未检测到监听"
    elif docker ps | grep -q snell 2>/dev/null; then
        echo -e "${BLUE}容器状态:${NC}"; docker ps --filter name=snell
        echo -e "\n${BLUE}容器详情:${NC}"; docker inspect snell | grep -E "NetworkMode|User" | head -2
        echo -e "\n${BLUE}最近日志:${NC}"; docker logs --tail 30 snell
    else
        print_error "Snell 未运行"
        return 1
    fi
}

manage_service() {
    local action="$1" action_name="$2"
    if systemctl list-unit-files | grep -q snell.service 2>/dev/null; then
        systemctl ${action} snell
        print_info "Snell ${action_name} 完成"
        if [ "$action" = "start" ] || [ "$action" = "restart" ]; then sleep 2; view_config; fi
    elif docker ps -a | grep -q snell 2>/dev/null; then
        cd "${DOCKER_COMPOSE_DIR}" 2>/dev/null
        case $action in
            start) if grep -q "image:.*:latest" "${DOCKER_COMPOSE_FILE}" 2>/dev/null; then print_info "拉取最新镜像..."; docker-compose pull; fi; docker-compose up -d ;;
            stop) docker-compose stop ;;
            restart) if grep -q "image:.*:latest" "${DOCKER_COMPOSE_FILE}" 2>/dev/null; then docker-compose pull; fi; docker-compose restart ;;
        esac
        print_info "Snell ${action_name} 完成"
        if [ "$action" = "start" ] || [ "$action" = "restart" ]; then sleep 2; view_config; fi
    else
        print_error "未检测到 Snell 安装"
        return 1
    fi
}

update_snell() {
    print_title "更新 Snell"
    if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
        local current_version=$(get_installed_version)
        echo -e "当前版本: ${current_version}"
        local latest_version=$(get_official_latest_version)
        if [ -z "$latest_version" ]; then print_error "获取最新版本失败"; return 1; fi
        echo -e "最新稳定版: ${latest_version}"
        if [ "$current_version" = "$latest_version" ]; then print_info "当前已是最新稳定版"; return 0; fi
        local latest_with_v=$(format_version_with_v "$latest_version")
        confirm=$(read_yes_no "是否更新到 ${latest_with_v}" "n")
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
        local backup_config="${SNELL_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "${SNELL_CONFIG_FILE}" "${backup_config}"
        print_info "已备份配置: ${backup_config}"
        systemctl stop snell
        local old_binary="${SNELL_INSTALL_DIR}/snell-server.old"
        [ -f "${SNELL_INSTALL_DIR}/snell-server" ] && mv "${SNELL_INSTALL_DIR}/snell-server" "${old_binary}"
        if download_snell_binary "$latest_version"; then
            chmod +x "${SNELL_INSTALL_DIR}/snell-server"
            systemctl start snell; sleep 2
            if systemctl is-active snell &>/dev/null; then
                print_success "更新完成！"; rm -f "${old_binary}"; print_info "已清理旧版本"; view_config
            else
                print_error "新版本启动失败，回滚中..."; systemctl stop snell
                mv "${old_binary}" "${SNELL_INSTALL_DIR}/snell-server"; chmod +x "${SNELL_INSTALL_DIR}/snell-server"
                systemctl start snell; print_error "已回滚到 v${current_version}"; return 1
            fi
        else
            print_error "下载失败，恢复中..."
            [ -f "${old_binary}" ] && mv "${old_binary}" "${SNELL_INSTALL_DIR}/snell-server"; chmod +x "${SNELL_INSTALL_DIR}/snell-server"
            systemctl start snell; return 1
        fi
    elif docker ps | grep -q snell; then
        print_info "正在更新 Docker 镜像..."
        cd "${DOCKER_COMPOSE_DIR}"
        local current_image=$(grep "image:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}')
        local current_tag=$(echo "$current_image" | cut -d':' -f2)
        if [ "$current_tag" = "latest" ]; then
            docker-compose pull; docker-compose up -d; docker image prune -f; print_success "更新完成！"; view_config
        else
            local latest_version=$(get_official_latest_version)
            local latest_version_with_v=$(format_version_with_v "$latest_version")
            if [ -n "$latest_version" ] && [ "$current_tag" != "$latest_version_with_v" ]; then
                confirm=$(read_yes_no "发现新版本 ${latest_version_with_v}，是否更新" "n")
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    local new_image=$(echo "$current_image" | sed "s/${current_tag}/${latest_version_with_v}/")
                    sed -i "s|image: ${current_image}|image: ${new_image}|g" "${DOCKER_COMPOSE_FILE}"
                    docker-compose pull; docker-compose up -d; docker image prune -f; print_success "更新完成！"; view_config
                fi
            else
                print_info "当前已是最新版本"
            fi
        fi
    else
        print_error "未检测到 Snell 安装"
    fi
}

change_config() {
    print_title "修改 Snell 配置"

    local install_method version
    if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
        install_method="1"
        version=$(get_installed_version)
    elif docker ps -a | grep -q snell; then
        install_method="2"
        version=$(docker exec snell ./snell-server -v 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+[a-z0-9]*' | sed 's/^v//')
    else
        print_error "未检测到 Snell 安装"
        return 1
    fi

    [ -z "$version" ] && version="0.0.0"

    collect_config "$version" "$install_method"

    if [ "$install_method" = "1" ]; then
        create_binary_config "$version" "$cfg_port" "$cfg_psk" "$cfg_ipv6" "$cfg_dns" "$cfg_egress" "$cfg_obfs" "$cfg_host"
        systemctl restart snell
        print_info "Snell 已重启并应用新配置"
    else
        local network_mode=$(grep "network_mode:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}')
        [ -z "$network_mode" ] && network_mode="host"
        local docker_user=$(grep "user:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}' | sed 's/"//g')
        local current_image=$(grep "image:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}')
        install_docker "$version" "$cfg_port" "$cfg_psk" "$cfg_ipv6" "$cfg_dns" "$cfg_egress" "$cfg_obfs" "$cfg_host" "$network_mode" "$docker_user"
        print_info "Docker 容器已重启并应用新配置"
    fi

    sleep 1
    view_config
}

uninstall_snell() {
    print_title "彻底卸载 Snell"
    echo -e "${RED}警告：此操作将删除 Snell 及其所有相关文件！${NC}"
    echo -e "${RED}包括：二进制文件、配置文件、systemd服务、Docker容器、镜像、Compose文件等${NC}"
    confirm=$(read_yes_no "确认卸载" "n")
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { print_info "取消卸载"; return 0; }
    if systemctl list-unit-files | grep -q snell.service 2>/dev/null; then
        print_info "停止并禁用 Snell 服务..."
        systemctl stop snell 2>/dev/null; systemctl disable snell 2>/dev/null
        print_info "删除 systemd 服务文件..."; rm -f "${SNELL_SERVICE_FILE}"
        print_info "删除二进制文件..."; rm -f "${SNELL_INSTALL_DIR}/snell-server" "${SNELL_INSTALL_DIR}/snell-server.old"
        print_info "删除配置文件..."; rm -rf "${SNELL_CONFIG_DIR}"
        print_info "删除系统用户..."; userdel ${SNELL_USER} 2>/dev/null
        systemctl daemon-reload
        print_success "二进制版本已完全卸载"
    fi
    if docker ps -a | grep -q snell 2>/dev/null; then
        print_info "停止并删除 Snell 容器..."; cd "${DOCKER_COMPOSE_DIR}" 2>/dev/null; docker-compose down -v 2>/dev/null
        print_info "删除 Docker 镜像..."; local snell_images=$(docker images | grep "snell" | awk '{print $3}')
        [ -n "$snell_images" ] && docker rmi $snell_images 2>/dev/null || true; print_success "已删除 Docker 镜像"
        print_info "删除 Compose 文件及目录..."; rm -rf "${DOCKER_COMPOSE_DIR}"
        print_info "清理未使用的 Docker 资源..."; docker image prune -f 2>/dev/null
        print_success "Docker 版本已完全卸载"
    fi
    rm -rf "${TMP_DIR}"
    print_success "Snell 已彻底卸载"
    echo -e "\n${YELLOW}所有相关文件已清理完成！${NC}"
}

show_menu() {
    clear
    print_title "Snell 一键管理脚本"
    echo -e "  ${GREEN}1${NC}) 安装 Snell"
    echo -e "  ${GREEN}2${NC}) 查看配置"
    echo -e "  ${GREEN}3${NC}) 查看状态"
    echo -e "  ${GREEN}4${NC}) 修改配置"
    echo -e "  ${GREEN}5${NC}) 停止 Snell"
    echo -e "  ${GREEN}6${NC}) 启动 Snell"
    echo -e "  ${GREEN}7${NC}) 重启 Snell"
    echo -e "  ${GREEN}8${NC}) 更新 Snell"
    echo -e "  ${GREEN}9${NC}) 彻底卸载"
    echo -e "  ${RED}0${NC}) 退出"
    echo ""
    echo "────────────────────────────────────────"
    if systemctl is-active snell &>/dev/null; then
        echo -e "状态: ${GREEN}运行中${NC}"
    elif docker ps | grep -q snell 2>/dev/null; then
        echo -e "状态: ${GREEN}运行中${NC}"
    elif [ -f "${SNELL_INSTALL_DIR}/snell-server" ] || docker ps -a | grep -q snell 2>/dev/null; then
        echo -e "状态: ${YELLOW}未运行${NC}"
    else
        echo -e "状态: ${RED}○ 未安装${NC}"
    fi
    echo ""
}

main() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 权限运行！"
        exit 1
    fi
    while true; do
        show_menu
        choice=$(read_with_default "请选择" "")
        case $choice in
            1) install_wizard ;;
            2) view_config ;;
            3) show_status ;;
            4) change_config ;;
            5) manage_service stop "停止" ;;
            6) manage_service start "启动" ;;
            7) manage_service restart "重启" ;;
            8) update_snell ;;
            9) uninstall_snell ;;
            0) print_info "感谢使用，再见！"; exit 0 ;;
            *) [ -n "$choice" ] && print_warning "无效选择，请重新输入" ;;
        esac
        if [ -n "$choice" ]; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

main
