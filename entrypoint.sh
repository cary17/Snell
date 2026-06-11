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

# 获取 Snell 版本
get_snell_version() {
    local version=$("./snell-server" -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    echo "$version"
}

# 比较版本号（返回值：0 表示 v1 <= v2）
version_le() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# 处理 LISTEN 配置（v6 以下版本）
parse_listen_v4() {
    local input="$1"
    # v4 版本只支持单端口，提取第一个数字
    local port=$(echo "$input" | grep -oE '[0-9]+' | head -n1)
    if [ -z "$port" ]; then
        port="20000"
    fi
    # v4 版本使用 :::端口 格式实现双栈监听
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

# 获取 LISTEN 环境变量
LISTEN_RAW=$(strip_quotes "${LISTEN:-}")
if [ -z "$LISTEN_RAW" ]; then
    echo "ℹ️  LISTEN not set, using default port 20000"
fi

# 获取 Snell 版本
SNELL_VERSION=$(get_snell_version)
echo "📌 Snell version: $SNELL_VERSION"

# 根据版本处理 LISTEN
if [ -z "$SNELL_VERSION" ] || version_le "$SNELL_VERSION" "6.0.0"; then
    # v6 以下版本
    echo "🔧 Using Snell v4 compatible mode (single port only)"
    LISTEN_VAL=$(parse_listen_v4 "$LISTEN_RAW")
    
    # 检查 v4 版本是否尝试使用多端口
    if [ -n "$LISTEN_RAW" ] && echo "$LISTEN_RAW" | grep -q ','; then
        echo "⚠️  Warning: Snell v4 only supports single port, using first port only"
    fi
else
    # v6+ 版本
    echo "🔧 Using Snell v6+ compatible mode (multi-address/multi-port supported)"
    LISTEN_VAL=$(parse_listen_v6 "$LISTEN_RAW")
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
