#!/bin/sh
set -e

# 去除变量值中的引号
strip_quotes() {
    echo "$1" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"
}

# 生成随机密码
random_psk() {
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
        return
    fi
    echo "$(date +%s)$$" | md5sum | cut -c1-20
}

# 变量处理
DEFAULT_PORT=$(strip_quotes "${PORT:-20000}")

if [ -n "${PSK}" ]; then
    DEFAULT_PSK=$(strip_quotes "${PSK}")
else
    DEFAULT_PSK=$(random_psk)
    echo "⚠️  PSK not specified, generated random PSK: ${DEFAULT_PSK}"
fi

DEFAULT_IPV6=$(strip_quotes "${IPV6:-false}")

if [ -n "${LISTEN}" ]; then
    DEFAULT_LISTEN=$(strip_quotes "${LISTEN}")
else
    DEFAULT_LISTEN=":::${DEFAULT_PORT}"
fi

# 生成配置
cat > /snell/snell.conf <<EOF
[snell-server]
listen = ${DEFAULT_LISTEN}
psk = ${DEFAULT_PSK}
ipv6 = ${DEFAULT_IPV6}
EOF

# 可选项处理
[ -n "${DNS}" ] && echo "dns = $(strip_quotes "${DNS}")" >> /snell/snell.conf
[ -n "${EGRESS_INTERFACE}" ] && echo "egress-interface = $(strip_quotes "${EGRESS_INTERFACE}")" >> /snell/snell.conf
[ -n "${OBFS}" ] && echo "obfs = $(strip_quotes "${OBFS}")" >> /snell/snell.conf
[ -n "${HOST}" ] && echo "host = $(strip_quotes "${HOST}")" >> /snell/snell.conf

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Generated snell.conf:"
cat /snell/snell.conf
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 启动 snell-server
# 使用 exec 使其成为 PID 1，从而能捕获并优雅处理 SIGTERM/SIGINT 信号
echo "Starting snell-server..."
exec /snell/snell-server -c /snell/snell.conf -l "${LOG:-notify}"
