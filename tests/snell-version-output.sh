#!/usr/bin/env bash

snell_binary_reports_version() {
    local requested=${1#v} version_log=$2 core suffix
    [[ "$requested" =~ ^([0-9]+\.[0-9]+\.[0-9]+)([[:alnum:]._-]*)$ ]] || return 1
    core=${BASH_REMATCH[1]}
    suffix=${BASH_REMATCH[2]}

    grep -Fq "snell-server v$requested (" "$version_log" && return 0
    # This official v4.1.1 arm64 binary has a stale v4.1.0 banner.
    # Pin the exception to the inspected upstream payload, not all patch releases.
    if [[ "$requested" == 4.1.1 && "${3:-}" == linux/arm64 &&
        "${4:-}" == a6dceb898ade6da58840bf26499a0747894fb1c6407878139c8d863e7926d297 ]]; then
        grep -Fq 'snell-server v4.1.0 (' "$version_log"
        return
    fi
    [[ -n "$suffix" ]] || return 1
    grep -Fq "snell-server v$core (" "$version_log"
}
