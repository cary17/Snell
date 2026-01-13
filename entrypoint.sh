#!/bin/sh
set -e

strip_quotes() {
    echo "$1" | sed "s/^[#\"']\(.*\)[#\"']$/\1/"
}

random_psk() {
    if [ -r /dev/urandom ]; then
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20
        return
    fi
    echo "$(date +%s)$$" | md5sum | cut -c1-20
}

DEFAULT_PORT=$(strip_quotes "${PORT:-20000}")
[ -n "${PSK}" ] && DEFAULT_PSK=$(strip_quotes "${PSK}") || DEFAULT_PSK=$(random_psk)
DEFAULT_IPV6=$(strip_quotes "${IPV6:-false}")
[ -n "${LISTEN}" ] && DEFAULT_LISTEN=$(strip_quotes "${LISTEN}") || DEFAULT_LISTEN=":::${DEFAULT_PORT}"

cat > /snell/snell.conf <<EOF
[snell-server]
listen = ${DEFAULT_LISTEN}
psk = ${DEFAULT_PSK}
ipv6 = ${DEFAULT_IPV6}
EOF

# 环境变量映射
[ -n "${DNS}" ] && echo "dns = $(strip_quotes "${DNS}")" >> /snell/snell.conf
[ -n "${EGRESS_INTERFACE}" ] && echo "egress-interface = $(strip_quotes "${EGRESS_INTERFACE}")" >> /snell/snell.conf
[ -n "${OBFS}" ] && echo "obfs = $(strip_quotes "${OBFS}")" >> /snell/snell.conf
[ -n "${HOST}" ] && echo "host = $(strip_quotes "${HOST}")" >> /snell/snell.conf

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cat /snell/snell.conf
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# exec 确保信号优雅转发 (PID 1)
exec ./snell-server -c /snell/snell.conf -l "${LOG:-notify}"
