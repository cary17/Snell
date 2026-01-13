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

# 处理核心变量
PORT_VAL=$(strip_quotes "${PORT:-20000}")
[ -n "${PSK}" ] && PSK_VAL=$(strip_quotes "${PSK}") || PSK_VAL=$(random_psk)
IPV6_VAL=$(strip_quotes "${IPV6:-false}")
[ -n "${LISTEN}" ] && LISTEN_VAL=$(strip_quotes "${LISTEN}") || LISTEN_VAL=":::${PORT_VAL}"

# 生成配置
cat > /snell/snell.conf <<EOF
[snell-server]
listen = ${LISTEN_VAL}
psk = ${PSK_VAL}
ipv6 = ${IPV6_VAL}
EOF

# 环境变量映射 (DNS, EGRESS_INTERFACE, OBFS, HOST)
for var in DNS EGRESS_INTERFACE OBFS HOST; do
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