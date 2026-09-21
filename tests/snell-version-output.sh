#!/usr/bin/env bash

snell_binary_reports_version() {
    local requested=${1#v} version_log=$2 core suffix
    [[ "$requested" =~ ^([0-9]+\.[0-9]+\.[0-9]+)([[:alnum:]._-]*)$ ]] || return 1
    core=${BASH_REMATCH[1]}
    suffix=${BASH_REMATCH[2]}

    grep -Fq "snell-server v$requested (" "$version_log" && return 0
    [[ -n "$suffix" ]] || return 1
    grep -Fq "snell-server v$core (" "$version_log"
}
