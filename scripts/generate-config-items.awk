function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
}

function quote(value) {
    return sprintf("%c%s%c", 39, value, 39)
}

function shell_key(value) {
    gsub(/-/, "_", value)
    return value
}

function normalize_version(version, parts, major, minor, patch, suffix) {
    gsub(/^v/, "", version)
    split(version, parts, ".")
    major = parts[1] + 0
    minor = (parts[2] == "" ? 0 : parts[2] + 0)
    patch = (parts[3] == "" ? 0 : parts[3])
    sub(/[A-Za-z].*$/, "", patch)
    patch = patch + 0
    return major * 1000000 + minor * 1000 + patch
}

function version_matches_rule(version_num, rule, negated, min, max, parts) {
    rule = trim(rule)
    if (rule == "") {
        return 1
    }

    negated = 0
    if (substr(rule, 1, 1) == "!") {
        negated = 1
        rule = substr(rule, 2)
    }

    if (rule ~ /\+$/) {
        sub(/\+$/, "", rule)
        min = normalize_version(rule)
        return negated ? version_num < min : version_num >= min
    }

    if (rule ~ /-/) {
        split(rule, parts, "-")
        min = normalize_version(parts[1])
        max = normalize_version(parts[2])
        return negated ? !(version_num >= min && version_num <= max) : (version_num >= min && version_num <= max)
    }

    min = normalize_version(rule)
    return negated ? version_num != min : version_num == min
}

function versions_match(version_num, count, i, has_positive, positive_match) {
    if (count == 0) {
        return 1
    }

    has_positive = 0
    positive_match = 0
    for (i = 1; i <= count; i++) {
        if (substr(versions[i], 1, 1) == "!") {
            if (!version_matches_rule(version_num, versions[i])) {
                return 0
            }
        } else {
            has_positive = 1
            if (version_matches_rule(version_num, versions[i])) {
                positive_match = 1
            }
        }
    }

    return has_positive ? positive_match : 1
}

function reset_item() {
    name = ""
    env = ""
    enabled = "true"
    required = "false"
    default_value = ""
    generator = ""
    port_min = ""
    port_max = ""
    allowed_count = 0
    version_count = 0
    in_allowed = 0
    in_versions = 0
    in_port_range = 0
}

function emit_item(version_num, allowed, versions, i, key) {
    if (name == "") {
        return
    }

    if (enabled != "true" && enabled != "false") {
        printf "Invalid enabled value for %s: %s\n", name, enabled > "/dev/stderr"
        exit 1
    }

    if (!versions_match(version_num, version_count)) {
        reset_item()
        return
    }

    allowed = ""
    for (i = 1; i <= allowed_count; i++) {
        allowed = allowed (allowed == "" ? "" : "|") allowed_values[i]
    }

    key = shell_key(name)
    printf "CONFIG_ITEM_NAMES=\"${CONFIG_ITEM_NAMES} %s\"\n", name
    printf "CONFIG_%s_ENV=%s\n", key, quote(env)
    printf "CONFIG_%s_ENABLED=%s\n", key, quote(enabled)
    printf "CONFIG_%s_REQUIRED=%s\n", key, quote(required)
    printf "CONFIG_%s_DEFAULT=%s\n", key, quote(default_value)
    printf "CONFIG_%s_GENERATOR=%s\n", key, quote(generator)
    printf "CONFIG_%s_ALLOWED=%s\n", key, quote(allowed)
    printf "CONFIG_%s_PORT_MIN=%s\n", key, quote(port_min)
    printf "CONFIG_%s_PORT_MAX=%s\n", key, quote(port_max)
    reset_item()
}

BEGIN {
    version_num = normalize_version(sn_version)
    print "# Generated from snell-config.yml. Do not edit."
    print "CONFIG_ITEM_NAMES=\"\""
    reset_item()
}

/^[[:space:]]*#/ || /^[[:space:]]*$/ {
    next
}

$0 ~ /^  - name:/ {
    emit_item(version_num)
    reset_item()
    name = trim(substr($0, index($0, ":") + 1))
    next
}

name != "" && $0 ~ /^    [A-Za-z_]+:/ {
    in_allowed = 0
    in_versions = 0
    in_port_range = 0
}

name != "" && $0 ~ /^    env:/ {
    env = trim(substr($0, index($0, ":") + 1))
    next
}

name != "" && $0 ~ /^    enabled:/ {
    enabled = trim(substr($0, index($0, ":") + 1))
    next
}

name != "" && $0 ~ /^    required:/ {
    required = trim(substr($0, index($0, ":") + 1))
    next
}

name != "" && $0 ~ /^    default:/ {
    default_value = trim(substr($0, index($0, ":") + 1))
    gsub(/^"|"$/, "", default_value)
    next
}

name != "" && $0 ~ /^    generator:/ {
    generator = trim(substr($0, index($0, ":") + 1))
    next
}

name != "" && $0 ~ /^    allowed:/ {
    in_allowed = 1
    next
}

name != "" && in_allowed && $0 ~ /^      - / {
    allowed_count++
    allowed_values[allowed_count] = trim(substr($0, index($0, "-") + 1))
    gsub(/^"|"$/, "", allowed_values[allowed_count])
    next
}

name != "" && $0 ~ /^    versions:/ {
    in_versions = 1
    next
}

name != "" && in_versions && $0 ~ /^      - / {
    version_count++
    versions[version_count] = trim(substr($0, index($0, "-") + 1))
    gsub(/^"|"$/, "", versions[version_count])
    next
}

name != "" && $0 ~ /^    port_range:/ {
    in_port_range = 1
    next
}

name != "" && in_port_range && $0 ~ /^      min:/ {
    port_min = trim(substr($0, index($0, ":") + 1))
    next
}

name != "" && in_port_range && $0 ~ /^      max:/ {
    port_max = trim(substr($0, index($0, ":") + 1))
    next
}

END {
    emit_item(version_num)
}
