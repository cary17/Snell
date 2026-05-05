#!/bin/bash

# Snell 一键管理脚本
# 支持二进制安装（官方+GitHub备份）/ Docker安装
# 完整支持所有配置项：PSK, PORT, IPV6, DNS, EGRESS_INTERFACE, OBFS, HOST

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
GITHUB_BASE="https://github.com/cary17/Snell/raw/main/Version"

# Docker配置
DOCKER_IMAGE_BASE="ghcr.io/cary17/snell"
DOCKER_COMPOSE_DIR="/opt/snell"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_DIR}/docker-compose.yml"

# 需要排除的常用端口（热门服务默认端口）
EXCLUDED_PORTS=(
    22 23 25 53 80 110 111 135 139 143 443 445 993 995 1723 3306 3389 5432 5900 6379 8080 8443 8888 9200 27017
)

# 打印信息函数
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_title() {
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
}

# 获取系统架构
get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64) echo "amd64" ;;
        i386|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7l|armv8l) echo "armv7l" ;;
        *) print_error "不支持的架构: $arch"; exit 1 ;;
    esac
}

# 版本比较
version_compare() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# 检查端口是否被占用
is_port_used() {
    local port=$1
    # 检查 TCP 端口
    if ss -tln | grep -q ":${port} "; then
        return 0
    fi
    # 检查 UDP 端口
    if ss -uln | grep -q ":${port} "; then
        return 0
    fi
    return 1
}

# 检查端口是否在排除列表中
is_port_excluded() {
    local port=$1
    for excluded in "${EXCLUDED_PORTS[@]}"; do
        if [ "$port" -eq "$excluded" ]; then
            return 0
        fi
    done
    return 1
}

# 生成随机端口
generate_random_port() {
    local min_port=10000
    local max_port=65535
    local max_attempts=100
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # 生成随机端口
        local port=$((RANDOM % (max_port - min_port + 1) + min_port))
        
        # 检查是否在排除列表中
        if is_port_excluded "$port"; then
            ((attempt++))
            continue
        fi
        
        # 检查端口是否被占用
        if ! is_port_used "$port"; then
            echo "$port"
            return 0
        fi
        ((attempt++))
    done
    
    # 如果找不到合适端口，返回默认端口
    print_warning "未找到合适的随机端口，使用默认端口 20000"
    echo "20000"
    return 0
}

# 生成随机 PSK（使用 openssl 或备用方案）
generate_psk() {
    # 优先使用 openssl
    if command -v openssl &> /dev/null; then
        openssl rand -base64 16 | tr -d '\n\r' | tr '+/' '-_' | cut -c1-24
    elif [ -r /dev/urandom ]; then
        # 备用方案：使用 /dev/urandom
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
    else
        # 最后的备用方案
        echo "$(date +%s)$$" | sha256sum | base64 | head -c 24
    fi
}

# 检测物理网络接口
detect_interface() {
    ip route | grep default | awk '{print $5}' | head -1 || ls /sys/class/net | grep -v lo | head -1
}

# 获取最新版本
get_latest_version() {
    print_info "正在从官方获取最新版本..."
    
    local official_version=$(curl -fsSL https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell \
        | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1)
    
    if [ -n "$official_version" ]; then
        echo "$official_version"
        return 0
    fi
    
    print_error "无法获取最新版本"
    return 1
}

# 下载 Snell 二进制文件（官方 -> GitHub备份）
download_snell_binary() {
    local version=$1
    local arch=$(get_arch)
    local filename="snell-server-v${version}-linux-${arch}.zip"
    local official_url="https://dl.nssurge.com/snell/${filename}"
    local backup_url="${GITHUB_BASE}/v${version}/${filename}"
    
    print_info "正在下载 Snell v${version} for ${arch}..."
    
    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir"
    
    # 先尝试官方下载
    if wget -q --show-progress "$official_url" 2>/dev/null; then
        print_info "从官方下载成功"
    # 官方失败则从 GitHub 备份下载
    elif wget -q --show-progress "$backup_url" 2>/dev/null; then
        print_info "从 GitHub 备份下载成功"
    else
        print_error "下载失败（官方和GitHub备份均不可用）"
        cd / && rm -rf "$tmp_dir"
        return 1
    fi
    
    # 解压并安装
    unzip -q "$filename"
    mv snell-server "${SNELL_INSTALL_DIR}/snell-server"
    chmod +x "${SNELL_INSTALL_DIR}/snell-server"
    
    cd / && rm -rf "$tmp_dir"
    print_info "二进制安装完成"
    return 0
}

# 创建系统用户
create_system_user() {
    if ! id -u ${SNELL_USER} &>/dev/null; then
        useradd -r -s /usr/sbin/nologin ${SNELL_USER}
        print_info "创建系统用户: ${SNELL_USER}"
    fi
}

# 创建二进制版本配置文件（完整支持所有选项）
create_binary_config() {
    local version=$1
    local port=$2
    local psk=$3
    local ipv6=$4
    local dns=$5
    local egress=$6
    local obfs=$7
    local host=$8
    
    mkdir -p "${SNELL_CONFIG_DIR}"
    
    # 基础配置
    cat > "${SNELL_CONFIG_FILE}" <<EOF
[snell-server]
listen = ::0:${port}
psk = ${psk}
ipv6 = ${ipv6}
EOF
    
    # DNS 配置 (v4.1.0+)
    if [ -n "$dns" ] && version_compare "$version" "4.1.0"; then
        echo "dns = ${dns}" >> "${SNELL_CONFIG_FILE}"
    fi
    
    # egress-interface 配置 (v5.0.0+)
    if [ -n "$egress" ] && version_compare "$version" "5.0.0"; then
        echo "egress-interface = ${egress}" >> "${SNELL_CONFIG_FILE}"
    fi
    
    # OBFS 混淆配置（需要配合 HOST 使用）
    if [ -n "$obfs" ] && [ -n "$host" ]; then
        echo "obfs = ${obfs}" >> "${SNELL_CONFIG_FILE}"
        echo "host = ${host}" >> "${SNELL_CONFIG_FILE}"
        print_info "已启用混淆模式: ${obfs}"
    elif [ -n "$obfs" ] && [ -z "$host" ]; then
        print_warning "OBFS 已设置但 HOST 未设置，混淆可能无法正常工作"
    fi
    
    chown -R ${SNELL_USER}:${SNELL_GROUP} "${SNELL_CONFIG_DIR}"
    chmod 640 "${SNELL_CONFIG_FILE}"
    print_info "配置文件已创建: ${SNELL_CONFIG_FILE}"
}

# 创建二进制版本 systemd 服务
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

# 二进制安装
install_binary() {
    local version=$1
    local port=$2
    local psk=$3
    local ipv6=$4
    local dns=$5
    local egress=$6
    local obfs=$7
    local host=$8
    
    print_title "二进制安装 Snell"
    
    # 安装依赖
    print_info "检查并安装依赖..."
    apt update
    apt install -y wget unzip curl iproute2 openssl
    
    # 创建用户
    create_system_user
    
    # 下载
    download_snell_binary "$version" || return 1
    
    # 创建配置
    create_binary_config "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
    
    # 创建服务
    create_binary_service
    
    # 启动
    systemctl enable snell
    systemctl start snell
    
    print_info "二进制安装完成"
}

# Docker 安装
install_docker() {
    local version=${1:-latest}
    local port=${2:-20000}
    local psk=${3:-$(generate_psk)}
    local ipv6=${4:-false}
    local dns=${5:-}
    local egress=${6:-}
    local obfs=${7:-}
    local host=${8:-}
    
    print_title "Docker 方式安装 Snell"
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        print_warning "Docker 未安装，正在安装..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable --now docker
    fi
    
    # 创建目录和 docker-compose.yml
    mkdir -p "${DOCKER_COMPOSE_DIR}"
    
    cat > "${DOCKER_COMPOSE_FILE}" <<EOF
version: '3.8'

services:
  snell:
    image: ${DOCKER_IMAGE_BASE}:${version}
    container_name: snell
    restart: unless-stopped
    ports:
      - "${port}:${port}"
    environment:
      - PSK=${psk}
      - PORT=${port}
      - IPV6=${ipv6}
EOF
    
    # 添加可选配置
    [ -n "$dns" ] && echo "      - DNS=${dns}" >> "${DOCKER_COMPOSE_FILE}"
    [ -n "$egress" ] && echo "      - EGRESS_INTERFACE=${egress}" >> "${DOCKER_COMPOSE_FILE}"
    [ -n "$obfs" ] && echo "      - OBFS=${obfs}" >> "${DOCKER_COMPOSE_FILE}"
    [ -n "$host" ] && echo "      - HOST=${host}" >> "${DOCKER_COMPOSE_FILE}"
    
    # 启动容器
    cd "${DOCKER_COMPOSE_DIR}"
    docker-compose up -d
    
    print_info "Docker 安装完成"
}

# 安装向导（统一入口）
install_wizard() {
    print_title "Snell 安装向导"
    
    # 选择安装方式
    echo "请选择安装方式："
    echo "1) 二进制安装 (systemd，性能最优)"
    echo "2) Docker 安装 (容器化，便于管理)"
    read -p "请选择 [1-2]: " install_method
    
    # 选择版本
    echo ""
    echo "选择版本："
    echo "1) 最新版本 (推荐)"
    echo "2) 指定版本"
    read -p "请选择 [1-2]: " ver_choice
    
    local version
    if [ "$ver_choice" = "1" ]; then
        version=$(get_latest_version) || return 1
        print_info "将安装最新版本: v${version}"
    else
        read -p "请输入版本号 (例如: 5.0.1): " version
        version=$(echo "$version" | sed 's/^v//')
        print_info "将安装版本: v${version}"
    fi
    
    # 端口配置
    echo ""
    print_title "端口配置"
    read -p "是否手动指定端口？[y/N]: " manual_port
    local port
    if [[ "$manual_port" =~ ^[Yy]$ ]]; then
        while true; do
            read -p "请输入端口号 (10000-65535): " port
            if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 10000 ] && [ "$port" -le 65535 ]; then
                if is_port_excluded "$port"; then
                    print_warning "端口 ${port} 是常用服务端口，建议更换"
                    read -p "是否继续使用？[y/N]: " continue_anyway
                    [[ "$continue_anyway" =~ ^[Yy]$ ]] && break
                elif is_port_used "$port"; then
                    print_warning "端口 ${port} 已被占用，请重新输入"
                else
                    break
                fi
            else
                print_error "端口号必须在 10000-65535 之间"
            fi
        done
    else
        port=$(generate_random_port)
        print_info "已自动生成随机端口: ${port}"
    fi
    
    # PSK 配置
    echo ""
    print_title "密码配置"
    read -p "是否手动设置密码？[y/N]: " manual_psk
    local psk
    if [[ "$manual_psk" =~ ^[Yy]$ ]]; then
        read -p "请输入密码 (建议20位以上): " psk
        if [ -z "$psk" ]; then
            psk=$(generate_psk)
            print_info "已自动生成密码: ${psk}"
        fi
    else
        psk=$(generate_psk)
        print_info "已自动生成密码: ${psk}"
    fi
    
    # IPv6 配置（默认 false）
    echo ""
    print_title "IPv6 配置"
    read -p "是否启用 IPv6？[y/N]: " ipv6_choice
    local ipv6="false"
    if [[ "$ipv6_choice" =~ ^[Yy]$ ]]; then
        ipv6="true"
        print_info "已启用 IPv6"
    else
        print_info "IPv6 保持关闭（默认）"
    fi
    
    # DNS 配置 (v4.1.0+)
    local dns=""
    if version_compare "$version" "4.1.0"; then
        echo ""
        print_title "DNS 配置 (可选，v4.1.0+ 支持)"
        echo "示例: 1.1.1.1, 8.8.8.8 或 1.1.1.1, 8.8.8.8, 2001:4860:4860::8888"
        read -p "请输入 DNS 服务器 (多个用逗号分隔，留空跳过): " dns
        [ -n "$dns" ] && print_info "已设置 DNS: ${dns}"
    fi
    
    # Egress Interface 配置 (v5.0.0+)
    local egress=""
    if version_compare "$version" "5.0.0"; then
        echo ""
        print_title "出口网卡配置 (可选，v5.0.0+ 支持)"
        local default_iface=$(detect_interface)
        echo -e "检测到的默认网卡: ${YELLOW}${default_iface}${NC}"
        echo "可用网卡列表:"
        ls /sys/class/net | grep -v lo | sed 's/^/  - /'
        read -p "请输入出口网卡名称 (留空自动检测或跳过): " egress
        if [ -z "$egress" ] && [ -n "$default_iface" ]; then
            read -p "是否使用检测到的网卡 ${default_iface}？[y/N]: " use_default
            [[ "$use_default" =~ ^[Yy]$ ]] && egress="$default_iface"
        fi
        [ -n "$egress" ] && print_info "已设置出口网卡: ${egress}"
    fi
    
    # OBFS 混淆配置
    echo ""
    print_title "混淆配置 (可选，v4.0.0+ 不建议设置)"
    read -p "是否启用混淆？[y/N]: " enable_obfs
    local obfs=""
    local host=""
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        echo "混淆模式:"
        echo "1) http"
        echo "2) tls"
        read -p "请选择 [1-2]: " obfs_choice
        case $obfs_choice in
            1) obfs="http" ;;
            2) obfs="tls" ;;
            *) obfs="http" ;;
        esac
        read -p "请输入混淆域名 (例如: www.example.com): " host
        if [ -z "$host" ]; then
            print_warning "未设置混淆域名，混淆可能无法正常工作"
        else
            print_info "已启用混淆: ${obfs} -> ${host}"
        fi
    fi
    
    # 显示配置摘要
    echo ""
    print_title "安装配置摘要"
    echo -e "安装方式: ${CYAN}$([ "$install_method" = "1" ] && echo "二进制" || echo "Docker")${NC}"
    echo -e "版本: ${CYAN}v${version}${NC}"
    echo -e "端口: ${CYAN}${port}${NC}"
    echo -e "密码: ${CYAN}${psk}${NC}"
    echo -e "IPv6: ${CYAN}${ipv6}${NC}"
    [ -n "$dns" ] && echo -e "DNS: ${CYAN}${dns}${NC}"
    [ -n "$egress" ] && echo -e "出口网卡: ${CYAN}${egress}${NC}"
    [ -n "$obfs" ] && echo -e "混淆模式: ${CYAN}${obfs}${NC}"
    [ -n "$host" ] && echo -e "混淆域名: ${CYAN}${host}${NC}"
    echo ""
    
    read -p "确认安装？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "取消安装"
        return 0
    fi
    
    # 执行安装
    if [ "$install_method" = "1" ]; then
        install_binary "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
    else
        install_docker "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
    fi
    
    # 显示结果
    echo ""
    print_info "安装完成！"
    
    # 获取外网 IP
    local public_ip=$(curl -s ifconfig.me)
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}连接信息:${NC}"
    echo -e "  服务器: ${public_ip}"
    echo -e "  端口: ${port}"
    echo -e "  密码: ${psk}"
    echo -e "  版本: v${version}"
    [ -n "$obfs" ] && echo -e "  混淆: ${obfs}"
    [ -n "$host" ] && echo -e "  域名: ${host}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    
    # Surge 配置示例
    echo ""
    echo -e "${BLUE}Surge 配置示例:${NC}"
    echo "────────────────────────────────────────"
    local surge_config="Snell = snell, ${public_ip}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true"
    [ -n "$obfs" ] && surge_config="${surge_config}, obfs=${obfs}"
    [ -n "$host" ] && surge_config="${surge_config}, obfs-host=${host}"
    echo "${surge_config}"
    echo "────────────────────────────────────────"
}

# 查看配置（自动识别安装方式）
view_config() {
    print_title "Snell 配置信息"
    
    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        echo -e "${BLUE}安装方式: 二进制${NC}"
        echo -e "${BLUE}配置文件: ${SNELL_CONFIG_FILE}${NC}"
        echo "────────────────────────────────────────"
        cat "${SNELL_CONFIG_FILE}"
        echo "────────────────────────────────────────"
        
        # 获取外网 IP
        local public_ip=$(curl -s ifconfig.me)
        if [ -n "$public_ip" ]; then
            local port=$(grep -oP 'listen = :::\K\d+' "${SNELL_CONFIG_FILE}" | head -1)
            local psk=$(grep 'psk = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
            local obfs=$(grep 'obfs = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
            local host=$(grep 'host = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
            
            echo ""
            echo -e "${BLUE}客户端连接信息:${NC}"
            echo "────────────────────────────────────────"
            echo -e "服务器: ${public_ip}"
            echo -e "端口: ${port}"
            echo -e "密码: ${psk}"
            [ -n "$obfs" ] && echo -e "混淆: ${obfs}"
            [ -n "$host" ] && echo -e "域名: ${host}"
            echo "────────────────────────────────────────"
            
            # Surge 配置示例
            echo ""
            echo -e "${BLUE}Surge 配置示例:${NC}"
            echo "────────────────────────────────────────"
            local surge_config="Snell = snell, ${public_ip}, ${port}, psk=${psk}, version=4, reuse=true, tfo=true"
            [ -n "$obfs" ] && surge_config="${surge_config}, obfs=${obfs}"
            [ -n "$host" ] && surge_config="${surge_config}, obfs-host=${host}"
            echo "${surge_config}"
            echo "────────────────────────────────────────"
        fi
        
    elif docker ps | grep -q snell 2>/dev/null; then
        echo -e "${BLUE}安装方式: Docker${NC}"
        echo -e "${BLUE}容器状态:${NC}"
        docker ps --filter name=snell --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo -e "${BLUE}配置文件内容:${NC}"
        echo "────────────────────────────────────────"
        docker exec snell cat /snell/snell.conf 2>/dev/null || echo "无法获取配置"
        echo "────────────────────────────────────────"
        
        # 获取连接信息
        local public_ip=$(curl -s ifconfig.me)
        if [ -n "$public_ip" ]; then
            local port=$(docker exec snell cat /snell/snell.conf 2>/dev/null | grep -oP 'listen = :::\K\d+' | head -1)
            local psk=$(docker exec snell cat /snell/snell.conf 2>/dev/null | grep 'psk = ' | cut -d'=' -f2 | sed 's/^ //')
            
            echo ""
            echo -e "${BLUE}客户端连接信息:${NC}"
            echo "────────────────────────────────────────"
            echo -e "服务器: ${public_ip}"
            echo -e "端口: ${port}"
            echo -e "密码: ${psk}"
            echo "────────────────────────────────────────"
        fi
    else
        print_error "未检测到 Snell 安装"
        return 1
    fi
}

# 查看状态
show_status() {
    print_title "Snell 运行状态"
    
    if systemctl is-active snell &>/dev/null; then
        echo -e "${BLUE}服务状态:${NC}"
        systemctl status snell --no-pager -l
        echo ""
        echo -e "${BLUE}进程信息:${NC}"
        ps aux | grep snell-server | grep -v grep
        echo ""
        echo -e "${BLUE}端口监听:${NC}"
        local port=$(grep -oP 'listen = :::\K\d+' "${SNELL_CONFIG_FILE}" 2>/dev/null | head -1)
        [ -n "$port" ] && ss -tlnp | grep "$port" || echo "未检测到监听"
        
    elif docker ps | grep -q snell 2>/dev/null; then
        echo -e "${BLUE}容器状态:${NC}"
        docker ps --filter name=snell
        echo ""
        echo -e "${BLUE}最近日志:${NC}"
        docker logs --tail 30 snell
    else
        print_error "Snell 未运行"
        return 1
    fi
}

# 服务管理
manage_service() {
    local action=$1
    local action_name=$2
    
    if systemctl list-unit-files | grep -q snell.service 2>/dev/null; then
        systemctl ${action} snell
        print_info "Snell ${action_name} 完成"
    elif docker ps -a | grep -q snell 2>/dev/null; then
        cd "${DOCKER_COMPOSE_DIR}" 2>/dev/null
        docker-compose ${action}
        print_info "Snell ${action_name} 完成"
    else
        print_error "未检测到 Snell 安装"
        return 1
    fi
}

# 更新 Snell
update_snell() {
    print_title "更新 Snell"
    
    if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
        local current_version=$(${SNELL_INSTALL_DIR}/snell-server --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
        echo -e "当前版本: ${current_version}"
        
        local latest_version=$(get_latest_version)
        echo -e "最新版本: ${latest_version}"
        
        if [ "$current_version" = "$latest_version" ]; then
            print_info "当前已是最新版本"
            return 0
        fi
        
        read -p "是否更新到 v${latest_version}？[y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 0
        fi
        
        # 备份配置
        local backup_config="${SNELL_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "${SNELL_CONFIG_FILE}" "${backup_config}"
        print_info "已备份配置: ${backup_config}"
        
        # 停止服务
        systemctl stop snell
        
        # 下载新版本
        if download_snell_binary "$latest_version"; then
            systemctl start snell
            print_info "更新完成！"
            view_config
        else
            print_error "更新失败，正在恢复..."
            cp "${backup_config}" "${SNELL_CONFIG_FILE}"
            systemctl start snell
            return 1
        fi
    elif docker ps | grep -q snell; then
        print_info "Docker 版本更新请执行: cd ${DOCKER_COMPOSE_DIR} && docker-compose pull && docker-compose up -d"
    else
        print_error "未检测到 Snell 安装"
    fi
}

# 修改配置
change_config() {
    print_title "修改 Snell 配置"
    
    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        print_info "正在编辑配置文件..."
        print_info "保存后请重启 Snell 服务"
        sleep 2
        ${EDITOR:-vi} "${SNELL_CONFIG_FILE}"
    elif [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        print_info "正在编辑 Docker Compose 文件..."
        print_info "保存后请重启容器: docker-compose restart"
        sleep 2
        ${EDITOR:-vi} "${DOCKER_COMPOSE_FILE}"
    else
        print_error "未找到配置文件"
        return 1
    fi
}

# 卸载
uninstall_snell() {
    print_title "彻底卸载 Snell"
    
    echo -e "${RED}警告：此操作将删除 Snell 及其所有数据！${NC}"
    read -p "确认卸载？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "取消卸载"
        return 0
    fi
    
    # 卸载二进制版本
    if systemctl list-unit-files | grep -q snell.service 2>/dev/null; then
        systemctl stop snell
        systemctl disable snell
        rm -f "${SNELL_SERVICE_FILE}"
        rm -f "${SNELL_INSTALL_DIR}/snell-server"
        
        read -p "是否删除配置文件？[y/N]: " del_config
        [[ "$del_config" =~ ^[Yy]$ ]] && rm -rf "${SNELL_CONFIG_DIR}"
        
        read -p "是否删除系统用户 ${SNELL_USER}？[y/N]: " del_user
        [[ "$del_user" =~ ^[Yy]$ ]] && userdel ${SNELL_USER} 2>/dev/null
        
        systemctl daemon-reload
        print_info "二进制版本已卸载"
    fi
    
    # 卸载 Docker 版本
    if docker ps -a | grep -q snell 2>/dev/null; then
        cd "${DOCKER_COMPOSE_DIR}" 2>/dev/null
        docker-compose down -v
        read -p "是否删除 Compose 文件？[y/N]: " del_compose
        [[ "$del_compose" =~ ^[Yy]$ ]] && rm -rf "${DOCKER_COMPOSE_DIR}"
        print_info "Docker 版本已卸载"
    fi
    
    print_info "Snell 已彻底卸载"
}

# 主菜单
show_menu() {
    clear
    print_title "Snell 一键管理脚本"
    
    echo "  ${GREEN}1${NC}) 安装 Snell"
    echo "  ${GREEN}2${NC}) 查看配置"
    echo "  ${GREEN}3${NC}) 查看状态"
    echo "  ${GREEN}4${NC}) 修改配置"
    echo "  ${GREEN}5${NC}) 停止 Snell"
    echo "  ${GREEN}6${NC}) 启动 Snell"
    echo "  ${GREEN}7${NC}) 重启 Snell"
    echo "  ${GREEN}8${NC}) 更新 Snell"
    echo "  ${GREEN}9${NC}) 彻底卸载"
    echo "  ${RED}0${NC}) 退出"
    echo ""
    echo "────────────────────────────────────────"
    
    # 显示当前状态
    if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
        local version=$(${SNELL_INSTALL_DIR}/snell-server --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
        if systemctl is-active snell &>/dev/null; then
            echo -e "状态: ${GREEN}● 二进制已安装 (v${version}) | 运行中${NC}"
        else
            echo -e "状态: ${YELLOW}● 二进制已安装 (v${version}) | 未运行${NC}"
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

# 主函数
main() {
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 权限运行！"
        exit 1
    fi
    
    while true; do
        show_menu
        read -p "请选择 [0-9]: " choice
        
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
            0) 
                print_info "感谢使用，再见！"
                exit 0
                ;;
            *) print_warning "无效选择，请重新输入" ;;
        esac
        
        echo ""
        read -p "按回车键继续..."
    done
}

# 运行
main
