#!/bin/sh

trap 'kill -TERM $SNELL_PID 2>/dev/null; wait $SNELL_PID 2>/dev/null' TERM INT

# ============================================================
# 工具函数
# ============================================================

strip_quotes() {
    echo "$1" | sed -e 's/^[[:space:]"'"'"']//' -e 's/[[:space:]"'"'"']$//'
}

# 生成随机 PSK（24-64 字节，首字符必须是字母）
random_psk() {
    # 随机长度 24-64
    if [ -r /dev/urandom ]; then
        RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
        LENGTH=$((24 + (${RANDOM_BYTE:-0} % 41)))
    else
        LENGTH=32
    fi
    
    # 确保长度至少为 24
    if [ "$LENGTH" -lt 24 ]; then
        LENGTH=24
    fi
    
    # 字母字符集（用于首字符）
    ALPHABET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    ALPHABET_LEN=52
    
    # 常用密码字符集（字母 + 数字 + 常用符号）
    CHARSET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+'
    CHARSET_LEN=84
    
    # 首字符必须是字母
    if [ -r /dev/urandom ]; then
        RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
        INDEX=$((RANDOM_BYTE % ALPHABET_LEN))
    else
        INDEX=$(($$ % ALPHABET_LEN))
    fi
    PSK="$(echo "$ALPHABET" | cut -c$((INDEX+1)))"
    
    # 剩余字符
    for i in $(seq 2 $LENGTH); do
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

random_port() {
    echo $((10000 + $(od -An -N2 -i /dev/urandom 2>/dev/null || echo $$) % 55536))
}

# ============================================================
# 日志级别验证
# ============================================================

validate_loglevel() {
    case "$1" in
        debug|info|warning|error|fatal) return 0 ;;
        *) return 1 ;;
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

# 检查是否支持 mode 配置（v6.0.0b3+）
supports_mode() {
    local version=$(get_snell_version)
    version=${version#v}
    
    # v6.0.0b3+ 或 v6.0.0+ 正式版都支持
    if echo "$version" | grep -qE '^6\.0\.0b[3-9]|^6\.0\.0$|^6\.0\.[1-9]|^6\.[1-9]'; then
        return 0
    fi
    
    # v6.x 其他版本
    if echo "$version" | grep -qE '^6\.'; then
        return 0
    fi
    
    return 1
}

# 检查是否是 v6 或更高版本（v6 废弃了 ipv6 配置项）
is_v6_or_higher() {
    local major=$(get_major_version)
    [ "$major" -ge 6 ] 2>/dev/null
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

# 处理 SNELL_ 前缀的环境变量（扩展配置）
process_snell_env_vars() {
    for var in $(env | grep '^SNELL_' | cut -d'=' -f1); do
        key=$(echo "$var" | sed 's/^SNELL_//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        eval "value=\$$var"
        if [ -n "$value" ]; then
            set_config "$key" "$value"
        fi
    done
}

current_env_hash() {
    local hash_str=""
    # v6+ 不再包含 IPV6 变量
    if is_v6_or_higher; then
        for var in LISTEN PSK DNS DNS_IP_PREFERENCE MODE EGRESS_INTERFACE OBFS HOST; do
            eval "val=\${$var:-}"
            hash_str="${hash_str}${val}"
        done
    else
        for var in LISTEN PSK IPV6 DNS DNS_IP_PREFERENCE EGRESS_INTERFACE OBFS HOST; do
            eval "val=\${$var:-}"
            hash_str="${hash_str}${val}"
        done
    fi
    # 添加 SNELL_ 前缀的变量
    for var in $(env | grep '^SNELL_' | cut -d'=' -f1 | sort); do
        eval "val=\$$var"
        hash_str="${hash_str}${var}=${val}"
    done
    echo "$hash_str" | md5sum 2>/dev/null | cut -c1-32 || echo "00000000000000000000000000000000"
}

# ============================================================
# 主逻辑
# ============================================================

SNELL_VERSION=$(get_snell_version)
MAJOR_VERSION=$(get_major_version)
MINOR_VERSION=$(echo "${SNELL_VERSION#v}" | cut -d. -f2)

echo "Snell version: $SNELL_VERSION"

# 计算期望配置
if is_v6_or_higher; then
    # v6+ 废弃 ipv6 配置项，使用 dns-ip-preference 代替
    EXPECTED_DNS_IP_PREFERENCE=${DNS_IP_PREFERENCE:-$(get_dns_ip_preference)}
    WRITE_IPV6=false
else
    # v5 及以下保留 ipv6 配置项
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

# Mode 配置（v6.0.0b3+ 才支持）
if supports_mode; then
    MODE_VAL=${MODE:-default}
    case "$MODE_VAL" in
        default|unshaped|unsafe-raw) ;;
        *) 
            echo "Warning: Invalid mode '$MODE_VAL', using default" >&2
            MODE_VAL="default"
            ;;
    esac
else
    MODE_VAL=""
    if [ -n "$MODE" ]; then
        echo "Warning: MODE requires Snell v6.0.0b3 or later" >&2
    fi
fi

# 强制更新配置（简单可靠）
echo "Generating configuration..."

# 直接重新生成配置文件
cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${EXPECTED_LISTEN}
psk = ${EXPECTED_PSK}
EOF

# 添加 DNS 配置（如果有）
if [ -n "$EXPECTED_DNS" ]; then
    echo "dns = ${EXPECTED_DNS}" >> "$CONFIG_FILE"
fi

# 添加 dns-ip-preference
echo "dns-ip-preference = ${EXPECTED_DNS_IP_PREFERENCE}" >> "$CONFIG_FILE"

# v5 及以下添加 ipv6 配置
if [ "$WRITE_IPV6" = true ]; then
    echo "ipv6 = ${IPV6_VAL}" >> "$CONFIG_FILE"
fi

# 添加 egress-interface（如果有）
if [ -n "$EGRESS_INTERFACE_VAL" ]; then
    echo "egress-interface = ${EGRESS_INTERFACE_VAL}" >> "$CONFIG_FILE"
fi

# 添加 obfs（如果有）
if [ -n "$OBFS_VAL" ]; then
    echo "obfs = ${OBFS_VAL}" >> "$CONFIG_FILE"
fi

# 添加 host（如果有）
if [ -n "$HOST_VAL" ]; then
    echo "host = ${HOST_VAL}" >> "$CONFIG_FILE"
fi

# 添加 mode（v6.0.0b3+）
if [ -n "$MODE_VAL" ]; then
    echo "mode = ${MODE_VAL}" >> "$CONFIG_FILE"
fi

# 处理 SNELL_ 前缀的扩展配置
for var in $(env | grep '^SNELL_' | cut -d'=' -f1); do
    key=$(echo "$var" | sed 's/^SNELL_//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    eval "value=\$$var"
    if [ -n "$value" ]; then
        echo "${key} = ${value}" >> "$CONFIG_FILE"
    fi
done

# 显示配置并启动
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$CONFIG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 构建启动命令
CMD="./snell-server -c $CONFIG_FILE"
if [ -n "$LOGLEVEL" ] && validate_loglevel "$LOGLEVEL"; then
    CMD="$CMD -l $LOGLEVEL"
    echo "Log level: $LOGLEVEL"
fi
echo "Starting: $CMD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

$CMD &
SNELL_PID=$!
wait $SNELL_PID 2>/dev/null
