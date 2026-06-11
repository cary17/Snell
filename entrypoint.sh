#!/bin/sh
set -e

# 信号处理：直接传递信号给子进程
trap 'kill -TERM $SNELL_PID 2>/dev/null; wait $SNELL_PID 2>/dev/null' TERM INT

# 去除引号和首尾空格
strip_quotes() {
    echo "$1" | sed -e 's/^[[:space:]"'"'"']//' -e 's/[[:space:]"'"'"']$//'
}

random_psk() {
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
        return
    fi
    echo "$(date +%s)$$" | md5sum | cut -c1-20
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

# 处理 LISTEN 配置（v3 版本）
parse_listen_v3() {
    local input="$1"
    # v3 版本只支持单端口
    local port=$(echo "$input" | grep -oE '[0-9]+' | head -n1)
    if [ -z "$port" ]; then
        port="20000"
    fi
    # v3 版本使用 0.0.0.0:端口 格式
    echo "0.0.0.0:$port"
}

# 处理 LISTEN 配置（v4/v5 版本）
parse_listen_v4() {
    local input="$1"
    # v4/v5 版本只支持单端口，使用 :::端口 格式实现双栈
    local port=$(echo "$input" | grep -oE '[0-9]+' | head -n1)
    if [ -z "$port" ]; then
        port="20000"
    fi
    echo ":::$port"
}

# 处理 LISTEN 配置（v6+ 版本）
parse_listen_v6() {
    local input="$1"
    local result=""
    
    # 如果输入为空，使用默认端口
    if [ -z "$input" ]; then
        echo "0.0.0.0:20000, [::]:20000"
        return
    fi
    
    # 按逗号分割
    IFS=','
    for item in $input; do
        # 去除首尾空格
        item=$(echo "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # 跳过空项
        [ -z "$item" ] && continue
        
        # 检查是否已经是完整地址（包含 : 且不是纯数字）
        if echo "$item" | grep -q ':' && ! echo "$item" | grep -q '^[0-9]\+$'; then
            # 已经是完整地址，直接添加
            [ -n "$result" ] && result="$result, "
            result="${result}${item}"
        else
            # 仅端口号，生成 IPv4 和 IPv6 地址
            [ -n "$result" ] && result="$result, "
            result="${result}0.0.0.0:${item}, [::]:${item}"
        fi
    done
    
    # 如果结果为空（没有有效端口），使用默认值
    if [ -z "$result" ]; then
        result="0.0.0.0:20000, [::]:20000"
    fi
    
    echo "$result"
}

# 主逻辑
[ -n "${PSK}" ] && PSK_VAL=$(strip_quotes "${PSK}") || PSK_VAL=$(random_psk)
IPV6_VAL=$(strip_quotes "${IPV6:-false}")

# 获取 Snell 版本（从文件读取）
SNELL_VERSION=$(get_snell_version)
MAJOR_VERSION=$(get_major_version)
echo "📌 Snell version: $SNELL_VERSION (major: $MAJOR_VERSION)"

# 获取 LISTEN 环境变量
LISTEN_RAW=$(strip_quotes "${LISTEN:-}")
if [ -z "$LISTEN_RAW" ]; then
    echo "ℹ️  LISTEN not set, using default port 20000"
fi

# 根据版本处理 LISTEN
if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
    # v6+ 版本
    echo "🔧 Using Snell v6+ compatible mode (multi-address/multi-port supported)"
    LISTEN_VAL=$(parse_listen_v6 "$LISTEN_RAW")
elif [ "$MAJOR_VERSION" -ge 4 ] 2>/dev/null; then
    # v4/v5 版本
    echo "🔧 Using Snell v4/v5 compatible mode (single port, dual-stack with :::port)"
    LISTEN_VAL=$(parse_listen_v4 "$LISTEN_RAW")
    
    # 检查旧版本是否尝试使用多端口
    if [ -n "$LISTEN_RAW" ] && echo "$LISTEN_RAW" | grep -q ','; then
        echo "⚠️  Warning: Snell v4/v5 only supports single port, using first port only"
    fi
else
    # v3 及以下版本
    echo "🔧 Using Snell v3 compatible mode (single port, IPv4 only)"
    LISTEN_VAL=$(parse_listen_v3 "$LISTEN_RAW")
    
    # 检查旧版本是否尝试使用多端口
    if [ -n "$LISTEN_RAW" ] && echo "$LISTEN_RAW" | grep -q ','; then
        echo "⚠️  Warning: Snell v3 only supports single port, using first port only"
    fi
fi

# 生成配置
cat > /snell/snell.conf <<EOF
[snell-server]
listen = ${LISTEN_VAL}
psk = ${PSK_VAL}
ipv6 = ${IPV6_VAL}
EOF

# 环境变量映射 (DNS, DNS_IP_PREFERENCE, EGRESS_INTERFACE, OBFS, HOST)
for var in DNS DNS_IP_PREFERENCE EGRESS_INTERFACE OBFS HOST; do
    val=$(eval echo "\$$var")
    if [ -n "$val" ]; then
        clean_val=$(strip_quotes "$val")
        key=$(echo "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        echo "$key = $clean_val" >> /snell/snell.conf
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat /snell/snell.conf
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 启动 snell-server
echo "Starting snell-server..."
./snell-server -c /snell/snell.conf -l "${LOG:-notify}" &
SNELL_PID=$!

# 等待子进程退出
wait $SNELL_PID 2>/dev/null
