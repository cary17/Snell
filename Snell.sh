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
DOCKER_IMAGE_GHCR="ghcr.io/cary17/snell"
DOCKER_IMAGE_DOCKERHUB="cary17/snell"
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
print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

# 获取大版本号
get_major_version() {
    local version=$1
    echo "$version" | cut -d'.' -f1
}

# 检查混淆是否支持
# tls 混淆仅在 v3 及以下版本支持
# http 混淆所有版本都支持
check_obfs_support() {
    local version=$1
    local obfs_type=$2
    local major_version=$(get_major_version "$version")
    
    # tls 混淆只在 version 3 及以下支持
    if [ "$obfs_type" = "tls" ] && [ "$major_version" -gt 3 ]; then
        return 1
    fi
    # http 混淆所有版本都支持
    if [ "$obfs_type" = "http" ]; then
        return 0
    fi
    return 0
}

# 获取支持的混淆类型
get_supported_obfs() {
    local version=$1
    local major_version=$(get_major_version "$version")
    
    if [ "$major_version" -le 3 ]; then
        echo "http/tls"
    else
        echo "http"
    fi
}

# 获取混淆说明
get_obfs_note() {
    local version=$1
    local major_version=$(get_major_version "$version")
    
    if [ "$major_version" -le 3 ]; then
        echo "tls 混淆仅在 v3 及以下版本支持"
    else
        echo "v4+ 版本仅支持 http 混淆，不支持 tls"
    fi
}

# 获取宿主机 IP 地址
get_host_ip() {
    # 优先获取 IPv4 地址
    local ipv4=$(curl -s -4 ifconfig.me 2>/dev/null)
    if [ -n "$ipv4" ]; then
        echo "$ipv4"
        return 0
    fi
    
    # 备用方案：从网卡获取
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

# 从官方获取最新版本
get_official_latest_version() {
    curl -fsSL https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell \
        | grep -oP 'snell-server-v\K[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1
}

# 从 GitHub 仓库获取最新版本
get_github_latest_version() {
    curl -fsSL "https://api.github.com/repos/cary17/Snell/contents/Version" \
        | grep -oP '"name": "v\K[0-9]+\.[0-9]+\.[0-9]+"' \
        | sed 's/"//g' \
        | sort -V | tail -n1
}

# 获取最新版本（智能比较官方和GitHub）
get_latest_version() {
    print_info "正在检查最新版本..."
    
    local official_version=$(get_official_latest_version)
    local github_version=$(get_github_latest_version)
    
    if [ -z "$official_version" ] && [ -z "$github_version" ]; then
        print_error "无法获取版本信息"
        return 1
    fi
    
    # 如果官方版本为空，使用 GitHub 版本
    if [ -z "$official_version" ]; then
        print_info "官方版本获取失败，使用 GitHub 备份版本: v${github_version}"
        echo "$github_version"
        return 0
    fi
    
    # 如果 GitHub 版本为空，使用官方版本
    if [ -z "$github_version" ]; then
        print_info "使用官方版本: v${official_version}"
        echo "$official_version"
        return 0
    fi
    
    # 比较版本，取较新的
    if [ "$(printf '%s\n' "$official_version" "$github_version" | sort -V | tail -n1)" = "$github_version" ] && [ "$official_version" != "$github_version" ]; then
        print_info "GitHub 备份版本较新: v${github_version} (官方: v${official_version})"
        echo "$github_version"
    else
        print_info "使用官方版本: v${official_version}"
        echo "$official_version"
    fi
    return 0
}

# 下载 Snell 二进制文件（智能选择下载源）
download_snell_binary() {
    local version=$1
    local arch=$(get_arch)
    local filename="snell-server-v${version}-linux-${arch}.zip"
    local official_url="https://dl.nssurge.com/snell/${filename}"
    local backup_url="${GITHUB_BASE}/v${version}/${filename}"
    
    # 获取官方和 GitHub 的版本信息
    local official_version=$(get_official_latest_version)
    local github_version=$(get_github_latest_version)
    
    print_info "正在下载 Snell v${version} for ${arch}..."
    
    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir"
    
    # 决定下载源
    local use_backup=false
    if [ "$version" = "$github_version" ] && [ "$version" != "$official_version" ]; then
        # 如果 GitHub 版本更新，使用 GitHub
        use_backup=true
        print_info "GitHub 版本较新，从备份下载"
    elif [ ! -z "$official_version" ] && [ "$version" = "$official_version" ]; then
        # 版本一致，优先官方
        use_backup=false
        print_info "从官方下载"
    else
        # 其他情况尝试官方，失败再用备份
        use_backup=false
    fi
    
    local success=false
    if [ "$use_backup" = false ]; then
        if wget -q --show-progress "$official_url" 2>/dev/null; then
            print_info "从官方下载成功"
            success=true
        elif wget -q --show-progress "$backup_url" 2>/dev/null; then
            print_info "官方下载失败，从 GitHub 备份下载成功"
            success=true
        fi
    else
        if wget -q --show-progress "$backup_url" 2>/dev/null; then
            print_info "从 GitHub 备份下载成功"
            success=true
        elif wget -q --show-progress "$official_url" 2>/dev/null; then
            print_info "GitHub 备份下载失败，从官方下载成功"
            success=true
        fi
    fi
    
    if [ "$success" = false ]; then
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
        # 检查混淆兼容性
        if ! check_obfs_support "$version" "$obfs"; then
            local major_version=$(get_major_version "$version")
            print_warning "Snell v${major_version} 不支持 ${obfs} 混淆"
            print_warning "v3 及以下版本支持 http/tls，v4+ 版本仅支持 http"
            read -p "是否继续安装（将跳过混淆配置）？[y/N]: " continue_install
            if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
                print_error "安装已取消"
                return 1
            fi
        else
            echo "obfs = ${obfs}" >> "${SNELL_CONFIG_FILE}"
            echo "host = ${host}" >> "${SNELL_CONFIG_FILE}"
            print_info "已启用混淆模式: ${obfs}"
        fi
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

# 生成 Surge 配置
generate_surge_config() {
    local host_ip=$1
    local port=$2
    local psk=$3
    local version=$4
    local obfs=$5
    local obfs_host=$6
    
    local major_version=$(get_major_version "$version")
    local config="Snell = snell, ${host_ip}, ${port}, psk=\"${psk}\", version=${major_version}, reuse=true"
    
    # 添加混淆配置（仅当存在且兼容时）
    if [ -n "$obfs" ] && [ -n "$obfs_host" ]; then
        if check_obfs_support "$version" "$obfs"; then
            config="${config}, obfs=${obfs}, obfs-host=${obfs_host}"
        fi
    fi
    
    echo "$config"
}

# 显示完整的配置信息
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
    local major_version=$(get_major_version "$version")
    
    clear
    print_title "Snell 安装成功！"
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  配置信息${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}安装信息:${NC}"
    echo -e "  安装方式: ${install_type}"
    echo -e "  Snell 版本: v${version} (协议版本: ${major_version})"
    [ -n "$docker_image" ] && echo -e "  Docker 镜像: ${docker_image}"
    echo ""
    echo -e "${CYAN}服务配置:${NC}"
    echo -e "  监听端口: ${port}"
    echo -e "  预共享密钥: ${psk}"
    echo -e "  IPv6 支持: ${ipv6}"
    [ -n "$dns" ] && echo -e "  DNS 服务器: ${dns}"
    [ -n "$egress" ] && echo -e "  出口网卡: ${egress}"
    
    # 显示混淆配置（仅当兼容时）
    if [ -n "$obfs" ] && [ -n "$host" ]; then
        if check_obfs_support "$version" "$obfs"; then
            echo -e "  混淆模式: ${obfs}"
            echo -e "  混淆域名: ${host}"
        else
            echo -e "  混淆模式: ${YELLOW}已忽略（v${major_version} 不支持 ${obfs}）${NC}"
        fi
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
    
    # 生成标准配置
    local surge_config=$(generate_surge_config "$host_ip" "$port" "$psk" "$version" "$obfs" "$host")
    echo -e "${CYAN}标准配置:${NC}"
    echo -e "${GREEN}${surge_config}${NC}"
    
    # 如果是 v3 版本且配置了 tls 混淆，额外显示说明
    if [ "$major_version" -le 3 ] && [ "$obfs" = "tls" ]; then
        echo ""
        echo -e "${CYAN}说明:${NC}"
        echo -e "  ${GREEN}• tls 混淆仅在 v3 及以下版本支持${NC}"
        echo -e "  ${GREEN}• 当前使用 tls 混淆，兼容性良好${NC}"
    fi
    
    # 如果是 v4+ 版本且尝试配置 tls，显示警告和建议
    if [ "$major_version" -ge 4 ] && [ "$obfs" = "tls" ]; then
        echo ""
        echo -e "${RED}⚠️  警告: v${major_version} 不支持 tls 混淆，已自动忽略${NC}"
        echo -e "${CYAN}建议配置（使用 http 混淆）:${NC}"
        local http_config=$(generate_surge_config "$host_ip" "$port" "$psk" "$version" "http" "$host")
        echo -e "${GREEN}${http_config}${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
    
    # 显示配置文件路径
    if [ "$install_type" = "二进制" ]; then
        echo -e "${CYAN}配置文件路径:${NC} ${SNELL_CONFIG_FILE}"
        echo -e "${CYAN}日志查看:${NC} journalctl -u snell -f"
    else
        echo -e "${CYAN}配置文件路径:${NC} ${DOCKER_COMPOSE_FILE}"
        echo -e "${CYAN}日志查看:${NC} docker logs -f snell"
    fi
    
    echo ""
    echo -e "${YELLOW}提示: 请保存好以上配置信息，特别是密码！${NC}"
}

# 测试 Docker 镜像仓库连接速度
test_docker_registry() {
    local registry=$1
    local start_time=$(date +%s%N)
    
    # 测试连接
    if curl -s -o /dev/null --connect-timeout 2 "https://${registry}/v2/" 2>/dev/null; then
        local end_time=$(date +%s%N)
        local elapsed=$((($end_time - $start_time) / 1000000))
        echo "$elapsed"
    else
        echo "999999"
    fi
}

# 选择最佳的 Docker 镜像仓库
select_best_docker_registry() {
    print_info "正在测试镜像仓库连接速度..."
    
    local ghcr_time=$(test_docker_registry "ghcr.io")
    local dockerhub_time=$(test_docker_registry "hub.docker.com")
    
    if [ "$ghcr_time" -lt "$dockerhub_time" ]; then
        print_info "选择 GHCR 镜像仓库 (连接时间: ${ghcr_time}ms)"
        echo "$DOCKER_IMAGE_GHCR"
    else
        print_info "选择 Docker Hub 镜像仓库 (连接时间: ${dockerhub_time}ms)"
        echo "$DOCKER_IMAGE_DOCKERHUB"
    fi
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
    create_binary_config "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" || return 1
    
    # 创建服务
    create_binary_service
    
    # 启动
    systemctl enable snell
    systemctl start snell
    
    print_info "二进制安装完成"
    
    # 显示完整配置信息
    show_full_config "二进制" "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
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
    local network_mode=${9:-host}
    local docker_user=${10:-}
    
    print_title "Docker 方式安装 Snell"
    
    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        print_warning "Docker 未安装，正在安装..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable --now docker
    fi
    
    # 检查 docker-compose
    if ! command -v docker-compose &> /dev/null; then
        print_warning "docker-compose 未安装，正在安装..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    # 选择最佳镜像仓库
    local docker_image=""
    if [ "$version" = "latest" ]; then
        docker_image=$(select_best_docker_registry)
        docker_image="${docker_image}:latest"
    else
        # 指定版本时，使用 GHCR（通常更全）
        docker_image="${DOCKER_IMAGE_GHCR}:${version}"
    fi
    
    # 检查混淆兼容性
    if [ -n "$obfs" ] && [ -n "$host" ] && ! check_obfs_support "$version" "$obfs"; then
        local major_version=$(get_major_version "$version")
        print_warning "Snell v${major_version} 不支持 ${obfs} 混淆"
        print_warning "v3 及以下版本支持 http/tls，v4+ 版本仅支持 http"
        read -p "是否继续安装（将跳过混淆配置）？[y/N]: " continue_install
        if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
            print_error "安装已取消"
            return 1
        fi
        obfs=""
        host=""
    fi
    
    # 创建目录和 docker-compose.yml
    mkdir -p "${DOCKER_COMPOSE_DIR}"
    
    # 开始生成 docker-compose.yml
    cat > "${DOCKER_COMPOSE_FILE}" <<EOF
version: '3.8'

services:
  snell:
    image: ${docker_image}
    container_name: snell
    restart: unless-stopped
EOF
    
    # 添加网络模式
    if [ "$network_mode" = "host" ]; then
        echo "    network_mode: host" >> "${DOCKER_COMPOSE_FILE}"
    else
        echo "    ports:" >> "${DOCKER_COMPOSE_FILE}"
        echo "      - \"${port}:${port}\"" >> "${DOCKER_COMPOSE_FILE}"
    fi
    
    # 添加用户配置（如果指定）
    if [ -n "$docker_user" ]; then
        echo "    user: \"${docker_user}\"" >> "${DOCKER_COMPOSE_FILE}"
    fi
    
    # 添加环境变量
    cat >> "${DOCKER_COMPOSE_FILE}" <<EOF
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
    
    # 如果是 latest 标签，添加拉取策略
    if [ "$version" = "latest" ]; then
        echo "    imagePullPolicy: always" >> "${DOCKER_COMPOSE_FILE}"
    fi
    
    # 启动容器
    cd "${DOCKER_COMPOSE_DIR}"
    
    # 如果是 latest 版本，先拉取最新镜像
    if [ "$version" = "latest" ]; then
        print_info "正在拉取最新镜像..."
        docker-compose pull
    fi
    
    docker-compose up -d
    
    print_info "Docker 安装完成"
    
    # 显示完整配置信息
    show_full_config "Docker" "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host" "$network_mode" "$docker_user" "$docker_image"
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
        if [ "$install_method" = "1" ]; then
            version=$(get_latest_version) || return 1
        else
            version="latest"
            print_info "将安装最新 Docker 镜像: ${version}"
        fi
    else
        if [ "$install_method" = "1" ]; then
            read -p "请输入版本号 (例如: 5.0.1): " version
            version=$(echo "$version" | sed 's/^v//')
        else
            read -p "请输入版本号 (例如: 5.0.1 或 latest): " version
            version=$(echo "$version" | sed 's/^v//')
        fi
        print_info "将安装版本: v${version}"
    fi
    
    # Docker 专属配置
    local network_mode="host"
    local docker_user=""
    if [ "$install_method" = "2" ]; then
        echo ""
        print_title "Docker 网络配置"
        echo "请选择网络模式："
        echo "1) host 模式 (默认，直接使用宿主机网络，性能最佳)"
        echo "2) bridge 模式 (需要映射端口)"
        read -p "请选择 [1-2]: " network_choice
        if [ "$network_choice" = "2" ]; then
            network_mode="bridge"
            print_info "将使用 bridge 模式，需要手动映射端口"
        else
            network_mode="host"
            print_info "将使用 host 模式"
        fi
        
        echo ""
        print_title "Docker 用户配置"
        read -p "是否指定运行用户？(留空使用默认) [y/N]: " set_user
        if [[ "$set_user" =~ ^[Yy]$ ]]; then
            read -p "请输入用户 ID (例如: 1000) 或用户名: " docker_user
            print_info "将使用用户: ${docker_user}"
        fi
    fi
    
    # 端口配置
    echo ""
    print_title "端口配置"
    # 如果是 bridge 模式，端口配置是必须的
    if [ "$install_method" = "2" ] && [ "$network_mode" = "bridge" ]; then
        print_info "bridge 模式下需要指定映射端口"
        manual_port="y"
    else
        read -p "是否手动指定端口？[y/N]: " manual_port
    fi
    
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
        print_success "已自动生成随机端口: ${port}"
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
            print_success "已自动生成密码: ${psk}"
        fi
    else
        psk=$(generate_psk)
        print_success "已自动生成密码: ${psk}"
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
    if [ "$install_method" = "1" ] && version_compare "$version" "4.1.0"; then
        echo ""
        print_title "DNS 配置 (可选，v4.1.0+ 支持)"
        echo "示例: 1.1.1.1, 8.8.8.8 或 1.1.1.1, 8.8.8.8, 2001:4860:4860::8888"
        read -p "请输入 DNS 服务器 (多个用逗号分隔，留空跳过): " dns
        [ -n "$dns" ] && print_info "已设置 DNS: ${dns}"
    elif [ "$install_method" = "2" ]; then
        # Docker 环境也支持 DNS
        echo ""
        print_title "DNS 配置 (可选)"
        echo "示例: 1.1.1.1, 8.8.8.8 或 1.1.1.1, 8.8.8.8, 2001:4860:4860::8888"
        read -p "请输入 DNS 服务器 (多个用逗号分隔，留空跳过): " dns
        [ -n "$dns" ] && print_info "已设置 DNS: ${dns}"
    fi
    
    # Egress Interface 配置 (v5.0.0+)
    local egress=""
    if [ "$install_method" = "1" ] && version_compare "$version" "5.0.0"; then
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
    elif [ "$install_method" = "2" ]; then
        # Docker 环境也支持 egress
        echo ""
        print_title "出口网卡配置 (可选)"
        local default_iface=$(detect_interface)
        echo -e "检测到的默认网卡: ${YELLOW}${default_iface}${NC}"
        read -p "请输入出口网卡名称 (留空跳过): " egress
        [ -n "$egress" ] && print_info "已设置出口网卡: ${egress}"
    fi
    
    # OBFS 混淆配置
    echo ""
    print_title "混淆配置 (可选)"
    local obfs=""
    local obfs_host=""
    
    if [ "$install_method" = "1" ]; then
        local supported_obfs=$(get_supported_obfs "$version")
        local major_version=$(get_major_version "$version")
        local obfs_note=$(get_obfs_note "$version")
        
        echo -e "${CYAN}当前版本 v${version} 支持的混淆类型: ${supported_obfs}${NC}"
        echo -e "${YELLOW}注意: ${obfs_note}${NC}"
    else
        echo -e "${CYAN}Docker 版本混淆配置${NC}"
        echo -e "${YELLOW}注意: v4+ 版本仅支持 http 混淆${NC}"
    fi
    
    read -p "是否启用混淆？[y/N]: " enable_obfs
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        if [ "$install_method" = "1" ] && [ "$(get_major_version "$version")" -le 3 ]; then
            echo "请选择混淆模式:"
            echo "1) http (所有版本支持)"
            echo "2) tls (仅 v3 及以下版本支持)"
            read -p "请选择 [1-2]: " obfs_choice
            case $obfs_choice in
                1) obfs="http" ;;
                2) obfs="tls" ;;
                *) obfs="http" ;;
            esac
        else
            obfs="http"
            print_info "将使用 http 混淆"
        fi
        
        read -p "请输入混淆域名 (例如: bing.com): " obfs_host
        if [ -z "$obfs_host" ]; then
            print_warning "未设置混淆域名，混淆可能无法正常工作"
        else
            print_info "已启用混淆: ${obfs} -> ${obfs_host}"
            
            # 显示配置示例
            echo ""
            echo -e "${CYAN}配置示例:${NC}"
            local major_ver=""
            if [ "$install_method" = "1" ]; then
                major_ver=$(get_major_version "$version")
            else
                major_ver="5"
            fi
            local example_config="Snell = snell, 服务器IP, ${port}, psk=\"${psk}\", version=${major_ver}, reuse=true, obfs=${obfs}, obfs-host=${obfs_host}"
            echo -e "${GREEN}${example_config}${NC}"
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
    if [ -n "$obfs" ] && [ -n "$obfs_host" ]; then
        if [ "$install_method" = "1" ]; then
            if check_obfs_support "$version" "$obfs"; then
                echo -e "混淆模式: ${CYAN}${obfs}${NC}"
                echo -e "混淆域名: ${CYAN}${obfs_host}${NC}"
            else
                echo -e "混淆模式: ${YELLOW}已忽略（v$(get_major_version "$version") 不支持 ${obfs}）${NC}"
            fi
        else
            echo -e "混淆模式: ${CYAN}${obfs}${NC}"
            echo -e "混淆域名: ${CYAN}${obfs_host}${NC}"
        fi
    fi
    
    if [ "$install_method" = "2" ]; then
        echo -e "Docker 网络模式: ${CYAN}${network_mode}${NC}"
        [ -n "$docker_user" ] && echo -e "Docker 运行用户: ${CYAN}${docker_user}${NC}"
    fi
    echo ""
    
    read -p "确认安装？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "取消安装"
        return 0
    fi
    
    # 执行安装
    if [ "$install_method" = "1" ]; then
        install_binary "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$obfs_host"
    else
        install_docker "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$obfs_host" "$network_mode" "$docker_user"
    fi
}

# 查看配置（自动识别安装方式）
view_config() {
    print_title "Snell 配置信息"
    
    if [ -f "${SNELL_CONFIG_FILE}" ]; then
        # 获取版本信息
        local version=$(${SNELL_INSTALL_DIR}/snell-server --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
        local port=$(grep -oP 'listen = :::\K\d+' "${SNELL_CONFIG_FILE}" | head -1)
        local psk=$(grep 'psk = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        local ipv6=$(grep 'ipv6 = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        local dns=$(grep 'dns = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2- | sed 's/^ //')
        local egress=$(grep 'egress-interface = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        local obfs=$(grep 'obfs = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        local host=$(grep 'host = ' "${SNELL_CONFIG_FILE}" | cut -d'=' -f2 | sed 's/^ //')
        
        show_full_config "二进制" "$version" "$port" "$psk" "$ipv6" "$dns" "$egress" "$obfs" "$host"
        
    elif docker ps | grep -q snell 2>/dev/null; then
        # 获取 Docker 容器配置
        local config=$(docker exec snell cat /snell/snell.conf 2>/dev/null)
        if [ -n "$config" ]; then
            local version=$(docker exec snell ./snell-server --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
            local port=$(echo "$config" | grep -oP 'listen = :::\K\d+' | head -1)
            local psk=$(echo "$config" | grep 'psk = ' | cut -d'=' -f2 | sed 's/^ //')
            local ipv6=$(echo "$config" | grep 'ipv6 = ' | cut -d'=' -f2 | sed 's/^ //')
            local dns=$(echo "$config" | grep 'dns = ' | cut -d'=' -f2- | sed 's/^ //')
            local egress=$(echo "$config" | grep 'egress-interface = ' | cut -d'=' -f2 | sed 's/^ //')
            local obfs=$(echo "$config" | grep 'obfs = ' | cut -d'=' -f2 | sed 's/^ //')
            local host=$(echo "$config" | grep 'host = ' | cut -d'=' -f2 | sed 's/^ //')
            
            # 获取 Docker 配置信息
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
        [ -n "$port" ] && ss -tlnp | grep "$port" || echo "未检测到监听"
        
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
            # 检查是否是 latest 版本，如果是则先拉取
            if grep -q "image:.*:latest" "${DOCKER_COMPOSE_FILE}" 2>/dev/null; then
                print_info "检测到 latest 标签，正在拉取最新镜像..."
                docker-compose pull
            fi
            docker-compose up -d
        elif [ "$action" = "stop" ]; then
            docker-compose stop
        elif [ "$action" = "restart" ]; then
            if grep -q "image:.*:latest" "${DOCKER_COMPOSE_FILE}" 2>/dev/null; then
                print_info "检测到 latest 标签，正在拉取最新镜像..."
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
        local current_version=$(${SNELL_INSTALL_DIR}/snell-server --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "未知")
        echo -e "当前版本: ${current_version}"
        
        local latest_version=$(get_latest_version)
        if [ -z "$latest_version" ]; then
            print_error "获取最新版本失败"
            return 1
        fi
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
        
        # 保存旧文件以备回滚
        local old_binary="${SNELL_INSTALL_DIR}/snell-server.old"
        if [ -f "${SNELL_INSTALL_DIR}/snell-server" ]; then
            mv "${SNELL_INSTALL_DIR}/snell-server" "${old_binary}"
        fi
        
        # 下载新版本
        if download_snell_binary "$latest_version"; then
            # 确保可执行权限
            chmod +x "${SNELL_INSTALL_DIR}/snell-server"
            
            # 启动服务
            systemctl start snell
            
            # 等待服务启动
            sleep 2
            
            if systemctl is-active snell &>/dev/null; then
                print_info "更新完成！"
                # 删除旧版本
                rm -f "${old_binary}"
                print_info "已清理旧版本文件"
                view_config
            else
                print_error "新版本启动失败，正在回滚..."
                systemctl stop snell
                mv "${old_binary}" "${SNELL_INSTALL_DIR}/snell-server"
                chmod +x "${SNELL_INSTALL_DIR}/snell-server"
                systemctl start snell
                print_error "已回滚到 v${current_version}"
                return 1
            fi
        else
            print_error "下载失败，正在恢复..."
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
        
        # 获取当前镜像
        local current_image=$(grep "image:" "${DOCKER_COMPOSE_FILE}" | awk '{print $2}')
        local current_version=$(echo "$current_image" | cut -d':' -f2)
        
        # 如果是 latest，拉取最新
        if [ "$current_version" = "latest" ]; then
            print_info "拉取最新镜像..."
            docker-compose pull
            docker-compose up -d
            
            # 清理旧镜像
            print_info "清理旧镜像..."
            docker image prune -f
        else
            # 检查是否有新版本
            local latest_version=$(get_latest_version)
            if [ -n "$latest_version" ] && [ "$current_version" != "$latest_version" ]; then
                read -p "发现新版本 v${latest_version}，是否更新？[y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    # 更新 docker-compose.yml 中的版本
                    sed -i "s/${current_version}/${latest_version}/g" "${DOCKER_COMPOSE_FILE}"
                    docker-compose pull
                    docker-compose up -d
                    
                    # 清理旧镜像
                    print_info "清理旧镜像..."
                    docker image prune -f
                    print_info "更新完成！"
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
        print_info "正在编辑配置文件..."
        print_info "保存后请重启 Snell 服务"
        sleep 2
        ${EDITOR:-vi} "${SNELL_CONFIG_FILE}"
        read -p "配置文件已修改，是否重启 Snell？[y/N]: " restart
        if [[ "$restart" =~ ^[Yy]$ ]]; then
            systemctl restart snell
            print_info "Snell 已重启"
            view_config
        fi
    elif [ -f "${DOCKER_COMPOSE_FILE}" ]; then
        print_info "正在编辑 Docker Compose 文件..."
        print_info "保存后请重启容器"
        sleep 2
        ${EDITOR:-vi} "${DOCKER_COMPOSE_FILE}"
        read -p "配置文件已修改，是否重启容器？[y/N]: " restart
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
        rm -f "${SNELL_INSTALL_DIR}/snell-server.old"
        
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
        
        # 清理镜像
        read -p "是否删除 Snell 镜像？[y/N]: " del_image
        if [[ "$del_image" =~ ^[Yy]$ ]]; then
            local snell_images=$(docker images | grep "snell" | awk '{print $3}')
            if [ -n "$snell_images" ]; then
                docker rmi $snell_images 2>/dev/null || true
                print_info "已删除镜像"
            fi
        fi
        
        read -p "是否删除 Compose 文件及目录？[y/N]: " del_compose
        if [[ "$del_compose" =~ ^[Yy]$ ]]; then
            rm -rf "${DOCKER_COMPOSE_DIR}"
            print_info "已删除 Compose 文件"
        fi
        
        # 清理未使用的镜像
        print_info "清理未使用的 Docker 资源..."
        docker image prune -f
        
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
        local major_version=$(get_major_version "$version")
        if systemctl is-active snell &>/dev/null; then
            echo -e "状态: ${GREEN}● 二进制已安装 (v${version}) | 协议版本: ${major_version} | 运行中${NC}"
        else
            echo -e "状态: ${YELLOW}● 二进制已安装 (v${version}) | 协议版本: ${major_version} | 未运行${NC}"
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
