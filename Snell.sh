#!/bin/bash

# Snell 一键管理脚本
# 支持二进制安装（官方+GitHub备份）/ Docker安装
# 完整支持所有配置项：PSK, PORT, IPV6, DNS, EGRESS_INTERFACE, OBFS, HOST
# 支持多种 Linux 发行版和架构

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

# Docker配置
DOCKER_IMAGE_GHCR="ghcr.io/cary17/snell"
DOCKER_IMAGE_DOCKERHUB="cary17/snell"
DOCKER_COMPOSE_DIR="/opt/snell"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_DIR}/docker-compose.yml"

# 临时文件目录
TMP_DIR="/tmp/snell_install"

# 需要排除的常用端口
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
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# 读取带默认值的输入
read_with_default() {
    local prompt=$1
    local default=$2
    local result
    
    if [ -n "$default" ]; then
        prompt="${prompt} [${default}]: "
    else
        prompt="${prompt}: "
    fi
    
    read -p "$prompt" result
    if [ -z "$result" ] && [ -n "$default" ]; then
        result="$default"
    fi
    echo "$result"
}

# 读取 yes/no 带默认值
read_yes_no() {
    local prompt=$1
    local default=$2
    local result
    
    if [ "$default" = "y" ] || [ "$default" = "Y" ]; then
        prompt="${prompt} [Y/n]: "
    else
        prompt="${prompt} [y/N]: "
    fi
    
    read -p "$prompt" result
    if [ -z "$result" ]; then
        result="$default"
    fi
    echo "$result"
}

# 格式化版本号（确保带 v 前缀）
format_version_with_v() {
    local version=$1
    # 去除可能的多余空格和换行
    version=$(echo "$version" | tr -d '[:space:]')
    if [[ ! "$version" =~ ^v ]]; then
        echo "v${version}"
    else
        echo "$version"
    fi
}

# 格式化版本号（移除 v 前缀）
format_version_without_v() {
    local version=$1
    version=$(echo "$version" | tr -d '[:space:]')
    echo "$version" | sed 's/^v//'
}

# 检查版本文件是否存在（官方源 + GitHub 备份）
check_version_exists() {
    local version=$1
    local arch=$(get_arch)
    
    # 确保版本号带 v 前缀
    local version_with_v=$(format_version_with_v "$version")
    local version_without_v=$(format_version_without_v "$version")
    
    # 尝试官方源
    local official_url="https://dl.nssurge.com/snell/snell-server-${version_with_v}-linux-${arch}.zip"
    if curl --head --silent --fail --output /dev/null "$official_url" 2>/dev/null; then
        return 0
    fi
    
    # 尝试 GitHub 备份源
    local github_url="${GITHUB_BASE}/v${version_without_v}/snell-server-${version_with_v}-linux-${arch}.zip"
    if curl --head --silent --fail --output /dev/null "$github_url" 2>/dev/null; then
        return 0
    fi
    
    return 1
}

# 获取版本下载链接
get_version_url() {
    local version=$1
    local arch=$(get_arch)
    
    local version_with_v=$(format_version_with_v "$version")
    local version_without_v=$(format_version_without_v "$version")
    
    # 优先返回官方源
    local official_url="https://dl.nssurge.com/snell/snell-server-${version_with_v}-linux-${arch}.zip"
    if curl --head --silent --fail --output /dev/null "$official_url" 2>/dev/null; then
        echo "$official_url"
        return 0
    fi
    
    # 返回 GitHub 备份源
    local github_url="${GITHUB_BASE}/v${version_without_v}/snell-server-${version_with_v}-linux-${arch}.zip"
    echo "$github_url"
    return 0
}

# 获取官方最新稳定版
get_official_latest_version() {
    local version=$(curl -fsSL https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell 2>/dev/null \
        | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1)
    
    if [ -z "$version" ]; then
        # 如果官方获取失败，从 GitHub 获取最新稳定版
        version=$(curl -fsSL "${GITHUB_API}" 2>/dev/null \
            | grep -oP '"name": "v\K[0-9]+\.[0-9]+\.[0-9]+"' \
            | sed 's/"//g' \
            | sort -V | tail -n1)
    fi
    
    echo "$version"
}

# 获取大版本号（只取数字部分）
get_major_version() {
    local version=$1
    local version_without_v=$(format_version_without_v "$version")
    # 只提取第一个点之前的数字，忽略字母
    echo "$version_without_v" | grep -oP '^[0-9]+' || echo "0"
}

# 处理大版本号输入（如 3、4、5）
resolve_major_version() {
    local input=$1
    
    case $input in
        3)
            # 获取 v3.x 的最新稳定版
            local v3_version=$(curl -fsSL "${GITHUB_API}" 2>/dev/null \
                | grep -oP '"name": "v\K3\.[0-9]+\.[0-9]+"' \
                | sed 's/"//g' \
                | sort -V | tail -n1)
            echo "$v3_version"
            ;;
        4)
            local v4_version=$(curl -fsSL "${GITHUB_API}" 2>/dev/null \
                | grep -oP '"name": "v\K4\.[0-9]+\.[0-9]+"' \
                | sed 's/"//g' \
                | sort -V | tail -n1)
            echo "$v4_version"
            ;;
        5)
            local v5_version=$(curl -fsSL "${GITHUB_API}" 2>/dev/null \
                | grep -oP '"name": "v\K5\.[0-9]+\.[0-9]+"' \
                | sed 's/"//g' \
                | sort -V | tail -n1)
            echo "$v5_version"
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查混淆是否支持（修复整数比较问题）
check_obfs_support() {
    local version=$1
    local obfs_type=$2
    local major_version=$(get_major_version "$version")
    
    # 如果无法提取大版本号，默认只支持 http
    if [ -z "$major_version" ] || [ "$major_version" -eq 0 ] 2>/dev/null; then
        [ "$obfs_type" = "http" ] && return 0
        return 1
    fi
    
    if [ "$obfs_type" = "tls" ] && [ "$major_version" -gt 3 ] 2>/dev/null; then
        return 1
    fi
    return 0
}

# 获取支持的混淆类型
get_supported_obfs() {
    local version=$1
    local major_version=$(get_major_version "$version")
    
    if [ -z "$major_version" ] || [ "$major_version" -le 3 ] 2>/dev/null; then
        echo "http/tls"
    else
        echo "http"
    fi
}

# 获取宿主机 IP 地址
get_host_ip() {
    local ipv4=$(curl -s -4 ifconfig.me 2>/dev/null)
    if [ -n "$ipv4" ]; then
        echo "$ipv4"
        return 0
    fi
    
    ipv4=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
    if [ -n "$ipv4" ]; then
        echo "$ipv4"
        return 0
    fi
    
    echo "无法获取IP"
    return 1
}

# 获取系统架构
get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            echo "amd64"
            ;;
        i386|i686)
            echo "i386"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        armv7l|armv8l|armv7|armv8)
            echo "armv7l"
            ;;
        *)
            print_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# 检测包管理器
detect_package_manager() {
    if command -v apt &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v pacman &> /dev/null; then
        echo "pacman"
    elif command -v zypper &> /dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

# 安装依赖
install_dependencies() {
    local pm=$(detect_package_manager)
    print_info "检测到包管理器: $pm"
    print_info "正在安装依赖..."
    
    case $pm in
        apt)
            apt update
            apt install -y wget unzip curl iproute2 openssl procps
            ;;
        yum)
            yum install -y wget unzip curl iproute openssl procps-ng
            ;;
        dnf)
            dnf install -y wget unzip curl iproute openssl procps-ng
            ;;
        pacman)
            pacman -S --noconfirm wget unzip curl iproute2 openssl procps-ng
            ;;
        zypper)
            zypper install -y wget unzip curl iproute2 openssl procps
            ;;
        *)
            print_warning "未知包管理器，请手动安装依赖"
            ;;
    esac
}

# 版本比较
version_compare() {
    local v1=$(format_version_without_v "$1")
    local v2=$(format_version_without_v "$2")
    [ "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n1)" = "$v2" ]
}

# 检查端口是否被占用
is_port_used() {
    local port=$1
    if command -v ss &> /dev/null; then
        if ss -tln | grep -q ":${port} "; then
            return 0
        fi
        if ss -uln | grep -q ":${port} "; then
            return 0
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tln | grep -q ":${port} "; then
            return 0
        fi
        if netstat -uln | grep -q ":${port} "; then
            return 0
        fi
    else
        if timeout 1 bash -c "echo >/dev/tcp/localhost/${port}" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# 检查端口是否在排除列表中
is_port_excluded() {
    local port=$1
    for excluded in "${EXCLUDED_PORTS[@]}"; do
        if [ "$port" -eq "$excluded" ] 2>/dev/null; then
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
        local port=$((RANDOM % (max_port - min_port + 1) + min_port))
        
        if is_port_excluded "$port"; then
            ((attempt++))
            continue
        fi
        
        if ! is_port_used "$port"; then
            echo "$port"
            return 0
        fi
        ((attempt++))
    done
    
    print_warning "未找到合适的随机端口，使用默认端口 20000"
    echo "20000"
    return 0
}

# 生成随机 PSK
generate_psk() {
    if command -v openssl &> /dev/null; then
        openssl rand -base64 16 | tr -d '\n\r' | tr '+/' '-_' | cut -c1-24
    elif [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
    else
        echo "$(date +%s)$$" | sha256sum | base64 | head -c 24
    fi
}

# 检测物理网络接口
detect_interface() {
    if command -v ip &> /dev/null; then
        ip route | grep default | awk '{print $5}' | head -1
    else
        route -n | grep '^0.0.0.0' | awk '{print $8}' | head -1
    fi
    ls /sys/class/net 2>/dev/null | grep -v lo | head -1
}

# 下载 Snell 二进制文件
download_snell_binary() {
    local version=$1
    local arch=$(get_arch)
    local version_with_v=$(format_version_with_v "$version")
    
    # 获取下载链接
    local download_url=$(get_version_url "$version")
    
    print_info "正在下载 Snell ${version_with_v} for ${arch}..."
    print_info "下载地址: ${download_url}"
    
    rm -rf "${TMP_DIR}"
    mkdir -p "${TMP_DIR}"
    cd "${TMP_DIR}"
    
    if wget -q --show-progress --timeout=30 --tries=3 "$download_url" -O snell.zip 2>/dev/null; then
        print_success "下载成功"
    else
        print_error "下载失败"
        cd / && rm -rf "${TMP_DIR}"
        return 1
    fi
    
    # 验证并解压
    if ! unzip -t snell.zip &>/dev/null; then
        print_error "下载的文件损坏"
        cd / && rm -rf "${TMP_DIR}"
        return 1
    fi
    
    print_info "正在解压..."
    unzip -q snell.zip
    
    if [ ! -f "snell-server" ]; then
        print_error "解压后未找到 snell-server 文件"
        cd / && rm -rf "${TMP_DIR}"
        return 1
    fi
    
    mv snell-server "${SNELL_INSTALL_DIR}/snell-server"
    chmod +x "${SNELL_INSTALL_DIR}/snell-server"
    
    cd /
    rm -rf "${TMP_DIR}"
    
    print_success "二进制安装完成"
    return 0
}

# 创建系统用户
create_system_user() {
    if ! id -u ${SNELL_USER} &>/dev/null; then
        useradd -r -s /usr/sbin/nologin ${SNELL_USER}
        print_info "创建系统用户: ${SNELL_USER}"
    fi
}

# 创建配置文件
create_binary_config() {
    local version=$1
    local version_without_v=$(format_version_without_v "$version")
    local port=$2
    local psk=$3
    local ipv6=$4
    local dns=$5
    local egress=$6
    local obfs=$7
    local host=$8
    
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
    
    if [ -n "$obfs" ] && [ -n "$host" ]; then
        if check_obfs_support "$version_without_v" "$obfs"; then
            echo "obfs = ${obfs}" >> "${SNELL_CONFIG_FILE}"
            echo "host = ${host}" >> "${SNELL_CONFIG_FILE}"
            print_info "已启用混淆模式: ${obfs}"
        else
            local major_version=$(get_major_version "$version_without_v")
            print_warning "Snell v${major_version} 不支持 ${obfs} 混淆，已跳过"
        fi
    fi
    
    chown -R ${SNELL_USER}:${SNELL_GROUP} "${SNELL_CONFIG_DIR}"
    chmod 640 "${SNELL_CONFIG_FILE}"
    print_info "配置文件已创建"
}

# 创建 systemd 服务
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

# 生成 Surge 配置
generate_surge_config() {
    local host_ip=$1
    local port=$2
    local psk=$3
    local version=$4
    local obfs=$5
    local obfs_host=$6
    
    local version_without_v=$(format_version_without_v "$version")
    local major_version=$(get_major_version "$version_without_v")
    local config="Snell = snell, ${host_ip}, ${port}, psk=\"${psk}\", version=${major_version}, reuse=true"
    
    if [ -n "$obfs" ] && [ -n "$obfs_host" ] && check_obfs_support "$version_without_v" "$obfs"; then
        config="${config}, obfs=${obfs}, obfs-host=${obfs_host}"
    fi
    
    echo "$config"
}

# 显示配置信息
show_full_config() {
    local install_type=$1
    local version=$2
    local port=$3
    local psk=$4
    local ipv6=$5
    local dns=$6
    local egress=$7
    local obfs=$8
    local host=$9
    local network_mode=${10:-}
    local docker_user=${11:-}
    local docker_image=${12:-}
    
    local host_ip=$(get_host_ip)
    local version_without_v=$(format_version_without_v "$version")
    local major_version=$(get_major_version "$version_without_v")
    local version_with_v=$(format_version_with_v "$version")
    
    clear
    print_title "Snell 安装成功！"
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  配置信息${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}安装信息:${NC}"
    echo -e "  安装方式: ${install_type}"
    echo -e "  Snell 版本: ${version_with_v} (协议版本: ${major_version})"
    [ -n "$docker_image" ] && echo -e "  Docker 镜像: ${docker_image}"
    echo ""
    echo -e "${CYAN}服务配置:${NC}"
    echo -e "  监听端口: ${port}"
    echo -e "  预共享密钥: ${psk}"
    echo -e "  IPv6 支持: ${ipv6}"
    [ -n "$dns" ] && echo -e "  DNS 服务器: ${dns}"
    [ -n "$egress" ] && echo -e "  出口网卡: ${egress}"
    
    if [ -n "$obfs" ] && [ -n "$host" ] && check_obfs_support "$version_without_v" "$obfs"; then
        echo -e "  混淆模式: ${obfs}"
        echo -e "  混淆域名: ${host}"
    fi
    
    if [ "$install_type" = "Docker" ]; then
        echo ""
        echo -e "${CYAN}Docker 配置:${NC}"
        echo -e "  网络模式: ${network_mode}"
        [ -n "$docker_user" ] && echo -e "  运行用户: ${docker_user}"
    fi
    
    echo ""
    echo -e "${CYAN}运行状态:${NC}"
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
    
    local surge_config=$(generate_surge_config "$host_ip" "$port" "$psk" "$version_without_v" "$obfs" "$host")
    echo -e "${CYAN}配置:${NC}"
    echo -e "${GREEN}${surge_config}${NC}"
    
    echo ""
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

# 测试 Docker 镜像仓库
test_docker_registry() {
    local registry=$1
    if curl -s -o /dev/null --connect-timeout 2 "https://${registry}/v2/" 2>/dev/null; then
        echo "0"
    else
        echo "1"
    fi
}

# 选择最佳 Docker 镜像
select_best_docker_registry() {
    print_info "正在测试镜像仓库连接..."
    
    local ghcr_ok=$(test_docker_registry "ghcr.io")
    local dockerhub_ok=$(test_docker_registry "hub.docker.com")
    
    if [ "$ghcr_ok" = "0" ]; then
        echo "$DOCKER_IMAGE_GHCR"
    else
        echo "$DOCKER_IMAGE_DOCKERHUB"
    fi
}

# 版本选择菜单
show_version_menu() {
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
    
    while true; do
        choice=$(read_with_default "请选择" "1")
        case $choice in
            1)
                if [ -z "$latest_version" ]; then
                    print_error "无法获取最新版本信息"
                    continue
                fi
                echo "$latest_version"
                return 0
                ;;
            2)
                while true; do
                    custom_version=$(read_with_default "请输入版本号" "")
                    custom_version=$(echo "$custom_version" | sed 's/^v//' | tr -d ' ')
                    
                    if [ -z "$custom_version" ]; then
                        print_error "版本号不能为空"
                        continue
                    fi
                    
                    # 检查是否为大版本号
                    if [[ "$custom_version" =~ ^[0-9]+$ ]]; then
                        local resolved=$(resolve_major_version "$custom_version")
                        if [ -n "$resolved" ]; then
                            echo "$resolved"
                            return 0
                        else
                            print_error "找不到版本 ${custom_version}.x 系列的最新稳定版"
                            continue
                        fi
                    fi
                    
                    # 检查版本是否存在
                    if check_version_exists "$custom_version"; then
                        echo "$custom_version"
                        return 0
                    else
                        print_error "版本 v${custom_version} 不存在于官方源或 GitHub 备份"
                        print_info "请检查版本号是否正确，支持测试版如 5.0.0b2"
                    fi
                done
                ;;
            *)
                print_warning "无效选择，请输入 1 或 2"
                ;;
        esac
    done
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

# Docker 安装
install_docker() {
    local version=$1
    local port=$2
    local psk=$3
    local ipv6=$4
    local dns=$5
    local egress=$6
    local obfs=$7
    local host=$8
    local network_mode=$9
    local docker_user=${10}
    
    print_title "Docker 方式安装 Snell"
    
    if ! command -v docker &> /dev/null; then
        print_warning "Docker 未安装，正在安装..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable --now docker
    fi
    
    if ! command -v docker-compose &> /dev/null; then
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
    
    if [ -n "$docker_user" ]; then
        echo "    user: \"${docker_user}\"" >> "${DOCKER_COMPOSE_FILE}"
    fi
    
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
    if [ "$version" != "latest" ]; then
        display_version=$(format_version_with_v "$version")
    fi
    
    show_full_config "Docker" "$display_version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" "$network_mode" "$docker_user" "$full_image"
}

# 安装向导
install_wizard() {
    print_title "Snell 安装向导"
    
    # 选择安装方式
    echo "请选择安装方式："
    echo "  1) 二进制安装 (systemd，性能最优) 【默认】"
    echo "  2) Docker 安装 (容器化，便于管理)"
    install_method=$(read_with_default "请选择" "1")
    
    # 选择版本（二进制和 Docker 都用同样的版本选择）
    version=$(show_version_menu)
    if [ -z "$version" ]; then
        print_error "版本选择失败"
        return 1
    fi
    local version_with_v=$(format_version_with_v "$version")
    print_success "将安装版本: ${version_with_v}"
    
    local network_mode="host"
    local docker_user=""
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
            if [ -n "$docker_user" ]; then
                print_info "将使用用户: ${docker_user}"
            fi
        fi
    fi
    
    # 端口配置
    echo ""
    print_title "端口配置"
    echo -e "${CYAN}说明: 端口范围 10000-65535，默认自动生成随机可用端口${NC}"
    
    manual_port=$(read_yes_no "是否手动指定端口" "n")
    
    local port
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
                        if [[ "$confirm_port" =~ ^[Yy]$ ]]; then
                            break
                        fi
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
    
    # PSK 配置
    echo ""
    print_title "密码配置"
    echo -e "${CYAN}说明: 密码用于客户端连接认证，默认随机生成 24 位强密码${NC}"
    
    manual_psk=$(read_yes_no "是否手动设置密码" "n")
    local psk
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
    
    # IPv6 配置
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
    
    # DNS 配置
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
    
    # 出口网卡配置
    local egress=""
    local default_iface=$(detect_interface)
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
    
    # OBFS 混淆配置
    echo ""
    print_title "混淆配置 (可选)"
    echo -e "${CYAN}说明:${NC}"
    echo "  • 混淆用于隐藏协议特征"
    echo "  • http 混淆所有版本支持"
    echo "  • tls 混淆仅 v3 及以下版本支持"
    echo -e "  • ${YELLOW}直接按回车键跳过此项配置${NC}"
    echo ""
    
    local obfs=""
    local obfs_host=""
    
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
    
    # 显示配置摘要
    echo ""
    print_title "安装配置摘要"
    echo -e "安装方式: ${CYAN}$([ "$install_method" = "1" ] && echo "二进制" || echo "Docker")${NC}"
    echo -e "版本: ${CYAN}${version_with_v}${NC}"
    echo -e "端口: ${CYAN}${port}${NC}"
    echo -e "密码: ${CYAN}${psk}${NC}"
    echo -e "IPv6: ${CYAN}${ipv6}${NC}"
    [ -n "$dns" ] && echo -e "DNS: ${CYAN}${dns}${NC}"
    [ -n "$egress" ] && echo -e "出口网卡: ${CYAN}${egress}${NC}"
    if [ -n "$obfs" ] && [ -n "$obfs_host" ]; then
        if [ "$install_method" = "1" ]; then
            local version_without_v=$(format_version_without_v "$version")
            if check_obfs_support "$version_without_v" "$obfs"; then
                echo -e "混淆: ${CYAN}${obfs} -> ${obfs_host}${NC}"
            else
                echo -e "混淆: ${YELLOW}已忽略（v$(get_major_version "$version_without_v") 不支持 ${obfs}）${NC}"
            fi
        else
            echo -e "混淆: ${CYAN}${obfs} -> ${obfs_host}${NC}"
        fi
    else
        echo -e "混淆: ${YELLOW}未启用${NC}"
    fi
    
    if [ "$install_method" = "2" ]; then
        echo -e "网络模式: ${CYAN}${network_mode}${NC}"
        [ -n "$docker_user" ] && echo -e "运行用户: ${CYAN}${docker_user}${NC}"
    fi
    echo ""
    
    confirm=$(read_yes_no "确认安装" "y")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "取消安装"
        return 0
    fi
    
    if [ "$install_method" = "1" ]; then
        install_binary "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$obfs_host"
    else
        install_docker "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$obfs_host" "$network_mode" "$docker_user"
    fi
}

# 查看配置
view_config() {
    print_title "Snell 配置信息"
    
    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        local version=$(${SNELL_INSTALL_DIR}/snell-server --version 2>&1 | grep -oP 'v\K[0-9a-z.]+' || echo "未知")
        local port=$(grep -oP 'listen = :::\K\d+' "${SNELL_CONFIG_FILE}" | head -1)
        local psk=$(grep 'psk = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        local ipv6=$(grep 'ipv6 = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        local dns=$(grep 'dns = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2- | sed 's/^ //')
        local egress=$(grep 'egress-interface = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        local obfs=$(grep 'obfs = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        local host=$(grep 'host = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        
        show_full_config "二进制" "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
        
    elif docker ps | grep -q snell 2>/dev/null; then
        local config=$(docker exec snell cat /snell/snell.conf 2>/dev/null)
        if [ -n "$config" ]; then
            local version=$(docker exec snell ./snell-server --version 2>&1 | grep -oP 'v\K[0-9a-z.]+' || echo "未知")
            local port=$(echo "$config" | grep -oP 'listen = :::\K\d+' | head -1)
            local psk=$(echo "$config" | grep 'psk = ' | cut -d'=' -f2 | sed 's/^ //')
            local ipv6=$(echo "$config" | grep 'ipv6 = ' | cut -d'=' -f2 | sed 's/^ //')
            local dns=$(echo "$config" | grep 'dns = ' | cut -d'=' -f2- | sed 's/^ //')
            local egress=$(echo "$config" | grep 'egress-interface = ' | cut -d'=' -f2 | sed 's/^ //')
            local obfs=$(echo "$config" | grep 'obfs = ' | cut -d'=' -f2 | sed 's/^ //')
            local host=$(echo "$config" | grep 'host = ' | cut -d'=' -f2 | sed 's/^ //')
            
            local network_mode=$(grep "network_mode:" "${DOCKER_COMPOSE_FILE}" 2>/dev/null | awk '{print $2}' || echo "host")
            local docker_user=$(grep "user:" "${DOCKER_COMPOSE_FILE}" 2>/dev/null | awk '{print $2}' | sed 's/"//g')
            local docker_image=$(grep "image:" "${DOCKER_COMPOSE_FILE}" 2>/dev/null | awk '{print $2}')
            
            show_full_config "Docker" "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" "$network_mode" "$docker_user" "$docker_image"
        else
            print_error "无法获取容器配置"
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
        [ -n "$port" ] && ss -tlnp 2>/dev/null | grep "$port" || netstat -tlnp 2>/dev/null | grep "$port" || echo "未检测到监听"
        
    elif docker ps | grep -q snell 2>/dev/null; then
        echo -e "${BLUE}容器状态:${NC}"
        docker ps --filter name=snell
        echo ""
        echo -e "${BLUE}容器详情:${NC}"
        docker inspect snell | grep -E "NetworkMode|User" | head -2
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
        if [ "$action" = "start" ] || [ "$action" = "restart" ]; then
            sleep 2
            view_config
        fi
    elif docker ps -a | grep -q snell 2>/dev/null; then
        cd "${DOCKER_COMPOSE_DIR}" 2>/dev/null
        if [ "$action" = "start" ]; then
            if grep -q "image:.*:latest" "${DOCKER_COMPOSE_FILE}" 2>/dev/null; then
                print_info "拉取最新镜像..."
                docker-compose pull
            fi
            docker-compose up -d
        elif [ "$action" = "stop" ]; then
            docker-compose stop
        elif [ "$action" = "restart" ]; then
            if grep -q "image:.*:latest" "${DOCKER_COMPOSE_FILE}" 2>/dev/null; then
                print_info "拉取最新镜像..."
                docker-compose pull
            fi
            docker-compose restart
        fi
        print_info "Snell ${action_name} 完成"
        if [ "$action" = "start" ] || [ "$action" = "restart" ]; then
            sleep 2
            view_config
        fi
    else
        print_error "未检测到 Snell 安装"
        return 1
    fi
}

# 更新 Snell
update_snell() {
    print_title "更新 Snell"
    
    if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
        local current_version=$(${SNELL_INSTALL_DIR}/snell-server --version 2>&1 | grep -oP 'v\K[0-9a-z.]+' || echo "未知")
        echo -e "当前版本: ${current_version}"
        
        local latest_version=$(get_official_latest_version)
        if [ -z "$latest_version" ]; then
            print_error "获取最新版本失败"
            return 1
        fi
        echo -e "最新稳定版: ${latest_version}"
        
        if [ "$current_version" = "$latest_version" ]; then
            print_info "当前已是最新稳定版"
            return 0
        fi
        
        local latest_with_v=$(format_version_with_v "$latest_version")
        confirm=$(read_yes_no "是否更新到 ${latest_with_v}" "n")
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            return 0
        fi
        
        local backup_config="${SNELL_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "${SNELL_CONFIG_FILE}" "${backup_config}"
        print_info "已备份配置: ${backup_config}"
        
        systemctl stop snell
        
        local old_binary="${SNELL_INSTALL_DIR}/snell-server.old"
        if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
            mv "${SNELL_INSTALL_DIR}/snell-server" "${old_binary}"
        fi
        
        if download_snell_binary "$latest_version"; then
            chmod +x "${SNELL_INSTALL_DIR}/snell-server"
            systemctl start snell
            sleep 2
            
            if systemctl is-active snell &>/dev/null; then
                print_success "更新完成！"
                rm -f "${old_binary}"
                print_info "已清理旧版本"
                view_config
            else
                print_error "新版本启动失败，回滚中..."
                systemctl stop snell
                mv "${old_binary}" "${SNELL_INSTALL_DIR}/snell-server"
                chmod +x "${SNELL_INSTALL_DIR}/snell-server"
                systemctl start snell
                print_error "已回滚到 v${current_version}"
                return 1
            fi
        else
            print_error "下载失败，恢复中..."
            if [ -f "${old_binary}" ]; then
                mv "${old_binary}" "${SNELL_INSTALL_DIR}/snell-server"
                chmod +x "${SNELL_INSTALL_DIR}/snell-server"
            fi
            systemctl start snell
            return 1
        fi
        
    elif docker ps | grep -q snell; then
        print_info "正在更新 Docker 镜像..."
        cd "${DOCKER_COMPOSE_DIR}"
        
        local current_image=$(grep "image:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}')
        local current_tag=$(echo "$current_image" | cut -d':' -f2)
        
        if [ "$current_tag" = "latest" ]; then
            docker-compose pull
            docker-compose up -d
            docker image prune -f
            print_success "更新完成！"
            view_config
        else
            local latest_version=$(get_official_latest_version)
            local latest_version_with_v=$(format_version_with_v "$latest_version")
            if [ -n "$latest_version" ] && [ "$current_tag" != "$latest_version_with_v" ]; then
                confirm=$(read_yes_no "发现新版本 ${latest_version_with_v}，是否更新" "n")
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    local new_image=$(echo "$current_image" | sed "s/${current_tag}/${latest_version_with_v}/")
                    sed -i "s|image: ${current_image}|image: ${new_image}|g" "${DOCKER_COMPOSE_FILE}"
                    docker-compose pull
                    docker-compose up -d
                    docker image prune -f
                    print_success "更新完成！"
                    view_config
                fi
            else
                print_info "当前已是最新版本"
            fi
        fi
    else
        print_error "未检测到 Snell 安装"
    fi
}

# 修改配置
change_config() {
    print_title "修改 Snell 配置"
    
    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        print_info "编辑配置文件: ${SNELL_CONFIG_FILE}"
        sleep 1
        ${EDITOR:-vi} "${SNELL_CONFIG_FILE}"
        restart=$(read_yes_no "是否重启 Snell" "n")
        if [[ "$restart" =~ ^[Yy]$ ]]; then
            systemctl restart snell
            print_info "Snell 已重启"
            view_config
        fi
    elif [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        print_info "编辑配置文件: ${DOCKER_COMPOSE_FILE}"
        sleep 1
        ${EDITOR:-vi} "${DOCKER_COMPOSE_FILE}"
        restart=$(read_yes_no "是否重启容器" "n")
        if [[ "$restart" =~ ^[Yy]$ ]]; then
            cd "${DOCKER_COMPOSE_DIR}"
            docker-compose restart
            print_info "容器已重启"
            view_config
        fi
    else
        print_error "未找到配置文件"
        return 1
    fi
}

# 彻底卸载
uninstall_snell() {
    print_title "彻底卸载 Snell"
    
    echo -e "${RED}警告：此操作将删除 Snell 及其所有相关文件！${NC}"
    echo -e "${RED}包括：二进制文件、配置文件、systemd服务、Docker容器、镜像、Compose文件等${NC}"
    confirm=$(read_yes_no "确认卸载" "n")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "取消卸载"
        return 0
    fi
    
    if systemctl list-unit-files | grep -q snell.service 2>/dev/null; then
        print_info "停止并禁用 Snell 服务..."
        systemctl stop snell 2>/dev/null
        systemctl disable snell 2>/dev/null
        
        print_info "删除 systemd 服务文件..."
        rm -f "${SNELL_SERVICE_FILE}"
        
        print_info "删除二进制文件..."
        rm -f "${SNELL_INSTALL_DIR}/snell-server"
        rm -f "${SNELL_INSTALL_DIR}/snell-server.old"
        
        print_info "删除配置文件..."
        rm -rf "${SNELL_CONFIG_DIR}"
        
        print_info "删除系统用户..."
        userdel ${SNELL_USER} 2>/dev/null
        
        systemctl daemon-reload
        
        print_success "二进制版本已完全卸载"
    fi
    
    if docker ps -a | grep -q snell 2>/dev/null; then
        print_info "停止并删除 Snell 容器..."
        cd "${DOCKER_COMPOSE_DIR}" 2>/dev/null
        docker-compose down -v 2>/dev/null
        
        print_info "删除 Docker 镜像..."
        local snell_images=$(docker images | grep "snell" | awk '{print $3}')
        if [ -n "$snell_images" ]; then
            docker rmi $snell_images 2>/dev/null || true
            print_success "已删除 Docker 镜像"
        fi
        
        print_info "删除 Compose 文件及目录..."
        rm -rf "${DOCKER_COMPOSE_DIR}"
        
        print_info "清理未使用的 Docker 资源..."
        docker image prune -f 2>/dev/null
        
        print_success "Docker 版本已完全卸载"
    fi
    
    rm -rf "${TMP_DIR}"
    
    print_success "Snell 已彻底卸载"
    echo ""
    echo -e "${YELLOW}所有相关文件已清理完成！${NC}"
}

# 主菜单
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
    
    if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
        local version=$(${SNELL_INSTALL_DIR}/snell-server --version 2>&1 | grep -oP 'v\K[0-9a-z.]+' || echo "未知")
        local major_version=$(get_major_version "$version")
        if systemctl is-active snell &>/dev/null; then
            echo -e "状态: ${GREEN}● 二进制已安装 (v${version}) | 协议: v${major_version} | 运行中${NC}"
        else
            echo -e "状态: ${YELLOW}● 二进制已安装 (v${version}) | 协议: v${major_version} | 未运行${NC}"
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
            0) 
                print_info "感谢使用，再见！"
                exit 0
                ;;
            *) 
                if [ -n "$choice" ]; then
                    print_warning "无效选择，请重新输入"
                fi
                ;;
        esac
        
        if [ "$choice" != "0" ] && [ -n "$choice" ]; then
            echo ""
            read -p "按回车键继续..."
        fi
    done
}

# 运行
main
