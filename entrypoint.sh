#!/bin/sh

# Snell v5 ignores Docker SIGTERM as PID 1; keep a forwarding parent and reap it.
cleanup() {
    if [ -n "${SNELL_PID:-}" ]; then
        kill -TERM "$SNELL_PID" 2>/dev/null || true
        wait "$SNELL_PID" 2>/dev/null || true
    fi
    exit 143
}

# ============================================================
# Random generation
# ============================================================

random_byte() {
    if [ -r /dev/urandom ]; then
        byte=$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' ')
    else
        byte=$$
    fi
    printf '%s\n' "${byte:-0}"
}

random_index() {
    index_length=$1
    index_limit=$((65536 - (65536 % index_length)))

    while :; do
        value=$(($(random_byte) * 256 + $(random_byte)))
        if [ "$value" -lt "$index_limit" ] 2>/dev/null; then
            printf '%s\n' $((value % index_length))
            return
        fi
    done
}

# Generate a random single-line PSK with a 16-180 byte Base64 length.
random_psk() {
    while :; do
        byte_count=$((12 + $(random_index 124)))
        value=$(openssl rand --base64 "$byte_count" | tr -d '\r\n')
        length=${#value}
        if [ "$length" -ge 16 ] && [ "$length" -le 180 ]; then
            printf '%s\n' "$value"
            return
        fi
    done
}

random_port() {
    min_port=${1:-10000}
    max_port=${2:-65535}
    port_span=$((max_port - min_port + 1))
    printf '%s\n' $((min_port + $(random_index "$port_span")))
}

validate_loglevel() {
    case "$1" in
        trace|verbose|info|notify|warning|error) return 0 ;;
        *) return 1 ;;
    esac
}

validate_psk() {
    value=$1
    length=$(LC_ALL=C printf '%s' "$value" | LC_ALL=C wc -c)
    [ "$length" -ge 16 ] && [ "$length" -le 180 ] || return 1
    case "$value" in *[!A-Za-z0-9._+=/-]*) return 1 ;; esac
}

validate_dns() { case "$1" in *[!A-Za-z0-9:.,\ _-]*) return 1 ;; esac; }
validate_interface() { case "$1" in *[!A-Za-z0-9_.:-]*) return 1 ;; esac; }
validate_host() { case "$1" in *[!A-Za-z0-9.-]*) return 1 ;; esac; }

sanitize_obfs_host() {
    runtime_obfs=${OBFS:-}
    runtime_host=${HOST:-}
    if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
        [ -z "$runtime_obfs$runtime_host" ] || echo "Warning: ignoring OBFS/HOST because Snell v6+ does not define these settings; use MODE instead." >&2
        unset OBFS HOST
        return
    fi

    case "$MAJOR_VERSION:$runtime_obfs" in
        3:http|3:tls|4:http|5:http) ;;
        *:|*:none) unset OBFS HOST; return ;;
        *) echo "Warning: ignoring unsupported OBFS=$runtime_obfs and HOST." >&2; unset OBFS HOST; return ;;
    esac
    if [ -z "$runtime_host" ] || ! validate_host "$runtime_host"; then
        echo "Warning: ignoring OBFS/HOST because HOST is missing or invalid." >&2
        unset OBFS HOST
    fi
}

# ============================================================
# Network probing and DNS generation
# ============================================================

test_connectivity() {
    nc -z -w 2 "$1" "${2:-80}" 2>/dev/null
}

test_google() {
    test_connectivity "google.com" 80
}

test_domestic() {
    test_connectivity "baidu.com" 80 || test_connectivity "aliyun.com" 80
}

get_network_type() {
    test_google && echo "international" && return
    test_domestic && echo "domestic" && return
    echo "none"
}

test_ipv4() {
    for ip in 8.8.8.8 1.1.1.1 119.29.29.29 223.5.5.5; do
        test_connectivity "$ip" 53 && return 0
    done
    return 1
}

test_ipv6() {
    for ip in 2001:4860:4860::8888 2606:4700:4700::1111 2402:4e00:: 2400:3200::1; do
        test_connectivity "$ip" 53 && return 0
    done
    return 1
}

get_dns_value() {
    network_type=$(get_network_type)
    ipv4_ok=false; test_ipv4 && ipv4_ok=true
    ipv6_ok=false; test_ipv6 && ipv6_ok=true
    
    case "$network_type" in
        none)
            echo "8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
            ;;
        domestic)
            if $ipv4_ok && $ipv6_ok; then
                echo "119.29.29.29, 223.5.5.5, 2402:4e00::, 2400:3200::1"
            elif $ipv4_ok; then
                echo "119.29.29.29, 223.5.5.5"
            else
                echo "2402:4e00::, 2400:3200::1"
            fi
            ;;
        international)
            if $ipv4_ok && $ipv6_ok; then
                echo "8.8.8.8, 1.1.1.1, 2001:4860:4860::8888, 2606:4700:4700::1111"
            elif $ipv4_ok; then
                echo "8.8.8.8, 1.1.1.1"
            else
                echo "2001:4860:4860::8888, 2606:4700:4700::1111"
            fi
            ;;
    esac
}

get_dns_ip_preference() {
    network_type=$(get_network_type)
    ipv4_ok=false; test_ipv4 && ipv4_ok=true
    ipv6_ok=false; test_ipv6 && ipv6_ok=true
    
    case "$network_type" in
        none) echo "prefer-ipv4" ;;
        *)
            if $ipv4_ok && $ipv6_ok; then
                echo "prefer-ipv4"
            elif $ipv6_ok; then
                echo "prefer-ipv6"
            else
                echo "prefer-ipv4"
            fi
            ;;
    esac
}

# ============================================================
# Snell version helpers
# ============================================================

get_major_version() {
    cat /snell/snell-major-version 2>/dev/null || echo "0"
}

ipv6_from_dns_preference() {
    case "${1:-default}" in
        prefer-ipv4|ipv4-only) printf 'false\n' ;;
        prefer-ipv6|ipv6-only) printf 'true\n' ;;
        default|'') return 1 ;;
        *) return 1 ;;
    esac
}

IPV6_CONFLICT_PREPARED=0
EFFECTIVE_DNS_IP_PREFERENCE=""
EFFECTIVE_IPV6=""

prepare_ipv6_configuration() {
    [ "$IPV6_CONFLICT_PREPARED" = 1 ] && return 0
    [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null || return 0
    IPV6_CONFLICT_PREPARED=1

    raw_ipv6=$(printenv IPV6 2>/dev/null || true)
    raw_dns_pref=$(printenv DNS_IP_PREFERENCE 2>/dev/null || true)
    case "$raw_ipv6" in true|false|'') ;; *) echo "Warning: invalid IPV6=$raw_ipv6; using the generated default." >&2; raw_ipv6="" ;; esac
    case "$raw_dns_pref" in default|prefer-ipv4|prefer-ipv6|ipv4-only|ipv6-only|'') ;; *) echo "Warning: invalid DNS_IP_PREFERENCE=$raw_dns_pref; using default." >&2; raw_dns_pref=default ;; esac

    EFFECTIVE_IPV6="$raw_ipv6"
    EFFECTIVE_DNS_IP_PREFERENCE="$raw_dns_pref"
    derived_ipv6=$(ipv6_from_dns_preference "$raw_dns_pref" || true)
    if [ -z "$raw_ipv6" ]; then
        EFFECTIVE_IPV6="$derived_ipv6"
        return 0
    fi
    [ -n "$derived_ipv6" ] || return 0
    [ "$raw_ipv6" = "$derived_ipv6" ] && return 0

    echo "Warning: preserving conflicting IPV6=$raw_ipv6 and DNS_IP_PREFERENCE=$raw_dns_pref at container runtime." >&2
    echo "Use Snell.sh to resolve and persist consistent .env/Compose values." >&2
    return 0
}

# ============================================================
# Listen value parsing
# ============================================================

validate_listen_input() {
    case "$1" in *'
'*) return 1 ;; esac
    printf '%s\n' "$1" | awk -v min="${2:-10000}" -v max="${3:-65535}" '
        function ipv4(address, parts, n, i) {
            n = split(address, parts, ".")
            if (n != 4) return 0
            for (i = 1; i <= n; i++)
                if (parts[i] !~ /^[0-9]+$/ || length(parts[i]) > 3 || parts[i] + 0 > 255) return 0
            return 1
        }
        function ipv6(address, parts, n, i, count, compressed, copy) {
            if (address !~ /^[0-9A-Fa-f:]+$/ || address ~ /:::/) return 0
            copy = address
            compressed = gsub(/::/, "", copy)
            if (compressed > 1) return 0
            if (!compressed && (address ~ /^:/ || address ~ /:$/)) return 0
            if (address ~ /^:[^:]/ || address ~ /[^:]:$/) return 0
            n = split(address, parts, ":")
            count = 0
            for (i = 1; i <= n; i++) {
                if (length(parts[i]) > 4) return 0
                if (parts[i] != "") count++
            }
            return compressed ? count < 8 : count == 8
        }
        {
            n = split($0, endpoints, ",")
            for (i = 1; i <= n; i++) {
                endpoint = endpoints[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", endpoint)
                port = endpoint
                if (endpoint ~ /^\[.*\]:[0-9]+$/) {
                    address = endpoint
                    sub(/^\[/, "", address); sub(/\]:[0-9]+$/, "", address)
                    if (!ipv6(address)) exit 1
                    sub(/^.*:/, "", port)
                } else if (endpoint ~ /^:::[0-9]+$/) {
                    sub(/^:::/, "", port)
                } else if (endpoint ~ /^[0-9.]+:[0-9]+$/) {
                    address = endpoint; sub(/:[0-9]+$/, "", address)
                    if (!ipv4(address)) exit 1
                    sub(/^.*:/, "", port)
                }
                if (port !~ /^[0-9]+$/ || port + 0 < min || port + 0 > max) exit 1
            }
            if (!n) exit 1
        }
    '
}

parse_listen() {
    major="$1"
    input="$2"
    min_port="${3:-10000}"
    max_port="${4:-65535}"
    
    if [ -z "$input" ]; then
        PORT=$(random_port "$min_port" "$max_port")
        if [ "$major" -ge 6 ] 2>/dev/null; then
            printf '0.0.0.0:%s, [::]:%s' "$PORT" "$PORT"
        else
            printf ':::%s' "$PORT"
        fi
        return
    fi
    
    printf '%s\n' "$input" | awk -v major="$major" '
        {
            n = split($0, endpoints, ",")
            for (i = 1; i <= n; i++) {
                endpoint = endpoints[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", endpoint)
                if (i > 1) printf ", "
                if (index(endpoint, ":")) printf "%s", endpoint
                else if (major >= 6) printf "0.0.0.0:%s, [::]:%s", endpoint, endpoint
                else printf ":::%s", endpoint
                if (major < 6) break
            }
        }
    '
}

show_config() {
    cat "$CONFIG_FILE"
}

get_config_meta() {
    item=$1
    field=$2
    item_key=$(printf '%s\n' "$item" | tr '-' '_')
    eval "printf '%s\n' \"\${CONFIG_${item_key}_${field}:-}\""
}

is_allowed_value() {
    value=$1
    allowed=$2

    [ -z "$allowed" ] && return 0

    OLD_IFS="$IFS"
    IFS='|'
    for candidate in $allowed; do
        IFS="$OLD_IFS"
        [ "$value" = "$candidate" ] && return 0
        IFS='|'
    done
    IFS="$OLD_IFS"
    return 1
}

generated_config_value() {
    item=$1
    generator=$2
    default_value=$3

    if [ "$generator" != "ipv6" ] && [ -n "$default_value" ]; then
        printf '%s\n' "$default_value"
        return
    fi

    case "$generator" in
        listen)
            min_port=$(get_config_meta "$item" PORT_MIN)
            max_port=$(get_config_meta "$item" PORT_MAX)
            parse_listen "$MAJOR_VERSION" "" "${min_port:-10000}" "${max_port:-65535}"
            ;;
        psk)
            random_psk
            ;;
        dns)
            get_dns_value
            ;;
        dns_ip_preference)
            get_dns_ip_preference
            ;;
        ipv6)
            if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null; then
                ipv6_from_dns_preference "${EFFECTIVE_DNS_IP_PREFERENCE:-${DNS_IP_PREFERENCE:-default}}"
            else
                printf '%s\n' "${default_value:-false}"
            fi
            ;;
        "")
            return 1
            ;;
        *)
            echo "Unknown generator for ${item}: ${generator}" >&2
            return 1
            ;;
    esac
}

normalize_config_value() {
    item=$1
    value=$2

    case "$item" in
        listen)
            min_port=$(get_config_meta "$item" PORT_MIN)
            max_port=$(get_config_meta "$item" PORT_MAX)
            validate_listen_input "$value" "${min_port:-10000}" "${max_port:-65535}" || {
                echo "Invalid LISTEN value: $value" >&2
                return 2
            }
            parse_listen "$MAJOR_VERSION" "$value" "${min_port:-10000}" "${max_port:-65535}"
            ;;
        psk)
            validate_psk "$value" || { echo "Invalid PSK: expected 16-180 safe ASCII bytes" >&2; return 2; }
            printf '%s\n' "$value"
            ;;
        dns)
            validate_dns "$value" || { echo "Invalid DNS value" >&2; return 2; }
            printf '%s\n' "$value"
            ;;
        egress-interface)
            validate_interface "$value" || { echo "Invalid EGRESS_INTERFACE value" >&2; return 2; }
            printf '%s\n' "$value"
            ;;
        host)
            validate_host "$value" || { echo "Invalid HOST value" >&2; return 2; }
            printf '%s\n' "$value"
            ;;
        *)
            printf '%s\n' "$value"
            ;;
    esac
}

resolve_config_value() {
    item=$1
    env_name=$(get_config_meta "$item" ENV)
    enabled=$(get_config_meta "$item" ENABLED)
    default_value=$(get_config_meta "$item" DEFAULT)
    generator=$(get_config_meta "$item" GENERATOR)
    allowed=$(get_config_meta "$item" ALLOWED)

    if [ "$IPV6_CONFLICT_PREPARED" = 1 ] && [ "$item" = "dns-ip-preference" ]; then
        env_value="$EFFECTIVE_DNS_IP_PREFERENCE"
    elif [ "$IPV6_CONFLICT_PREPARED" = 1 ] && [ "$item" = "ipv6" ]; then
        env_value="$EFFECTIVE_IPV6"
    else
        env_value=$(printenv "$env_name" 2>/dev/null || true)
    fi
    if [ -n "$env_value" ]; then
        value=$env_value
    elif [ "$enabled" = "true" ]; then
        value=$(generated_config_value "$item" "$generator" "$default_value" || true)
    else
        value=""
    fi

    [ -n "$value" ] || return 3
    if ! value=$(normalize_config_value "$item" "$value"); then
        if [ -n "$env_value" ]; then
            if [ "$env_name" = PSK ]; then
                echo "Warning: invalid PSK; using a generated default." >&2
            else
                echo "Warning: invalid ${env_name}=${env_value}; using the default behavior." >&2
            fi
            if [ "$enabled" = true ]; then
                value=$(generated_config_value "$item" "$generator" "$default_value" || true)
                [ -n "$value" ] || return 3
                value=$(normalize_config_value "$item" "$value") || return 2
            else
                return 3
            fi
        else
            return 2
        fi
    fi

    if ! is_allowed_value "$value" "$allowed"; then
        if [ -n "$default_value" ] && is_allowed_value "$default_value" "$allowed"; then
            value=$default_value
            [ -n "$env_value" ] && echo "Warning: invalid ${env_name}=${env_value}; using ${default_value}." >&2
        elif [ -n "$env_value" ] && [ "$enabled" != true ]; then
            echo "Warning: invalid ${env_name}=${env_value}; ignoring this optional setting." >&2
            return 3
        else
            echo "Invalid value for ${env_name}: ${value}" >&2
            return 2
        fi
    fi

    [ "$item" = "dns-ip-preference" ] && [ "$value" = "default" ] && return 3

    printf '%s\n' "$value"
}

write_config_items() {
    prepare_ipv6_configuration || return 1
    sanitize_obfs_host
    for item in $CONFIG_ITEM_NAMES; do
        key=$item
        if value=$(resolve_config_value "$item"); then
            if [ "$MAJOR_VERSION" -ge 6 ] 2>/dev/null && { [ "$item" = obfs ] || [ "$item" = host ]; }; then
                echo "Ignoring unsupported ${key} for Snell v6+" >&2
                continue
            fi
            echo "${key} = ${value}"
        else
            status=$?
            [ "$status" -eq 3 ] || return "$status"
        fi
    done
}

# ============================================================
# Main
# ============================================================

main() {
    MAJOR_VERSION=$(get_major_version)
    CONFIG_FILE="/snell/snell.conf"
    CONFIG_ITEMS_FILE="/snell/config-items.sh"

    if [ -r "$CONFIG_ITEMS_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_ITEMS_FILE"
    else
        echo "Missing config metadata: $CONFIG_ITEMS_FILE" >&2
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No existing config, creating new configuration..."
        temp_config=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || exit 1
        if ! {
            echo "[snell-server]"
            write_config_items
        } > "$temp_config"; then
            rm -f "$temp_config"
            exit 1
        fi
        mv -f "$temp_config" "$CONFIG_FILE" || { rm -f "$temp_config"; exit 1; }

        # Show generated configuration.
        echo "----------------------------------------"
        show_config
        echo "----------------------------------------"

    else
        echo "Existing config found, using it as-is..."

        # Show existing configuration.
        echo "----------------------------------------"
        show_config
        echo "----------------------------------------"
    fi

    set -- ./snell-server -c "$CONFIG_FILE"
    if [ -n "${LOGLEVEL:-}" ]; then
        if validate_loglevel "$LOGLEVEL" 2>/dev/null; then
            echo "Using log level: $LOGLEVEL"
            set -- "$@" -l "$LOGLEVEL"
        else
            echo "Ignoring unsupported LOGLEVEL: $LOGLEVEL (supported: trace, verbose, info, notify, warning, error)" >&2
        fi
    fi

    echo "Starting snell-server..."
    trap cleanup TERM INT
    "$@" &
    SNELL_PID=$!
    wait "$SNELL_PID"
}

if [ "${SNELL_ENTRYPOINT_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
