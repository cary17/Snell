#!/bin/sh

trap 'kill -TERM $SNELL_PID 2>/dev/null; wait $SNELL_PID 2>/dev/null' TERM INT

# ============================================================
# 工具函数
# ============================================================

strip_quotes() {
    echo "$1" | sed -e 's/^[[:space:]"'"'"']//' -e 's/[[:space:]"'"'"']$//'
}

random_psk() {
    if [ -r /dev/urandom ]; then
        RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
        LENGTH=$((32 + (${RANDOM_BYTE:-0} % 33)))
    else
        LENGTH=48
    fi
    tr -dc 'A-Za-z0-9+/' </dev/urandom 2>/dev/null | head -c ${LENGTH} || \
        echo "$(date +%s)$$$(hostname)" | sha256sum | cut -c1-${LENGTH}
}

random_port() {
    echo $((10000 + $(od -An -N2 -i /dev/urandom 2>/dev/null || echo $$) % 55536))
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
# 需要 Snell >= v6.0.0b3 或 v6.0.0 正式版及以上
# ============================================================

supports_mode() {
    local version=$(get_snell_version)
    # 移除 v 前缀
    version=${version#v}
    
    # 提取主版本
    local main=$(echo "$version" | cut -d. -f1)
    
    # 主版本 > 6 肯定支持
    if [ "$main" -gt 6 ] 2>/dev/null; then
        return 0
    fi
    
    # 主版本 = 6 时需要进一步判断
    if [ "$main" -eq 6 ] 2>/dev/null; then
        # 排除 v6.0.0b2 及更早的 beta 版本
        if echo "$version" | grep -q 'b[0-2]$'; then
            return 1
        fi
        # 其他所有 v6.x.x 都支持（包括 v6.0.0 正式版和 v6.0.0b3+）
        return 0
    fi
    
    # 主版本 < 6 不支持
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
ENV_HASH_FILE="/snell/.env_hash"

set_config() {
    local key="$1" new_value="$2"
    
    if [ -z "$new_value" ]; then
        sed -i "/^${key} = /d" "$CONFIG_FILE" 2>/dev/null
        return
    fi
    
    local old_value=$(grep "^${key} = " "$CONFIG_FILE" 2>/dev/null | sed "s/^${key} = //")
    [ "$old_value" = "$new_value" ] && return
    
    if grep -q "^${key} = " "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^${key} = .*/${key} = ${new_value}/" "$CONFIG_FILE"
    else
        sed -i "/^psk = /a ${key} = ${new_value}" "$CONFIG_FILE"
    fi
}

current_env_hash() {
    echo "${LISTEN:-}${PSK:-}${IPV6:-}${DNS:-}${DNS_IP_PREFERENCE:-}${MODE:-}" | \
        md5sum 2>/dev/null | cut -c1-32 || echo "00000000000000000000000000000000"
}

# ============================================================
# 主逻辑
# ============================================================

SNELL_VERSION=$(get_snell_version)
MAJOR_VERSION=$(get_major_version)
MINOR_VERSION=$(echo "${SNELL_VERSION#v}" | cut -d. -f2)

# 计算期望配置
if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
    EXPECTED_DNS_IP_PREFERENCE=${DNS_IP_PREFERENCE:-$(get_dns_ip_preference)}
    WRITE_IPV6=false
else
    EXPECTED_DNS_IP_PREFERENCE=${DNS_IP_PREFERENCE:-$(get_dns_ip_preference)}
    IPV6_VAL=${IPV6:-false}
    WRITE_IPV6=true
fi

EXPECTED_PSK=${PSK:-$(random_psk)}
EXPECTED_LISTEN=$(parse_listen "$MAJOR_VERSION" "${LISTEN:-}")

# DNS 配置（v4.1.0+ 才支持）
if [ "$MAJOR_VERSION" -ge 4 ] && { [ "$MAJOR_VERSION" -ne 4 ] || [ "$MINOR_VERSION" -ge 1 ]; }; then
    EXPECTED_DNS=${DNS:-$(get_dns_value)}
else
    EXPECTED_DNS=""
fi

EGRESS_INTERFACE_VAL=${EGRESS_INTERFACE:-""}
OBFS_VAL=${OBFS:-""}
HOST_VAL=${HOST:-""}

# Mode 配置（需要 Snell >= v6.0.0b3 或 v6.0.0 正式版及以上）
if supports_mode; then
    MODE_VAL=${MODE:-default}
    # 验证 mode 值是否合法
    case "$MODE_VAL" in
        default|unshaped|unsafe-raw) ;;
        *) MODE_VAL="default" ;;
    esac
else
    MODE_VAL=""
fi

# 检查是否需要更新
NEED_UPDATE=false
CURRENT_HASH=$(current_env_hash)

if [ ! -f "$CONFIG_FILE" ]; then
    NEED_UPDATE=true
else
    if [ -f "$ENV_HASH_FILE" ]; then
        OLD_HASH=$(cat "$ENV_HASH_FILE" 2>/dev/null)
        [ "$CURRENT_HASH" != "$OLD_HASH" ] && NEED_UPDATE=true
    else
        NEED_UPDATE=true
    fi
fi

if [ "$NEED_UPDATE" = true ]; then
    # 创建或更新配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${EXPECTED_LISTEN}
psk = ${EXPECTED_PSK}
EOF
    fi
    
    set_config "listen" "$EXPECTED_LISTEN"
    set_config "psk" "$EXPECTED_PSK"
    
    if [ "$WRITE_IPV6" = true ]; then
        set_config "ipv6" "$IPV6_VAL"
    else
        set_config "ipv6" ""
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
    
    echo "$CURRENT_HASH" > "$ENV_HASH_FILE"
fi

# 显示配置并启动
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$CONFIG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

./snell-server -c "$CONFIG_FILE" &
SNELL_PID=$!
wait $SNELL_PID 2>/dev/null
