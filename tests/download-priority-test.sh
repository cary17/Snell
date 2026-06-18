#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$1"
}

if grep -q 'MAJOR_VERSION" = "3"' "$ROOT_DIR/Dockerfile"; then
    fail "Dockerfile should not prefer Version/ backup for v3"
fi
pass "Dockerfile has no v3 local-first special case"

if ! grep -q 'curl -4 .*OFFICIAL_URL' "$ROOT_DIR/Dockerfile"; then
    fail "Dockerfile should try official download over IPv4 first"
fi
pass "Dockerfile tries official IPv4 download first"

if ! grep -q 'curl -6 .*OFFICIAL_URL' "$ROOT_DIR/Dockerfile"; then
    fail "Dockerfile should try official download over IPv6 before backup"
fi
pass "Dockerfile tries official IPv6 before backup"

if grep -q 'no local backup' "$ROOT_DIR/.github/workflows/build.yml"; then
    fail "workflow should allow Version/ backup for beta/future versions too"
fi
pass "workflow does not exclude beta/future versions from backup fallback"
