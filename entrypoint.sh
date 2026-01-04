#!/bin/sh

set -e

# 默认值
DEFAULT_PORT="${PORT:-20000}"
DEFAULT_PSK="${PSK:-RgtvOzILQDPBENgzqeZXsw==}"
DEFAULT_IPV6="${IPV6:-false}"
DEFAULT_LISTEN="${LISTEN:-:::${DEFAULT_PORT}}"

# 生成基础配置
cat > /snell/snell.conf <<EOF
[snell-server]
listen = ${DEFAULT_LISTEN}
psk = ${DEFAULT_PSK}
ipv6 = ${DEFAULT_IPV6}
EOF

# 只添加已配置的可选项（不添加空值）
[ -n "${DNS}" ] && echo "dns = ${DNS}" >> /snell/snell.conf
[ -n "${EGRESS_INTERFACE}" ] && echo "egress-interface = ${EGRESS_INTERFACE}" >> /snell/snell.conf
[ -n "${OBFS}" ] && echo "obfs = ${OBFS}" >> /snell/snell.conf
[ -n "${HOST}" ] && echo "host = ${HOST}" >> /snell/snell.conf
[ -n "${TFO}" ] && echo "tfo = ${TFO}" >> /snell/snell.conf

echo "Generated snell.conf:"
cat /snell/snell.conf

# 启动 snell-server，日志级别直接在命令行指定
exec /snell/snell-server -c /snell/snell.conf -l ${LOG:-notify}
