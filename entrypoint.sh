#!/bin/sh

trap 'kill -TERM $SNELL_PID 2>/dev/null' TERM INT

# ============================================================
# 工具函数
# ============================================================

# 生成随机 PSK（24-64 字节，首字符必须是字母，最后一位不能是特殊符号）
random_psk() {
    if [ -r /dev/urandom ]; then
        RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
        LENGTH=$((24 + (${RANDOM_BYTE:-0} % 41)))
    else
        LENGTH=32
    fi
    
    [ "$LENGTH" -lt 24 ] && LENGTH=24
    
    ALPHABET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    ALPHABET_LEN=52
    
    ALPHANUM='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    ALPHANUM_LEN=62
    
    CHARSET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+'
    CHARSET_LEN=84
    
    if [ -r /dev/urandom ]; then
        RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
        INDEX=$((RANDOM_BYTE % ALPHABET_LEN))
    else
        INDEX=$(($$ % ALPHABET_LEN))
    fi
    PSK="$(echo "$ALPHABET" | cut -c$((INDEX+1)))"
    
    for i in $(seq 2 $((LENGTH - 1))); do
        if [ -r /dev/urandom ]; then
            RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
            INDEX=$((RANDOM_BYTE % CHARSET_LEN))
        else
            INDEX=$(($$ % CHARSET_LEN))
        fi
        PSK="${PSK}$(echo "$CHARSET" | cut -c$((INDEX+1)))"
    done
    
    if [ -r /dev/urandom ]; then
        RANDOM_BYTE=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
        INDEX=$((RANDOM_BYTE % ALPHANUM_LEN))
    else
        INDEX=$(($$ % ALPHANUM_LEN))
    fi
    PSK="${PSK}$(echo "$ALPHANUM" | cut -c$((INDEX+1)))"
    
    echo "$PSK"
}

random_port() {
    echo $((10000 + $(od -An -N2 -i /dev/urandom 2>/dev/null || echo $$) % 55536))
}

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

supports_mode() {
    local major=$(get_major_version)
    [ "$major" -ge 6 ] 2>/dev/null
}

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
    
    if echo "$input" | grep -q ':' && ! echo "$input" | grep -q '^[0-9]\+$'; then
        printf "%s" "$input"
        return
    fi
    
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

# 更新单个配置项
update_config() {
    local key="$1" value="$2"
    if [ -z "$value" ]; then
        sed -i "/^${key} = /d" "$CONFIG_FILE" 2>/dev/null
    elif grep -q "^${key} = " "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s/^${key} = .*/${key} = ${value}/" "$CONFIG_FILE"
    else
        sed -i "/^psk = /a ${key} = ${value}" "$CONFIG_FILE"
    fi
}

# ============================================================
# 主逻辑
# ============================================================

SNELL_VERSION=$(get_snell_version)
MAJOR_VERSION=$(get_major_version)
MINOR_VERSION=$(echo "${SNELL_VERSION#v}" | cut -d. -f2)

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config, creating new configuration..."
    
    # 计算配置值
    if is_v6_or_higher; then
        DNS_IP_PREFERENCE_VAL=${DNS_IP_PREFERENCE:-$(get_dns_ip_preference)}
    else
        DNS_IP_PREFERENCE_VAL=${DNS_IP_PREFERENCE:-$(get_dns_ip_preference)}
        IPV6_VAL=${IPV6:-false}
    fi
    
    # PSK
    if [ -n "$PSK" ]; then
        PSK_VAL="$PSK"
    else
        PSK_VAL=$(random_psk)
    fi
    
    LISTEN_VAL=$(parse_listen "$MAJOR_VERSION" "${LISTEN:-}")
    
    # DNS 配置
    if [ "$MAJOR_VERSION" -ge 4 ] && { [ "$MAJOR_VERSION" -ne 4 ] || [ "$MINOR_VERSION" -ge 1 ]; }; then
        DNS_VAL=${DNS:-$(get_dns_value)}
    else
        DNS_VAL=""
    fi
    
    # Mode 配置
    if supports_mode; then
        MODE_VAL=${MODE:-default}
        case "$MODE_VAL" in
            default|unshaped|unsafe-raw) ;;
            *) MODE_VAL="default" ;;
        esac
    else
        MODE_VAL=""
    fi
    
    # 创建配置文件
    cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${LISTEN_VAL}
psk = ${PSK_VAL}
EOF
    
    [ -n "$DNS_VAL" ] && echo "dns = ${DNS_VAL}" >> "$CONFIG_FILE"
    echo "dns-ip-preference = ${DNS_IP_PREFERENCE_VAL}" >> "$CONFIG_FILE"
    
    if ! is_v6_or_higher; then
        echo "ipv6 = ${IPV6_VAL}" >> "$CONFIG_FILE"
    fi
    
    [ -n "$EGRESS_INTERFACE" ] && echo "egress-interface = ${EGRESS_INTERFACE}" >> "$CONFIG_FILE"
    [ -n "$OBFS" ] && echo "obfs = ${OBFS}" >> "$CONFIG_FILE"
    [ -n "$HOST" ] && echo "host = ${HOST}" >> "$CONFIG_FILE"
    [ -n "$MODE_VAL" ] && echo "mode = ${MODE_VAL}" >> "$CONFIG_FILE"
    
    # 处理 SNELL_ 前缀的扩展配置
    for var in $(env | grep '^SNELL_' | cut -d'=' -f1); do
        key=$(echo "$var" | sed 's/^SNELL_//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        eval "value=\$$var"
        [ -n "$value" ] && echo "${key} = ${value}" >> "$CONFIG_FILE"
    done
    
else
    echo "Existing config found, updating only environment variables..."
    
    # 配置文件已存在，只更新环境变量明确指定的配置项
    
    # 更新 listen
    if [ -n "$LISTEN" ]; then
        LISTEN_VAL=$(parse_listen "$MAJOR_VERSION" "${LISTEN}")
        update_config "listen" "$LISTEN_VAL"
        echo "Updated listen: $LISTEN_VAL"
    fi
    
    # 更新 psk（如果环境变量指定）
    if [ -n "$PSK" ]; then
        update_config "psk" "$PSK"
        echo "Updated psk"
    fi
    
    # 更新 dns（如果环境变量指定）
    if [ -n "$DNS" ]; then
        update_config "dns" "$DNS"
        echo "Updated dns: $DNS"
    fi
    
    # 更新 dns-ip-preference（如果环境变量指定）
    if [ -n "$DNS_IP_PREFERENCE" ]; then
        update_config "dns-ip-preference" "$DNS_IP_PREFERENCE"
        echo "Updated dns-ip-preference: $DNS_IP_PREFERENCE"
    fi
    
    # 更新 egress-interface（如果环境变量指定）
    if [ -n "$EGRESS_INTERFACE" ]; then
        update_config "egress-interface" "$EGRESS_INTERFACE"
        echo "Updated egress-interface: $EGRESS_INTERFACE"
    fi
    
    # 更新 obfs（如果环境变量指定）
    if [ -n "$OBFS" ]; then
        update_config "obfs" "$OBFS"
        echo "Updated obfs: $OBFS"
    fi
    
    # 更新 host（如果环境变量指定）
    if [ -n "$HOST" ]; then
        update_config "host" "$HOST"
        echo "Updated host: $HOST"
    fi
    
    # 更新 mode（如果环境变量指定且版本支持）
    if [ -n "$MODE" ] && supports_mode; then
        MODE_VAL="$MODE"
        case "$MODE_VAL" in
            default|unshaped|unsafe-raw) ;;
            *) MODE_VAL="default" ;;
        esac
        update_config "mode" "$MODE_VAL"
        echo "Updated mode: $MODE_VAL"
    fi
    
    # 处理 SNELL_ 前缀的扩展配置
    for var in $(env | grep '^SNELL_' | cut -d'=' -f1); do
        key=$(echo "$var" | sed 's/^SNELL_//' | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        eval "value=\$$var"
        if [ -n "$value" ]; then
            update_config "$key" "$value"
            echo "Updated $key: $value"
        fi
    done
fi

# 显示配置
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat "$CONFIG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 构建启动命令
CMD="./snell-server -c $CONFIG_FILE"
if [ -n "$LOGLEVEL" ] && validate_loglevel "$LOGLEVEL" 2>/dev/null; then
    CMD="$CMD -l $LOGLEVEL"
fi

# 启动服务
$CMD &
SNELL_PID=$!
wait $SNELL_PID
