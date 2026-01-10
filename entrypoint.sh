#!/bin/sh
set -e

# 去除变量值中的引号（如果有的话）
strip_quotes() {
    echo "$1" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"
}

# 生成随机密码（使用更安全的方式）
random_psk() {
    # 方法1: 使用 /dev/urandom
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
        return
    fi
    
    # 方法2: 使用 openssl（如果安装了）
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 16 | tr -d '=' | head -c 20
        return
    fi
    
    # 方法3: 使用时间戳和进程ID（最后的备选）
    echo "$(date +%s)$$" | md5sum | cut -c1-20
}

# 默认值（去除引号）
DEFAULT_PORT=$(strip_quotes "${PORT:-20000}")

# PSK: 如果未指定则生成随机密码
if [ -n "${PSK}" ]; then
    DEFAULT_PSK=$(strip_quotes "${PSK}")
else
    DEFAULT_PSK=$(random_psk)
    echo "⚠️  PSK not specified, generated random PSK: ${DEFAULT_PSK}"
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

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Generated snell.conf:"
cat /snell/snell.conf
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 启动 snell-server（使用 exec 让其成为 PID 1 的子进程）
# tini 会自动处理信号转发，所以我们直接 exec
echo "Starting snell-server..."
exec /snell/snell-server -c /snell/snell.conf -l "${LOG:-notify}"
