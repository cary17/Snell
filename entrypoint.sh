#!/bin/sh
set -e

# 增强型：去除前导/尾随空格、单引号、双引号
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

# 基础配置处理
PORT_CLEAN=$(strip_quotes "${PORT:-20000}")
[ -n "${PSK}" ] && PSK_CLEAN=$(strip_quotes "${PSK}") || PSK_CLEAN=$(random_psk)
IPV6_CLEAN=$(strip_quotes "${IPV6:-false}")
[ -n "${LISTEN}" ] && LISTEN_CLEAN=$(strip_quotes "${LISTEN}") || LISTEN_CLEAN=":::${PORT_CLEAN}"

cat > /snell/snell.conf <<EOF
[snell-server]
listen = ${LISTEN_CLEAN}
psk = ${PSK_CLEAN}
ipv6 = ${IPV6_CLEAN}
EOF

# 环境变量动态映射
for var in DNS EGRESS_INTERFACE OBFS HOST; do
    # 获取环境变量值
    val=$(eval echo "\$$var")
    if [ -n "$val" ]; then
        clean_val=$(strip_quotes "$val")
        # 将变量名转换为 snell.conf 的 key (如 EGRESS_INTERFACE -> egress-interface)
        key=$(echo "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        echo "$key = $clean_val" >> /snell/snell.conf
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat /snell/snell.conf
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 使用 exec 确保 snell-server 捕获 SIGTERM/SIGINT
echo "Starting snell-server (PID 1)..."
exec ./snell-server -c /snell/snell.conf -l "${LOG:-notify}"
