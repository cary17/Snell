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
    # 从 /dev/urandom 获取随机字节确定长度 (32-64)
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
    
    # 使用 /dev/urandom 生成随机 PSK
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9+/' </dev/urandom | head -c ${LENGTH}
    else
        # 最后回退方案
        echo "$(date +%s%N)$$$(hostname)" | sha256sum | cut -c1-${LENGTH}
    fi
}

# 随机生成端口（10000-65535）
random_port() {
    echo $((10000 + $(od -An -N2 -i /dev/urandom 2>/dev/null || echo $$) % 55536))
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

# 获取完整版本号（用于比较小版本）
get_full_version() {
    VERSION=$(get_snell_version)
    echo "${VERSION#v}"
}

# 处理 LISTEN 配置
parse_listen() {
    local major="$1"
    local input="$2"
    
    # 如果未定义 LISTEN，随机生成端口
    if [ -z "$input" ]; then
        PORT=$(random_port)
        if [ "$major" -ge 6 ] 2>/dev/null; then
            # v6+ 版本使用官方格式
            printf "%s" "0.0.0.0:$PORT, [::]:$PORT"
        else
            # v3/v4/v5 版本使用双栈格式
            printf "%s" ":::$PORT"
        fi
        return
    fi
    
    # 用户自定义了 LISTEN
    # 检查是否已经是完整地址格式（包含 : 且不是纯数字，或者是 ::: 开头）
    if echo "$input" | grep -q ':' && ! echo "$input" | grep -q '^[0-9]\+$'; then
        # 已经是完整地址，直接使用
        printf "%s" "$input"
        return
    fi
    
    # 仅端口号，需要生成完整格式
    # 检查是否包含多个端口（仅 v6+ 支持）
    if echo "$input" | grep -q ','; then
        if [ "$major" -ge 6 ] 2>/dev/null; then
            # v6+ 版本支持多端口，每个端口生成 0.0.0.0:port, [::]:port 格式
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
            # v6 以下版本不支持多端口，只使用第一个端口并给出警告
            local port=$(echo "$input" | grep -oE '[0-9]+' | head -n1)
            echo "⚠️  Warning: Snell v${major} only supports single port, using first port only: $port" >&2
            printf "%s" ":::$port"
        fi
    else
        # 单端口
        if [ "$major" -ge 6 ] 2>/dev/null; then
            # v6+ 版本使用官方格式
            printf "%s" "0.0.0.0:${input}, [::]:${input}"
        else
            # v3/v4/v5 版本使用双栈格式
            printf "%s" ":::${input}"
        fi
    fi
}

# 检查配置文件是否已存在
CONFIG_FILE="/snell/snell.conf"

if [ -f "$CONFIG_FILE" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Existing configuration found, using it"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat "$CONFIG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📝 Generating new configuration..."
    
    # 主逻辑
    SNELL_VERSION=$(get_snell_version)
    FULL_VERSION=$(get_full_version)
    MAJOR_VERSION=$(get_major_version)
    MINOR_VERSION=$(echo "$FULL_VERSION" | cut -d. -f2)
    
    # 1. 处理 DNS_IP_PREFERENCE 和 IPV6 的联动（v6+ 才有效）
    if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
        # 获取 DNS_IP_PREFERENCE 值（默认 prefer-ipv4）
        if [ -n "${DNS_IP_PREFERENCE}" ]; then
            DNS_IP_PREFERENCE_VAL=$(strip_quotes "${DNS_IP_PREFERENCE}")
        else
            DNS_IP_PREFERENCE_VAL="prefer-ipv4"
        fi
        
        # 根据 DNS_IP_PREFERENCE 判断是否启用 IPv6（仅用于 DNS 选择，不写入配置文件）
        case "$DNS_IP_PREFERENCE_VAL" in
            ipv4-only)
                IPV6_ENABLED="false"
                ;;
            default|prefer-ipv4|prefer-ipv6|ipv6-only)
                IPV6_ENABLED="true"
                ;;
            *)
                IPV6_ENABLED="true"
                ;;
        esac
    else
        # v6 以下版本，需要写入 ipv6 配置项
        DNS_IP_PREFERENCE_VAL=""
        if [ -n "${IPV6}" ]; then
            IPV6_VAL=$(strip_quotes "${IPV6}")
        else
            IPV6_VAL="false"
        fi
        IPV6_ENABLED="$IPV6_VAL"
    fi
    
    # 2. 处理 PSK
    if [ -n "${PSK}" ]; then
        PSK_VAL=$(strip_quotes "${PSK}")
    else
        PSK_VAL=$(random_psk)
    fi
    
    # 3. 处理 LISTEN
    LISTEN_VAL=$(parse_listen "$MAJOR_VERSION" "$(strip_quotes "${LISTEN:-}")")
    
    # 4. 处理 DNS（根据 IPV6_ENABLED 和 DNS_IP_PREFERENCE 决定）
    # DNS 支持从 v4.1.0 开始
    if [ "$MAJOR_VERSION" -eq 4 ] && [ "$MINOR_VERSION" -lt 1 ]; then
        DNS_VAL=""
    elif [ "$MAJOR_VERSION" -lt 4 ]; then
        DNS_VAL=""
    else
        if [ -n "${DNS}" ]; then
            # 用户自定义 DNS
            DNS_VAL=$(strip_quotes "${DNS}")
        else
            # 根据 DNS_IP_PREFERENCE 和 IPV6_ENABLED 自动选择默认 DNS
            if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
                case "$DNS_IP_PREFERENCE_VAL" in
                    ipv6-only)
                        DNS_VAL="2001:4860:4860::8888, 2606:4700:4700::1111"
                        ;;
                    ipv4-only)
                        DNS_VAL="8.8.8.8, 1.1.1.1"
                        ;;
                    default|prefer-ipv4|prefer-ipv6)
                        if [ "$IPV6_ENABLED" = "true" ]; then
                            DNS_VAL="8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
                        else
                            DNS_VAL="8.8.8.8, 1.1.1.1"
                        fi
                        ;;
                    *)
                        DNS_VAL="8.8.8.8, 1.1.1.1"
                        ;;
                esac
            else
                # v3/v4/v5 版本
                if [ "$IPV6_ENABLED" = "true" ]; then
                    DNS_VAL="8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
                else
                    DNS_VAL="8.8.8.8, 1.1.1.1"
                fi
            fi
        fi
    fi
    
    # 5. 处理 EGRESS_INTERFACE（v5 开始支持）
    if [ "$MAJOR_VERSION" -ge 5 ] 2>/dev/null; then
        if [ -n "${EGRESS_INTERFACE}" ]; then
            EGRESS_INTERFACE_VAL=$(strip_quotes "${EGRESS_INTERFACE}")
        else
            EGRESS_INTERFACE_VAL=""
        fi
    else
        EGRESS_INTERFACE_VAL=""
    fi
    
    # 6. 处理 OBFS 和 HOST（v6 及以上版本不支持）
    if [ "$MAJOR_VERSION" -lt 6 ] 2>/dev/null; then
        # v5 及以下版本支持 OBFS 和 HOST
        if [ -n "${OBFS}" ]; then
            OBFS_VAL=$(strip_quotes "${OBFS}")
        else
            OBFS_VAL=""
        fi
        
        if [ -n "${HOST}" ]; then
            HOST_VAL=$(strip_quotes "${HOST}")
        else
            HOST_VAL=""
        fi
    else
        # v6+ 版本不支持 OBFS 和 HOST
        OBFS_VAL=""
        HOST_VAL=""
    fi
    
    # 生成配置文件
    cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = ${LISTEN_VAL}
psk = ${PSK_VAL}
EOF
    
    # v6 以下版本才写入 ipv6 配置项
    if [ "$MAJOR_VERSION" -lt 6 ] 2>/dev/null; then
        echo "ipv6 = ${IPV6_VAL}" >> "$CONFIG_FILE"
    fi
    
    # 添加 DNS（如果支持且有值）
    if [ -n "$DNS_VAL" ]; then
        echo "dns = $DNS_VAL" >> "$CONFIG_FILE"
    fi
    
    # 添加 DNS_IP_PREFERENCE（v6+ 且有值）
    if [ -n "$DNS_IP_PREFERENCE_VAL" ]; then
        echo "dns-ip-preference = $DNS_IP_PREFERENCE_VAL" >> "$CONFIG_FILE"
    fi
    
    # 添加 EGRESS_INTERFACE（如果有值）
    if [ -n "$EGRESS_INTERFACE_VAL" ]; then
        echo "egress-interface = $EGRESS_INTERFACE_VAL" >> "$CONFIG_FILE"
    fi
    
    # 添加 OBFS（仅 v5 及以下版本且如果有值）
    if [ -n "$OBFS_VAL" ]; then
        echo "obfs = $OBFS_VAL" >> "$CONFIG_FILE"
    fi
    
    # 添加 HOST（仅 v5 及以下版本且如果有值）
    if [ -n "$HOST_VAL" ]; then
        echo "host = $HOST_VAL" >> "$CONFIG_FILE"
    fi
    
    # 显示新生成的配置文件内容
    cat "$CONFIG_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# 启动 snell-server
./snell-server -c "$CONFIG_FILE" &
SNELL_PID=$!

# 等待子进程退出
wait $SNELL_PID 2>/dev/null
