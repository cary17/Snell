#!/bin/sh

trap 'kill -TERM $SNELL_PID 2>/dev/null; wait $SNELL_PID 2>/dev/null' TERM INT

# ============================================================
# 工具函数
# ============================================================

# 生成随机 PSK（16-255 字节，包含大小写字母、数字和特殊字符）
random_psk() {
    # 先随机确定长度（16-255）
    if [ -r /dev/urandom ]; then
        RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
        LENGTH=$((16 + (${RANDOM_BYTE:-0} % 240)))
    else
        LENGTH=32
    fi
    
    # 使用所有可打印字符生成强密码
    CHARSET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+[]{}|;:,.<>?'
    CHARSET_LEN=90
    
    PSK=""
    for i in $(seq 1 $LENGTH); do
        if [ -r /dev/urandom ]; then
            RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
            INDEX=$((RANDOM_BYTE % CHARSET_LEN))
        else
            INDEX=$(($$ % CHARSET_LEN))
        fi
        PSK="${PSK}$(echo "$CHARSET" | cut -c$((INDEX+1)))"
    done
    echo "$PSK"
}

# 验证 PSK 长度是否有效（16-255 字节）
validate_psk() {
    local psk="$1"
    local len=$(echo -n "$psk" | wc -c)
    if [ "$len" -lt 16 ] || [ "$len" -gt 255 ]; then
        echo "Warning: PSK length is $len bytes. Must be between 16 and 255 bytes." >&2
        return 1
    fi
    return 0
}

random_port() {
    echo $((10000 + $(od -An -N2 -i /dev/urandom 2>/dev/null || echo $$) % 55536))
}

# ============================================================
# 日志级别处理
# ============================================================

# 验证日志级别是否有效
validate_loglevel() {
    local level="$1"
    case "$level" in
        debug|info|warning|error|fatal)
            return 0
            ;;
        *)
            echo "Warning: Invalid log level '$level'. Valid levels: debug, info, warning, error, fatal" >&2
            return 1
            ;;
    esac
}

# ============================================================
# 网络检测
# ============================================================

test_connectivity() {
    nc -z -w 2 "$1" "${2:-80}" 2>/dev/null
}

test_google() {
    test_connectivity "google.com" 80
}

test_domestic() {
    test_connectivity "baidu.com" 80 || test_connectivity "aliyun.com" 80
}

get_network_type() {
    test_google && echo "international" && return
    test_domestic && echo "domestic" && return
    echo "none"
}

test_ipv4() {
    for ip in 8.8.8.8 1.1.1.1 119.29.29.29 223.5.5.5; do
        test_connectivity "$ip" 53 && return 0
    done
    return 1
}

test_ipv6() {
    for ip in 2001:4860:4860::8888 2606:4700:4700::1111 2402:4e00:: 2400:3200::1; do
        test_connectivity "$ip" 53 && return 0
    done
    return 1
}

# ============================================================
# DNS 配置
# ============================================================

get_dns_value() {
    local network_type=$(get_network_type)
    local ipv4_ok=false; test_ipv4 && ipv4_ok=true
    local ipv6_ok=false; test_ipv6 && ipv6_ok=true
    
    case "$network_type" in
        none)
            echo "8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
            ;;
        domestic)
            if $ipv4_ok && $ipv6_ok; then
                echo "119.29.29.29, 223.5.5.5, 2402:4e00::, 2400:3200::1"
            elif $ipv4_ok; then
                echo "119.29.29.29, 223.5.5.5"
            else
                echo "2402:4e00::, 2400:3200::1"
            fi
            ;;
        international)
            if $ipv4_ok && $ipv6_ok; then
                echo "8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
            elif $ipv4_ok; then
                echo "8.8.8.8, 1.1.1.1"
            else
                echo "2001:4860:4860::8888, 2606:4700:4700::1111"
            fi
            ;;
    esac
}

get_dns_ip_preference() {
    local network_type=$(get_network_type)
    local ipv4_ok=false; test_ipv4 && ipv4_ok=true
    local ipv6_ok=false; test_ipv6 && ipv6_ok=true
    
    case "$network_type" in
        none) echo "prefer-ipv4" ;;
        *)
            if $ipv4_ok && $ipv6_ok; then
                echo "prefer-ipv4"
            elif $ipv6_ok; then
                echo "prefer-ipv6"
            else
                echo "prefer-ipv4"
            fi
            ;;
    esac
}

# ============================================================
# 版本读取
# ============================================================

get_snell_version() {
    cat /snell/snell-version 2>/dev/null || echo "unknown"
}

get_major_version() {
    cat /snell/snell-major-version 2>/dev/null || echo "0"
}

# ============================================================
# 版本比较函数 - 检查是否支持 mode 配置
# Snell v6.0.0b3 及之后的所有版本都支持 mode
# ============================================================

supports_mode() {
    local version=$(get_snell_version)
    version=${version#v}
    
    local main=$(echo "$version" | cut -d. -f1)
    
    # 主版本 > 6
    if [ "$main" -gt 6 ] 2>/dev/null; then
        return 0
    fi
    
    # 主版本 = 6
    if [ "$main" -eq 6 ] 2>/dev/null; then
        # 排除 v6.0.0b2 及更早
        if echo "$version" | grep -qE '^6\.0\.0b[0-2]$'; then
            return 1
        fi
        # 其他所有 v6.x 都支持
        return 0
    fi
    
    return 1
}

# 检查是否是 v6 或更高版本（废弃了 ipv6 配置项）
is_v6_or_higher() {
    local major=$(get_major_version)
    if [ "$major" -ge 6 ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# ============================================================
# LISTEN 解析
# ============================================================

parse_listen() {
    local major="$1" input="$2"
    
    if [ -z "$input" ]; then
        PORT=$(random_port)
        if [ "$major" -ge 6 ] 2>/dev/null; then
            printf "0.0.0.0:$PORT, [::]:$PORT"
        else
            printf ":::$PORT"
        fi
        return
    fi
    
    # 已经是完整地址格式
    if echo "$input" | grep -q ':' && ! echo "$input" | grep -q '^[0-9]\+$'; then
        printf "%s" "$input"
        return
    fi
    
    # 仅端口号
    if [ "$major" -ge 6 ] 2>/dev/null; then
        printf "0.0.0.0:${input}, [::]:${input}"
    else
        printf ":::${input}"
    fi
}

# ============================================================
# 配置管理
# ============================================================

CONFIG_FILE="/snell/snell.conf"

set_config() {
    local key="$1" new_value="$2"
    
    if [ -z "$new_value" ]; then
        sed -i "/^${key} = /d" "$CONFIG_FILE" 2>/dev/null
        return
    fi
    
    if grep -q "^${key} = " "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^${key} = .*/${key} = ${new_value}/" "$CONFIG_FILE"
    else
        sed -i "/^psk = /a ${key} = ${new_value}" "$CONFIG_FILE"
    fi
}

# 处理所有 SNELL_ 前缀的环境变量作为配置项
process_snell_env_vars() {
    # 遍历所有以 SNELL_ 开头的环境变量
    for var in $(env | grep '^SNELL_' | cut -d'=' -f1); do
        # 提取配置键名（去掉 SNELL_ 前缀，转换为小写）
        key=$(echo "$var" | sed 's/^SNELL_//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        # 获取值
        eval "value=\$$var"
        if [ -n "$value" ]; then
            set_config "$key" "$value"
        fi
    done
}

# ============================================================
# 主逻辑
# ============================================================

SNELL_VERSION=$(get_snell_version)
MAJOR_VERSION=$(get_major_version)
MINOR_VERSION=$(echo "${SNELL_VERSION#v}" | cut -d. -f2)

echo "Snell version: $SNELL_VERSION (major: $MAJOR_VERSION)"

# 计算期望配置
# v6+ 使用新的 DNS 配置方式，废弃 ipv6 配置项
if is_v6_or_higher; then
    EXPECTED_DNS_IP_PREFERENCE=${DNS_IP_PREFERENCE:-$(get_dns_ip_preference)}
    WRITE_IPV6=false  # v6+ 不再写入 ipv6 配置
else
    EXPECTED_DNS_IP_PREFERENCE=${DNS_IP_PREFERENCE:-$(get_dns_ip_preference)}
    IPV6_VAL=${IPV6:-false}
    WRITE_IPV6=true
fi

# PSK 处理（全版本通用）
if [ -n "$PSK" ]; then
    EXPECTED_PSK="$PSK"
    validate_psk "$EXPECTED_PSK" || true
else
    EXPECTED_PSK=$(random_psk)
    echo "Generated random PSK (length: $(echo -n "$EXPECTED_PSK" | wc -c) bytes)"
fi

EXPECTED_LISTEN=$(parse_listen "$MAJOR_VERSION" "${LISTEN:-}")

# DNS 配置（v4.1.0+ 才支持）
if [ "$MAJOR_VERSION" -ge 4 ] && { [ "$MAJOR_VERSION" -ne 4 ] || [ "$MINOR_VERSION" -ge 1 ]; }; then
    EXPECTED_DNS=${DNS:-$(get_dns_value)}
else
    EXPECTED_DNS=""
fi

# 日志级别配置（全版本通用，通过命令行参数传递）
LOGLEVEL_VAL=""
if [ -n "$LOGLEVEL" ]; then
    if validate_loglevel "$LOGLEVEL"; then
        LOGLEVEL_VAL="$LOGLEVEL"
    fi
    # 如果无效，不设置日志级别，使用默认值
fi

EGRESS_INTERFACE_VAL=${EGRESS_INTERFACE:-""}
OBFS_VAL=${OBFS:-""}
HOST_VAL=${HOST:-""}

# Mode 配置（v6.0.0b3+ 才支持）
if supports_mode; then
    MODE_VAL=${MODE:-default}
    # 验证 mode 值是否合法
    case "$MODE_VAL" in
        default|unshaped|unsafe-raw)
            ;;
        *) 
            echo "Warning: Invalid mode '$MODE_VAL'. Using 'default'" >&2
            MODE_VAL="default"
            ;;
    esac
else
    MODE_VAL=""
    if [ -n "$MODE" ]; then
        echo "Warning: MODE is set but your Snell version ($SNELL_VERSION) doesn't support it. Mode requires v6.0.0b3 or later." >&2
    fi
fi

# 生成配置文件
echo "Generating configuration..."
cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${EXPECTED_LISTEN}
psk = ${EXPECTED_PSK}
EOF

# 添加可选配置项
if [ "$WRITE_IPV6" = true ]; then
    set_config "ipv6" "$IPV6_VAL"
fi

set_config "dns" "$EXPECTED_DNS"
set_config "dns-ip-preference" "$EXPECTED_DNS_IP_PREFERENCE"
set_config "egress-interface" "$EGRESS_INTERFACE_VAL"
set_config "obfs" "$OBFS_VAL"
set_config "host" "$HOST_VAL"

# 只有支持 mode 的版本才写入
if [ -n "$MODE_VAL" ]; then
    set_config "mode" "$MODE_VAL"
fi

# 处理所有 SNELL_ 前缀的环境变量作为额外配置项
process_snell_env_vars

# 显示配置并启动
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Snell Server Configuration:"
cat "$CONFIG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 构建启动命令
CMD="./snell-server -c $CONFIG_FILE"
if [ -n "$LOGLEVEL_VAL" ]; then
    CMD="$CMD -l $LOGLEVEL_VAL"
    echo "Log level: $LOGLEVEL_VAL (command line parameter)"
else
    echo "Log level: default"
fi
echo "Starting Snell Server..."
echo "Command: $CMD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 启动 Snell 服务
$CMD &
SNELL_PID=$!

# 等待进程结束
wait $SNELL_PID 2>/dev/null
