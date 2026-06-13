#!/bin/sh
set -e

# 信号处理：直接传递信号给子进程
trap 'kill -TERM $SNELL_PID 2>/dev/null; wait $SNELL_PID 2>/dev/null' TERM INT

# 去除引号和首尾空格
strip_quotes() {
    echo "$1" | sed -e 's/^[[:space:]"'"'"']//' -e 's/[[:space:]"'"'"']$//'
}

# 随机生成 PSK（32-64位随机长度随机字符）
random_psk() {
    if [ -r /dev/urandom ]; then
        RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
        if [ -n "$RANDOM_BYTE" ]; then
            LENGTH=$((32 + RANDOM_BYTE % 33))
        else
            LENGTH=48
        fi
    else
        LENGTH=48
    fi
    
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9+/' </dev/urandom | head -c ${LENGTH}
    else
        echo "$(date +%s%N)$$$(hostname)" | sha256sum | cut -c1-${LENGTH}
    fi
}

# 随机生成端口（10000-65535）
random_port() {
    echo $((10000 + $(od -An -N2 -i /dev/urandom 2>/dev/null || echo $$) % 55536))
}

# 使用 nc 测试 IPv4 连通性
check_tcp_ipv4() {
    local target="$1"
    local port="${2:-53}"
    local timeout="${3:-2}"
    
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w $timeout "$target" "$port" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# 使用 nc 测试 IPv6 连通性
check_tcp_ipv6() {
    local target="$1"
    local port="${2:-53}"
    local timeout="${3:-2}"
    
    if command -v nc >/dev/null 2>&1; then
        if nc -6 -z -w $timeout "$target" "$port" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# 检测 IPv4 网络是否可用
check_ipv4_available() {
    local ipv4_servers="8.8.8.8 1.1.1.1"
    
    for server in $ipv4_servers; do
        if check_tcp_ipv4 "$server" 53 1; then
            return 0
        fi
    done
    return 1
}

# 检测 IPv6 网络是否可用
check_ipv6_available() {
    local ipv6_servers="2001:4860:4860::8888 2606:4700:4700::1111"
    
    for server in $ipv6_servers; do
        if check_tcp_ipv6 "$server" 53 1; then
            return 0
        fi
    done
    return 1
}

# 获取 DNS 值（根据网络检测结果）
get_dns_value() {
    local ipv4_ok=false
    local ipv6_ok=false
    
    if check_ipv4_available; then
        ipv4_ok=true
    fi
    
    if check_ipv6_available; then
        ipv6_ok=true
    fi
    
    if $ipv4_ok && $ipv6_ok; then
        echo "8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
    elif $ipv4_ok; then
        echo "8.8.8.8, 1.1.1.1"
    elif $ipv6_ok; then
        echo "2001:4860:4860::8888, 2606:4700:4700::1111"
    else
        echo "8.8.8.8, 1.1.1.1"
    fi
}

# 自动检测最佳 DNS_IP_PREFERENCE 设置
detect_dns_ip_preference() {
    local ipv4_available=false
    local ipv6_available=false
    
    if check_ipv4_available; then
        ipv4_available=true
    fi
    
    if check_ipv6_available; then
        ipv6_available=true
    fi
    
    if $ipv6_available && $ipv4_available; then
        echo "prefer-ipv4"
    elif $ipv6_available; then
        echo "prefer-ipv6"
    elif $ipv4_available; then
        echo "prefer-ipv4"
    else
        echo "default"
    fi
}

# 从文件读取 Snell 版本
get_snell_version() {
    if [ -f /snell/snell-version ]; then
        cat /snell/snell-version
    elif [ -f /snell-version ]; then
        cat /snell-version
    else
        echo "unknown"
    fi
}

# 获取主版本号
get_major_version() {
    if [ -f /snell/snell-major-version ]; then
        cat /snell/snell-major-version
    elif [ -f /snell-major-version ]; then
        cat /snell-major-version
    else
        echo "0"
    fi
}

# 获取完整版本号
get_full_version() {
    VERSION=$(get_snell_version)
    echo "${VERSION#v}"
}

# 处理 LISTEN 配置
parse_listen() {
    local major="$1"
    local input="$2"
    
    if [ -z "$input" ]; then
        PORT=$(random_port)
        if [ "$major" -ge 6 ] 2>/dev/null; then
            printf "%s" "0.0.0.0:$PORT, [::]:$PORT"
        else
            printf "%s" ":::$PORT"
        fi
        return
    fi
    
    if echo "$input" | grep -q ':' && ! echo "$input" | grep -q '^[0-9]\+$'; then
        printf "%s" "$input"
        return
    fi
    
    if echo "$input" | grep -q ','; then
        if [ "$major" -ge 6 ] 2>/dev/null; then
            local result=""
            IFS=','
            for item in $input; do
                item=$(echo "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                [ -z "$item" ] && continue
                [ -n "$result" ] && result="$result, "
                result="${result}0.0.0.0:${item}, [::]:${item}"
            done
            printf "%s" "$result"
        else
            local port=$(echo "$input" | grep -oE '[0-9]+' | head -n1)
            printf "%s" ":::$port"
        fi
    else
        if [ "$major" -ge 6 ] 2>/dev/null; then
            printf "%s" "0.0.0.0:${input}, [::]:${input}"
        else
            printf "%s" ":::${input}"
        fi
    fi
}

# 读取现有配置值
get_config_value() {
    local key="$1"
    grep "^${key} = " "$CONFIG_FILE" 2>/dev/null | sed "s/^${key} = //"
}

# 设置配置项（添加或更新）
set_config() {
    local key="$1"
    local new_value="$2"
    
    # 如果值为空，删除配置项
    if [ -z "$new_value" ]; then
        if grep -q "^${key} = " "$CONFIG_FILE" 2>/dev/null; then
            sed -i "/^${key} = /d" "$CONFIG_FILE"
        fi
        return
    fi
    
    old_value=$(get_config_value "$key")
    
    if [ "$old_value" != "$new_value" ]; then
        if grep -q "^${key} = " "$CONFIG_FILE" 2>/dev/null; then
            # 更新现有配置
            sed -i "s/^${key} = .*/${key} = ${new_value}/" "$CONFIG_FILE"
        else
            # 添加新配置（在 psk 后面插入）
            sed -i "/^psk = /a ${key} = ${new_value}" "$CONFIG_FILE"
        fi
    fi
}

# 主逻辑
CONFIG_FILE="/snell/snell.conf"
ENV_HASH_FILE="/snell/.env_hash"

# 获取当前环境变量哈希
current_env_hash() {
    echo "${LISTEN:-}${PSK:-}${IPV6:-}${DNS:-}${DNS_IP_PREFERENCE:-}${EGRESS_INTERFACE:-}${OBFS:-}${HOST:-}" | sha256sum | cut -c1-32
}

# 获取当前配置值（用于比较）
SNELL_VERSION=$(get_snell_version)
FULL_VERSION=$(get_full_version)
MAJOR_VERSION=$(get_major_version)
MINOR_VERSION=$(echo "$FULL_VERSION" | cut -d. -f2)

# 计算当前期望的配置值
if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
    if [ -n "${DNS_IP_PREFERENCE}" ]; then
        EXPECTED_DNS_IP_PREFERENCE=$(strip_quotes "${DNS_IP_PREFERENCE}")
    else
        EXPECTED_DNS_IP_PREFERENCE=$(detect_dns_ip_preference)
    fi
    
    case "$EXPECTED_DNS_IP_PREFERENCE" in
        ipv4-only) IPV6_ENABLED="false" ;;
        *) IPV6_ENABLED="true" ;;
    esac
else
    EXPECTED_DNS_IP_PREFERENCE=""
    if [ -n "${IPV6}" ]; then
        IPV6_VAL=$(strip_quotes "${IPV6}")
    else
        IPV6_VAL="false"
    fi
    IPV6_ENABLED="$IPV6_VAL"
fi

if [ -n "${PSK}" ]; then
    EXPECTED_PSK=$(strip_quotes "${PSK}")
else
    EXPECTED_PSK=$(random_psk)
fi

EXPECTED_LISTEN=$(parse_listen "$MAJOR_VERSION" "$(strip_quotes "${LISTEN:-}")")

# DNS 配置
if [ "$MAJOR_VERSION" -eq 4 ] && [ "$MINOR_VERSION" -lt 1 ]; then
    EXPECTED_DNS=""
elif [ "$MAJOR_VERSION" -lt 4 ]; then
    EXPECTED_DNS=""
else
    if [ -n "${DNS}" ]; then
        EXPECTED_DNS=$(strip_quotes "${DNS}")
    else
        if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
            EXPECTED_DNS=$(get_dns_value)
        else
            if [ "$IPV6_ENABLED" = "true" ]; then
                EXPECTED_DNS="8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
            else
                EXPECTED_DNS="8.8.8.8, 1.1.1.1"
            fi
        fi
    fi
fi

if [ "$MAJOR_VERSION" -ge 5 ] 2>/dev/null; then
    if [ -n "${EGRESS_INTERFACE}" ]; then
        EXPECTED_EGRESS_INTERFACE=$(strip_quotes "${EGRESS_INTERFACE}")
    else
        EXPECTED_EGRESS_INTERFACE=""
    fi
else
    EXPECTED_EGRESS_INTERFACE=""
fi

if [ "$MAJOR_VERSION" -lt 6 ] 2>/dev/null; then
    if [ -n "${OBFS}" ]; then
        EXPECTED_OBFS=$(strip_quotes "${OBFS}")
    else
        EXPECTED_OBFS=""
    fi
    if [ -n "${HOST}" ]; then
        EXPECTED_HOST=$(strip_quotes "${HOST}")
    else
        EXPECTED_HOST=""
    fi
else
    EXPECTED_OBFS=""
    EXPECTED_HOST=""
fi

# 检查配置文件是否需要更新
NEED_UPDATE=false
CURRENT_HASH=$(current_env_hash)

if [ ! -f "$CONFIG_FILE" ]; then
    NEED_UPDATE=true
else
    # 检查必要配置项是否存在
    if ! grep -q "^listen = " "$CONFIG_FILE" 2>/dev/null; then
        NEED_UPDATE=true
    fi
    if ! grep -q "^psk = " "$CONFIG_FILE" 2>/dev/null; then
        NEED_UPDATE=true
    fi
    
    # v6+ 检查 dns 配置项
    if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
        if [ -n "$EXPECTED_DNS" ] && ! grep -q "^dns = " "$CONFIG_FILE" 2>/dev/null; then
            NEED_UPDATE=true
        fi
        if [ -n "$EXPECTED_DNS_IP_PREFERENCE" ] && ! grep -q "^dns-ip-preference = " "$CONFIG_FILE" 2>/dev/null; then
            NEED_UPDATE=true
        fi
    fi
    
    # 检查哈希
    if [ -f "$ENV_HASH_FILE" ]; then
        OLD_HASH=$(cat "$ENV_HASH_FILE" 2>/dev/null)
        if [ "$CURRENT_HASH" != "$OLD_HASH" ]; then
            NEED_UPDATE=true
        fi
    else
        NEED_UPDATE=true
    fi
fi

if [ "$NEED_UPDATE" = true ]; then
    # 生成或更新配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        # 创建新配置文件
        cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${EXPECTED_LISTEN}
psk = ${EXPECTED_PSK}
EOF
    fi
    
    # 使用 set_config 统一处理所有配置项（会自动添加缺失的）
    set_config "listen" "$EXPECTED_LISTEN"
    set_config "psk" "$EXPECTED_PSK"
    
    if [ "$MAJOR_VERSION" -lt 6 ] 2>/dev/null; then
        set_config "ipv6" "$IPV6_VAL"
    else
        set_config "ipv6" ""  # 删除 ipv6 配置项
    fi
    
    set_config "dns" "$EXPECTED_DNS"
    set_config "dns-ip-preference" "$EXPECTED_DNS_IP_PREFERENCE"
    set_config "egress-interface" "$EXPECTED_EGRESS_INTERFACE"
    set_config "obfs" "$EXPECTED_OBFS"
    set_config "host" "$EXPECTED_HOST"
    
    # 保存环境变量哈希
    echo "$CURRENT_HASH" > "$ENV_HASH_FILE"
fi

# 显示配置文件内容
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$CONFIG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 启动 snell-server
./snell-server -c "$CONFIG_FILE" &
SNELL_PID=$!

wait $SNELL_PID 2>/dev/null
