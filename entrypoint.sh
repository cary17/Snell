#!/bin/sh

# ============================================================
# Signal handling
# ============================================================
cleanup() {
    [ -n "$SNELL_PID" ] && kill -TERM "$SNELL_PID" 2>/dev/null
}
trap cleanup TERM INT

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

# Generate a random single-line PSK with base64 output length around 12-180 bytes.
random_psk() {
    byte_count=$((9 + $(random_index 127)))
    openssl rand --base64 "$byte_count" | tr -d '\r\n'
    printf '\n'
}

random_port() {
    min_port=${1:-10000}
    max_port=${2:-65535}
    port_span=$((max_port - min_port + 1))
    printf '%s\n' $((min_port + $(random_index "$port_span")))
}

validate_loglevel() {
    case "$1" in
        debug|info|warning|error|fatal) return 0 ;;
        *) return 1 ;;
    esac
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

get_snell_version() {
    cat /snell/snell-version 2>/dev/null || echo "unknown"
}

get_major_version() {
    cat /snell/snell-major-version 2>/dev/null || echo "0"
}

supports_mode() {
    major=$(get_major_version)
    [ "$major" -ge 6 ] 2>/dev/null
}

is_v6_or_higher() {
    major=$(get_major_version)
    [ "$major" -ge 6 ] 2>/dev/null
}

supports_dns() {
    major=$(get_major_version)
    full_version=$(get_snell_version)
    version_without_v=${full_version#v}
    minor=${version_without_v#*.}
    minor=${minor%%.*}
    
    # DNS is supported from v4.1.
    [ "$major" -gt 4 ] 2>/dev/null && return 0
    [ "$major" -eq 4 ] 2>/dev/null && [ "$minor" -ge 1 ] 2>/dev/null && return 0
    return 1
}

# ============================================================
# Listen value parsing
# ============================================================

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
    
    if echo "$input" | grep -q ':'; then
        printf "%s" "$input"
        return
    fi
    
    if [ "$major" -ge 6 ] 2>/dev/null; then
        result=""
        OLD_IFS="$IFS"
        IFS=','
        for item in $input; do
            IFS="$OLD_IFS"
            port=$(printf "%s" "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$port" ]; then
                result="${result:+${result}, }0.0.0.0:${port}, [::]:${port}"
            fi
            IFS=','
        done
        IFS="$OLD_IFS"
        printf "%s" "$result"
    else
        first_port=$(printf "%s" "$input" | cut -d, -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        printf ":::%s" "$first_port"
    fi
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

env_to_key() {
    printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
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

    if [ -n "$default_value" ]; then
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
            parse_listen "$MAJOR_VERSION" "$value" "${min_port:-10000}" "${max_port:-65535}"
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

    env_value=$(printenv "$env_name" 2>/dev/null || true)
    if [ -n "$env_value" ]; then
        value=$env_value
    elif [ "$enabled" = "true" ]; then
        value=$(generated_config_value "$item" "$generator" "$default_value" || true)
    else
        value=""
    fi

    [ -n "$value" ] || return 1
    value=$(normalize_config_value "$item" "$value")

    if ! is_allowed_value "$value" "$allowed"; then
        if [ -n "$default_value" ] && is_allowed_value "$default_value" "$allowed"; then
            value=$default_value
        else
            echo "Invalid value for ${env_name}: ${value}" >&2
            return 1
        fi
    fi

    printf '%s\n' "$value"
}

write_config_items() {
    for item in $CONFIG_ITEM_NAMES; do
        key=$item
        value=$(resolve_config_value "$item" || true)
        [ -n "$value" ] && echo "${key} = ${value}"
    done

    env | awk -v known_envs=" ${CONFIG_ENV_NAMES:-} " '
        function is_runtime_env(name) {
            return name == "TZ" ||
                name == "LOG" ||
                name == "LOG_LEVEL" ||
                name == "LOGLEVEL" ||
                name == "HOSTNAME" ||
                name == "HOME" ||
                name == "PATH" ||
                name == "PWD" ||
                name == "OLDPWD" ||
                name == "SHLVL" ||
                name == "TERM" ||
                name == "_" ||
                name == "SHELL" ||
                name == "USER" ||
                name == "LOGNAME"
        }

        /^[A-Za-z_][A-Za-z0-9_]*=/ {
            separator = index($0, "=")
            name = substr($0, 1, separator - 1)
            value = substr($0, separator + 1)

            if (value == "") {
                next
            }
            if (index(known_envs, " " name " ") > 0) {
                next
            }
            if (is_runtime_env(name)) {
                next
            }
            if (name !~ /^[A-Z][A-Z0-9_]+$/) {
                next
            }

            key = name
            sub(/^SNELL_/, "", key)
            key = tolower(key)
            gsub(/_/, "-", key)
            print key " = " value
        }
    '
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

        # Generate configuration file.
        {
            echo "[snell-server]"
            write_config_items

        } > "$CONFIG_FILE"

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

    CMD="./snell-server -c $CONFIG_FILE"
    if [ -n "$LOGLEVEL" ] && validate_loglevel "$LOGLEVEL" 2>/dev/null; then
        CMD="$CMD -l $LOGLEVEL"
    fi

    echo "Starting snell-server..."
    $CMD &
    SNELL_PID=$!
    wait $SNELL_PID
}

if [ "${SNELL_ENTRYPOINT_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
