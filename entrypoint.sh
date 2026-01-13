#!/bin/sh
set -e

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

# exec 启动，确保程序作为 PID 1 运行，从而能处理 SIGTERM/SIGINT
echo "Starting snell-server..."
exec ./snell-server -c /snell/snell.conf -l "${LOG:-notify}"
