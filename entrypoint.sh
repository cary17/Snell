#!/bin/sh

set -e

# 去除变量值中的引号（如果有的话）
strip_quotes() {
    echo "$1" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"
}

# 默认值（去除引号）
DEFAULT_PORT=$(strip_quotes "${PORT:-20000}")

# PSK: 如果未指定则生成随机密码
if [ -n "${PSK}" ]; then
    DEFAULT_PSK=$(strip_quotes "${PSK}")
else
    DEFAULT_PSK=$(openssl rand -base64 16)
    echo "⚠ PSK not specified, generated random PSK: ${DEFAULT_PSK}"
fi

DEFAULT_IPV6=$(strip_quotes "${IPV6:-false}")

# listen 配置
if [ -n "${LISTEN}" ]; then
    DEFAULT_LISTEN=$(strip_quotes "${LISTEN}")
else
    DEFAULT_LISTEN=":::${DEFAULT_PORT}"
fi

# 生成基础配置
cat > /snell/snell.conf <<EOF
[snell-server]
listen = ${DEFAULT_LISTEN}
psk = ${DEFAULT_PSK}
ipv6 = ${DEFAULT_IPV6}
EOF

# 只添加已配置的可选项（不添加空值）
if [ -n "${DNS}" ]; then
    DNS_CLEAN=$(strip_quotes "${DNS}")
    [ -n "${DNS_CLEAN}" ] && echo "dns = ${DNS_CLEAN}" >> /snell/snell.conf
fi

if [ -n "${EGRESS_INTERFACE}" ]; then
    EGRESS_CLEAN=$(strip_quotes "${EGRESS_INTERFACE}")
    [ -n "${EGRESS_CLEAN}" ] && echo "egress-interface = ${EGRESS_CLEAN}" >> /snell/snell.conf
fi

if [ -n "${OBFS}" ]; then
    OBFS_CLEAN=$(strip_quotes "${OBFS}")
    [ -n "${OBFS_CLEAN}" ] && echo "obfs = ${OBFS_CLEAN}" >> /snell/snell.conf
fi

if [ -n "${HOST}" ]; then
    HOST_CLEAN=$(strip_quotes "${HOST}")
    [ -n "${HOST_CLEAN}" ] && echo "host = ${HOST_CLEAN}" >> /snell/snell.conf
fi

echo "Generated snell.conf:"
cat /snell/snell.conf

# 信号处理函数
cleanup() {
    echo "Received shutdown signal, stopping snell-server..."
    if [ -n "$SNELL_PID" ]; then
        kill -TERM "$SNELL_PID" 2>/dev/null || true
        wait "$SNELL_PID" 2>/dev/null || true
    fi
    echo "Snell-server stopped"
    exit 0
}

# 捕获 SIGTERM 和 SIGINT 信号
trap cleanup TERM INT

# 启动 snell-server
echo "Starting snell-server..."
/snell/snell-server -c /snell/snell.conf -l ${LOG:-notify} &
SNELL_PID=$!

echo "Snell-server started with PID $SNELL_PID"

# 等待进程结束
wait $SNELL_PID
