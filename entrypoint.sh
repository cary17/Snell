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

# ============================================================
# 网络检测函数
# ============================================================

# 使用 nc 测试连通性（兼容所有版本，支持 IPv6 括号）
test_connectivity() {
    local target="$1"
    local port="${2:-80}"
    local timeout="${3:-2}"
    
    if command -v nc >/dev/null 2>&1; then
        # 如果 target 看起来像 IPv6 地址（包含冒号），则加上方括号
        if echo "$target" | grep -q ':'; then
            if nc -z -w $timeout "[$target]" "$port" 2>/dev/null; then
                return 0
            fi
        else
            if nc -z -w $timeout "$target" "$port" 2>/dev/null; then
                return 0
            fi
        fi
    fi
    return 1
}

# 测试 Google 连通性（国际网络判断唯一依据）
test_google() {
    test_connectivity "google.com" 80 2
}

# 测试国内域名（baidu, aliyun）
test_domestic() {
    for domain in baidu.com aliyun.com; do
        if test_connectivity "$domain" 80 2; then
            return 0
        fi
    done
    return 1
}

# 检测网络环境
# 返回值：0=国内, 1=国外, 2=无网络
detect_network_env() {
    local google_ok=false
    local domestic_ok=false
    
    if test_google; then
        google_ok=true
    fi
    
    if test_domestic; then
        domestic_ok=true
    fi
    
    # 判断逻辑：Google 通 = 国外网络
    if $google_ok; then
        return 1  # 国外
    elif $domestic_ok; then
        return 0  # 国内（Google 不通，但国内域名通）
    else
        return 2  # 无网络（Google 和国内域名都不通）
    fi
}

# 测试 IPv4 连通性（用 IP 直连）
test_ipv4_connectivity() {
    # 国际 IPv4
    for ip in 8.8.8.8 1.1.1.1; do
        if test_connectivity "$ip" 53 2; then
            return 0
        fi
    done
    # 国内 IPv4
    for ip in 119.29.29.29 223.5.5.5; do
        if test_connectivity "$ip" 53 2; then
            return 0
        fi
    done
    return 1
}

# 测试 IPv6 连通性
test_ipv6_connectivity() {
    # 国际 IPv6
    for ip in 2001:4860:4860::8888 2606:4700:4700::1111; do
        if test_connectivity "$ip" 53 2; then
            return 0
        fi
    done
    # 国内 IPv6
    for ip in 2402:4e00:: 2400:3200::1; do
        if test_connectivity "$ip" 53 2; then
            return 0
        fi
    done
    return 1
}

# 检测 IPv4 网络是否可用
check_ipv4_available() {
    test_ipv4_connectivity
}

# 检测 IPv6 网络是否可用
check_ipv6_available() {
    test_ipv6_connectivity
}

# ============================================================
# DNS 值生成函数
# ============================================================

# 获取 DNS 值（根据网络环境+连通性）
get_dns_value() {
    detect_network_env
    local network_env=$?
    
    # 无网络时，返回完整的国际 DNS（IPv4 + IPv6）
    if [ $network_env -eq 2 ]; then
        echo "8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
        return
    fi
    
    # 检测 IPv4/IPv6 连通性
    local ipv4_ok=false
    local ipv6_ok=false
    
    if test_ipv4_connectivity; then
        ipv4_ok=true
    fi
    
    if test_ipv6_connectivity; then
        ipv6_ok=true
    fi
    
    # 根据网络环境选择 DNS 模板
    local ipv4_dns=""
    local ipv6_dns=""
    
    if [ $network_env -eq 0 ]; then  # 国内
        ipv4_dns="119.29.29.29, 223.5.5.5"
        ipv6_dns="2402:4e00::, 2400:3200::1"
    else  # 国外
        ipv4_dns="8.8.8.8, 1.1.1.1"
        ipv6_dns="2001:4860:4860::8888, 2606:4700:4700::1111"
    fi
    
    # 根据连通性返回
    if $ipv4_ok && $ipv6_ok; then
        echo "${ipv4_dns}, ${ipv6_dns}"
    elif $ipv4_ok; then
        echo "${ipv4_dns}"
    elif $ipv6_ok; then
        echo "${ipv6_dns}"
    else
        echo "$ipv4_dns"
    fi
}

# 获取 DNS_IP_PREFERENCE
get_dns_ip_preference() {
    detect_network_env
    local network_env=$?
    
    if [ $network_env -eq 2 ]; then
        echo "prefer-ipv4"
        return
    fi
    
    local ipv4_ok=false
    local ipv6_ok=false
    
    if test_ipv4_connectivity; then
        ipv4_ok=true
    fi
    
    if test_ipv6_connectivity; then
        ipv6_ok=true
    fi
    
    if $ipv4_ok && $ipv6_ok; then
        echo "prefer-ipv4"
    elif $ipv6_ok; then
        echo "prefer-ipv6"
    else
        echo "prefer-ipv4"
    fi
}

# ============================================================
# 版本读取函数
# ============================================================

get_snell_version() {
    if [ -f /snell/snell-version ]; then
        cat /snell/snell-version
    elif [ -f /snell-version ]; then
        cat /snell-version
    else
        echo "unknown"
    fi
}

get_major_version() {
    if [ -f /snell/snell-major-version ]; then
        cat /snell/snell-major-version
    elif [ -f /snell-major-version ]; then
        cat /snell-major-version
    else
        echo "0"
    fi
}

get_full_version() {
    VERSION=$(get_snell_version)
    echo "${VERSION#v}"
}

# ============================================================
# LISTEN 配置解析
# ============================================================

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

# ============================================================
# 配置文件操作函数
# ============================================================

CONFIG_FILE="/snell/snell.conf"
ENV_HASH_FILE="/snell/.env_hash"

get_config_value() {
    grep "^${1} = " "$CONFIG_FILE" 2>/dev/null | sed "s/^${1} = //"
}

set_config() {
    local key="$1"
    local new_value="$2"
    
    if [ -z "$new_value" ]; then
        if grep -q "^${key} = " "$CONFIG_FILE" 2>/dev/null; then
            sed -i "/^${key} = /d" "$CONFIG_FILE"
        fi
        return
    fi
    
    old_value=$(get_config_value "$key")
    
    if [ "$old_value" != "$new_value" ]; then
        if grep -q "^${key} = " "$CONFIG_FILE" 2>/dev/null; then
            sed -i "s/^${key} = .*/${key} = ${new_value}/" "$CONFIG_FILE"
        else
            sed -i "/^psk = /a ${key} = ${new_value}" "$CONFIG_FILE"
        fi
    fi
}

# 获取当前环境变量哈希
current_env_hash() {
    echo "${LISTEN:-}${PSK:-}${IPV6:-}${DNS:-}${DNS_IP_PREFERENCE:-}${EGRESS_INTERFACE:-}${OBFS:-}${HOST:-}" | sha256sum | cut -c1-32
}

# ============================================================
# 主逻辑
# ============================================================

SNELL_VERSION=$(get_snell_version)
FULL_VERSION=$(get_full_version)
MAJOR_VERSION=$(get_major_version)
MINOR_VERSION=$(echo "$FULL_VERSION" | cut -d. -f2)

# 计算期望的配置值
# ============================================================

# 1. DNS_IP_PREFERENCE 和 IPV6 相关
if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
    if [ -n "${DNS_IP_PREFERENCE}" ]; then
        EXPECTED_DNS_IP_PREFERENCE=$(strip_quotes "${DNS_IP_PREFERENCE}")
    else
        EXPECTED_DNS_IP_PREFERENCE=$(get_dns_ip_preference)
    fi
    # v6+ 不需要写入 ipv6 配置项
    WRITE_IPV6=false
else
    EXPECTED_DNS_IP_PREFERENCE=""
    if [ -n "${IPV6}" ]; then
        IPV6_VAL=$(strip_quotes "${IPV6}")
    else
        IPV6_VAL="false"
    fi
    WRITE_IPV6=true
fi

# 2. PSK
if [ -n "${PSK}" ]; then
    EXPECTED_PSK=$(strip_quotes "${PSK}")
else
    EXPECTED_PSK=$(random_psk)
fi

# 3. LISTEN
EXPECTED_LISTEN=$(parse_listen "$MAJOR_VERSION" "$(strip_quotes "${LISTEN:-}")")

# 4. DNS（v4.1.0+ 才支持）
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
            # v4/v5 版本
            if [ "$IPV6_VAL" = "true" ]; then
                EXPECTED_DNS="8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
            else
                EXPECTED_DNS="8.8.8.8, 1.1.1.1"
            fi
        fi
    fi
fi

# 5. EGRESS_INTERFACE（v5+ 支持，需用户自定义才写入）
if [ "$MAJOR_VERSION" -ge 5 ] 2>/dev/null; then
    if [ -n "${EGRESS_INTERFACE}" ]; then
        EXPECTED_EGRESS_INTERFACE=$(strip_quotes "${EGRESS_INTERFACE}")
    else
        EXPECTED_EGRESS_INTERFACE=""  # 不写入配置
    fi
else
    EXPECTED_EGRESS_INTERFACE=""
fi

# 6. OBFS 和 HOST（v6 以下支持，需用户自定义才写入）
if [ "$MAJOR_VERSION" -lt 6 ] 2>/dev/null; then
    if [ -n "${OBFS}" ]; then
        EXPECTED_OBFS=$(strip_quotes "${OBFS}")
    else
        EXPECTED_OBFS=""  # 不写入配置
    fi
    if [ -n "${HOST}" ]; then
        EXPECTED_HOST=$(strip_quotes "${HOST}")
    else
        EXPECTED_HOST=""  # 不写入配置
    fi
else
    EXPECTED_OBFS=""
    EXPECTED_HOST=""
fi

# ============================================================
# 检查是否需要更新配置文件
# ============================================================

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
    
    # v6+ 检查 dns 和 dns-ip-preference 配置项
    if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
        if [ -n "$EXPECTED_DNS" ] && ! grep -q "^dns = " "$CONFIG_FILE" 2>/dev/null; then
            NEED_UPDATE=true
        fi
        if [ -n "$EXPECTED_DNS_IP_PREFERENCE" ] && ! grep -q "^dns-ip-preference = " "$CONFIG_FILE" 2>/dev/null; then
            NEED_UPDATE=true
        fi
    fi
    
    # 检查哈希（环境变量是否变化）
    if [ -f "$ENV_HASH_FILE" ]; then
        OLD_HASH=$(cat "$ENV_HASH_FILE" 2>/dev/null)
        if [ "$CURRENT_HASH" != "$OLD_HASH" ]; then
            NEED_UPDATE=true
        fi
    else
        NEED_UPDATE=true
    fi
fi

# ============================================================
# 更新配置文件
# ============================================================

if [ "$NEED_UPDATE" = true ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${EXPECTED_LISTEN}
psk = ${EXPECTED_PSK}
EOF
    fi
    
    # 始终更新 listen 和 psk
    set_config "listen" "$EXPECTED_LISTEN"
    set_config "psk" "$EXPECTED_PSK"
    
    # 处理 ipv6 配置项（仅 v6 以下版本）
    if [ "$WRITE_IPV6" = true ]; then
        set_config "ipv6" "$IPV6_VAL"
    else
        set_config "ipv6" ""  # 删除 ipv6 配置项
    fi
    
    # 处理 DNS（有默认值，自动补全）
    set_config "dns" "$EXPECTED_DNS"
    
    # 处理 DNS_IP_PREFERENCE（v6+ 有默认值）
    if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
        set_config "dns-ip-preference" "$EXPECTED_DNS_IP_PREFERENCE"
    else
        set_config "dns-ip-preference" ""  # 删除（v6 以下不支持）
    fi
    
    # 处理 EGRESS_INTERFACE（需要用户自定义才写入）
    if [ -n "$EXPECTED_EGRESS_INTERFACE" ]; then
        set_config "egress-interface" "$EXPECTED_EGRESS_INTERFACE"
    else
        set_config "egress-interface" ""
    fi
    
    # 处理 OBFS（需要用户自定义才写入）
    if [ -n "$EXPECTED_OBFS" ]; then
        set_config "obfs" "$EXPECTED_OBFS"
    else
        set_config "obfs" ""
    fi
    
    # 处理 HOST（需要用户自定义才写入）
    if [ -n "$EXPECTED_HOST" ]; then
        set_config "host" "$EXPECTED_HOST"
    else
        set_config "host" ""
    fi
    
    # 保存环境变量哈希
    echo "$CURRENT_HASH" > "$ENV_HASH_FILE"
fi

# ============================================================
# 显示配置文件并启动服务
# ============================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$CONFIG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

./snell-server -c "$CONFIG_FILE" &
SNELL_PID=$!

wait $SNELL_PID 2>/dev/null