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

# 处理 LISTEN 配置
# 支持格式：
# 1. 仅端口: "25169" -> "0.0.0.0:25169, [::]:25169"
# 2. 多个端口: "25169, 12121" -> "0.0.0.0:25169, [::]:25169, 0.0.0.0:12121, [::]:12121"
# 3. 完整地址: "0.0.0.0:20001, [::]:20001" -> 直接使用
# 4. 混合: "0.0.0.0:20001, 12121" -> "0.0.0.0:20001, 0.0.0.0:12121, [::]:12121"
parse_listen() {
    local input="$1"
    local result=""
    
    # 按逗号分割
    IFS=','
    for item in $input; do
        # 去除首尾空格
        item=$(echo "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
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
    
    echo "$result"
}

# 处理核心变量
PORT_VAL=$(strip_quotes "${PORT:-}")
[ -n "${PSK}" ] && PSK_VAL=$(strip_quotes "${PSK}") || PSK_VAL=$(random_psk)
IPV6_VAL=$(strip_quotes "${IPV6:-false}")

# 处理 LISTEN（优先级最高）
if [ -n "${LISTEN}" ]; then
    LISTEN_RAW=$(strip_quotes "${LISTEN}")
    LISTEN_VAL=$(parse_listen "$LISTEN_RAW")
else
    # 没有设置 LISTEN 时，使用 PORT 配置（兼容旧版本）
    if [ -n "$PORT_VAL" ]; then
        # 使用 PORT 配置，生成 IPv4 和 IPv6 地址
        LISTEN_VAL="0.0.0.0:${PORT_VAL}, [::]:${PORT_VAL}"
    else
        # 默认配置
        LISTEN_VAL="0.0.0.0:20000, [::]:20000"
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
