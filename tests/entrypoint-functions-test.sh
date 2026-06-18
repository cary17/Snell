#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

sed '/^SNELL_VERSION=$(get_snell_version)/,$d' "$ROOT_DIR/entrypoint.sh" > "$TMP_DIR/functions.sh"
# shellcheck source=/dev/null
. "$TMP_DIR/functions.sh"

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$actual" != "$expected" ]; then
        printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
        exit 1
    fi

    printf 'ok - %s\n' "$name"
}

assert_eq \
    "v6 expands one port to IPv4 and IPv6 listeners" \
    "0.0.0.0:20000, [::]:20000" \
    "$(parse_listen 6 "20000")"

assert_eq \
    "v6 expands comma-separated ports to dual-stack listeners" \
    "0.0.0.0:20000, [::]:20000, 0.0.0.0:20001, [::]:20001" \
    "$(parse_listen 6 "20000, 20001")"

assert_eq \
    "v5 uses only the first port from a comma-separated listen value" \
    ":::20000" \
    "$(parse_listen 5 "20000, 20001")"

assert_eq \
    "explicit listen address is preserved" \
    "0.0.0.0:20000,[::]:20000" \
    "$(parse_listen 6 "0.0.0.0:20000,[::]:20000")"

CONFIG_FILE="$TMP_DIR/snell.conf"
cat > "$CONFIG_FILE" <<'EOF'
[snell-server]
listen = 0.0.0.0:20000, [::]:20000
psk = generated-secret
EOF

assert_eq \
    "config log includes psk for users relying on docker logs" \
    "[snell-server]
listen = 0.0.0.0:20000, [::]:20000
psk = generated-secret" \
    "$(show_config)"
