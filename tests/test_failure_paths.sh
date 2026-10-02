#!/usr/bin/env bash
# Exercise the real installer in conditional contexts, without host services or network.
# shellcheck disable=SC2034,SC2317
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
suite=$(mktemp -d)
trap 'rm -rf "$suite"' EXIT
count=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

load_fixture() {
    # Only relocate readonly host paths; expand fixture when sourcing the declarations.
    # shellcheck disable=SC1090,SC2016
    SNELL_SOURCE_ONLY=1 source <(sed \
        -e 's|^readonly SNELL_BIN=.*|readonly SNELL_BIN="${fixture}/bin/snell-server"|' \
        -e 's|^readonly SNELL_CONFIG_DIR=.*|readonly SNELL_CONFIG_DIR="${fixture}/config"|' \
        -e 's|^readonly SNELL_SERVICE_FILE=.*|readonly SNELL_SERVICE_FILE="${fixture}/snell.service"|' \
        -e 's|^readonly SNELL_INIT_FILE=.*|readonly SNELL_INIT_FILE="${fixture}/snell.init"|' \
        -e 's|^readonly STATE_DIR=.*|readonly STATE_DIR="${fixture}/state"|' \
        -e 's|^readonly DOCKER_DIR=.*|readonly DOCKER_DIR="${fixture}/docker"|' "$root/Snell.sh")
    calls="$fixture/calls"
    : > "$calls"
    cfg_port=32000 cfg_psk=FixturePsk16._-abcdef cfg_ipv6=false cfg_dns=''
    cfg_dns_pref=prefer-ipv4 cfg_egress='' cfg_obfs='' cfg_host='' cfg_mode=default
    cfg_loglevel=info cfg_effective_version=v6.0.0rc2
    phase=''
    unexpected() { fail "unexpected external command: $*"; }
    docker() { unexpected docker "$@"; }
    curl() { unexpected curl "$@"; }
    systemctl() { unexpected systemctl "$@"; }
    rc-service() { unexpected rc-service "$@"; }
    groupadd() { unexpected groupadd "$@"; }
    addgroup() { unexpected addgroup "$@"; }
    useradd() { unexpected useradd "$@"; }
    adduser() { unexpected adduser "$@"; }
    apt-get() { unexpected apt-get "$@"; }
    dnf() { unexpected dnf "$@"; }
    yum() { unexpected yum "$@"; }
    apk() { unexpected apk "$@"; }
    chown() { gate chown; }
    success() { gate success; }
    show_install_result() { gate result; }
}

gate() {
    printf '%s\n' "$1" >> "$calls"
    [[ "$phase" != "$1" ]]
}

no_event() {
    if grep -Fxq "$1" "$calls"; then fail "unexpected continuation: $1"; fi
}

expect_failure() {
    local context="$1" status=0
    shift
    case "$context" in
        if)
            if "$@" > "$fixture/stdout" 2> "$fixture/stderr"; then
                fail "succeeded in if context: $* ($phase)"
            fi
            ;;
        or)
            "$@" > "$fixture/stdout" 2> "$fixture/stderr" || status=$?
            [[ "$status" -ne 0 ]] || fail "succeeded in || context: $* ($phase)"
            ;;
    esac
    no_event success
}

run_case() {
    count=$((count + 1))
    fixture="$suite/$count"
    (
        mkdir -p "$fixture/bin" "$fixture/config" "$fixture/state"
        load_fixture
        "$@"
    )
    printf 'ok %s - %s\n' "$count" "$*"
}

download_stubs() {
    get_arch() { gate arch || return 1; printf 'amd64\n'; }
    mktemp() {
        if [[ "$1" == -d ]]; then
            gate temp || return 1
            command mktemp -d "$fixture/download.XXXXXX"
        else
            gate stage || return 1
            command mktemp "$@"
        fi
    }
    mkdir() { gate mkdir || return 1; command mkdir "$@"; }
    curl() {
        gate curl || return 1
        [[ "$phase" != official || "${*: -1}" != "$OFFICIAL_BASE/"* ]] || return 1
        local output=''
        while (($#)); do
            if [[ "$1" == -o ]]; then output="$2"; break; fi
            shift
        done
        printf 'fixture archive\n' > "$output"
    }
    unzip() {
        case "$1" in
            -t) gate zip-test ;;
            -q)
                gate extract || return 1
                [[ "$phase" != missing-binary ]] || return 0
                printf '#!/usr/bin/env bash\nprintf "Snell v6.0.0\\n"\n' > "$4/snell-server"
                ;;
            *) fail "unexpected unzip arguments" ;;
        esac
    }
    install() { gate install || return 1; command install "$@"; }
}

download_failure() {
    local context="$1"
    phase="$2"
    download_stubs
    if [[ "$context" == assignment ]]; then
        download_assignment() {
            local stage
            stage=$(download_native_binary "$@") || return 1
            printf '%s\n' "$stage"
        }
        expect_failure or download_assignment v6.0.0rc2
    else
        expect_failure "$context" download_native_binary v6.0.0rc2
    fi
    [[ ! -s "$fixture/stdout" ]] || fail 'download failure printed a stage path'
    if compgen -G "$fixture/download.*" >/dev/null || compgen -G "${SNELL_BIN}.new.*" >/dev/null; then
        fail 'download failure leaked temp or stage'
    fi
    case "$phase" in
        arch) no_event temp ;;
        temp) no_event stage ;;
        stage) no_event mkdir ;;
        mkdir) no_event curl ;;
        curl) no_event zip-test ;;
        zip-test) no_event extract ;;
        extract|missing-binary) no_event install ;;
    esac
}

download_success() {
    phase="$1"
    download_stubs
    local stage
    stage=$(download_native_binary v6.0.0rc2) || fail 'valid download failed'
    [[ -x "$stage" ]] || fail 'download stage is not executable'
    [[ "$stage" == "${SNELL_BIN}.new."* ]] || fail 'download returned wrong stage'
    if compgen -G "$fixture/download.*" >/dev/null; then fail 'successful download leaked temp'; fi
    [[ "$("$stage" -v)" == 'Snell v6.0.0' ]] || fail 'invalid stage content'
}

docker_apply_failure() {
    local context="$1"
    phase="$2"
    ensure_docker() { gate ensure; }
    docker_container_exists() { return 1; }
    write_docker_files() { gate write; }
    compose() { gate "$1"; }
    wait_for_docker_container() { gate wait; }
    mkdir() { gate state-dir || return 1; command mkdir "$@"; }
    if [[ "$phase" == state-write ]]; then command mkdir "$STATE_FILE"; fi
    expect_failure "$context" docker_apply fixture:v6.0.0 host true
    [[ ! -f "$STATE_FILE" ]] || fail 'failed docker apply wrote install mode'
    case "$phase" in
        ensure) no_event write ;;
        write) no_event config ;;
        config) no_event down ;;
        down) no_event up ;;
        up) no_event wait ;;
        wait) no_event state-dir ;;
    esac
}

docker_install_failure() {
    local context="$1"
    phase="$2"
    ensure_docker() { gate ensure; }
    has_docker_install() { return 1; }
    pull_docker_image() { gate pull || return 1; selected_image=fixture:v6.0.0; }
    docker_apply() { gate apply; }
    expect_failure "$context" docker_install v6.0.0 host auto
    case "$phase" in ensure) no_event pull ;; pull) no_event apply ;; esac
}

docker_update_failure() {
    local context="$1"
    phase="$2"
    get_mode() { printf 'docker\n'; }
    docker_config_defaults() { gate defaults; }
    ensure_docker() { gate ensure; }
    compose() { gate "$1"; }
    wait_for_docker_container() { gate wait; }
    expect_failure "$context" update_snell
    case "$phase" in
        defaults) no_event ensure ;;
        ensure) no_event pull ;;
        pull) no_event up ;;
        up) no_event wait ;;
    esac
}

agent_validation_failure() {
    CLI_METHOD=native CLI_VERSION=v6.0.0
    phase=validate
    validate_agent_config() { gate validate; }
    collect_config() { gate collect; }
    native_install() { gate install; }
    expect_failure "$1" agent_install
    no_event collect
    no_event install
}

writer_failure() {
    local context="$1" writer="$2"
    phase="$3"
    printf 'old config\n' > "$SNELL_CONFIG_FILE"
    printf 'old loglevel\n' > "$SNELL_LOGLEVEL_FILE"
    command mkdir -p "$DOCKER_DIR"
    printf 'old env\n' > "$DOCKER_ENV_FILE"
    printf 'old compose\n' > "$DOCKER_COMPOSE_FILE"
    backup_file() { gate backup; }
    mkdir() { gate mkdir || return 1; command mkdir "$@"; }
    mktemp() { gate mktemp || return 1; command mktemp "$@"; }
    render_snell_config() { gate render || return 1; printf 'new config\n'; }
    render_env_file() { gate render-env || return 1; printf 'new env\n'; }
    render_compose() { gate render-compose || return 1; printf 'new compose\n'; }
    chmod() { gate chmod || return 1; command chmod "$@"; }
    mv() { gate mv || return 1; command mv "$@"; }
    case "$writer" in
        config)
            expect_failure "$context" write_native_config v6.0.0
            [[ "$(< "$SNELL_CONFIG_FILE")" == 'old config' ]] || fail 'failed config overwrote original'
            ;;
        loglevel)
            expect_failure "$context" write_native_loglevel
            [[ "$(< "$SNELL_LOGLEVEL_FILE")" == 'old loglevel' ]] || fail 'failed loglevel overwrote original'
            ;;
        docker)
            expect_failure "$context" write_docker_files fixture:v6.0.0 host
            [[ "$(< "$DOCKER_COMPOSE_FILE")" == 'old compose' ]] || fail 'failed writer overwrote compose'
            ;;
    esac
    if compgen -G "$SNELL_CONFIG_DIR/*.tmp.*" >/dev/null \
        || compgen -G "$DOCKER_DIR/*.tmp.*" >/dev/null \
        || compgen -G "$DOCKER_DIR/.env.tmp.*" >/dev/null; then fail 'writer leaked temp'; fi
}

native_stubs() {
    is_musl_system() { return 1; }
    ensure_native_dependencies() { gate deps; }
    create_system_user() { gate user; }
    download_native_binary() {
        gate download || return 1
        printf 'new binary\n' > "$fixture/stage"
        command chmod 755 "$fixture/stage"
        printf '%s\n' "$fixture/stage"
    }
    native_stop() { gate stop; }
    backup_file() { gate backup; }
    write_native_config() { gate config; }
    write_native_loglevel() { gate loglevel; }
    write_service_files() { gate service; }
    native_start() { gate start; }
    cp() { gate copy || return 1; command cp "$@"; }
    mv() {
        local target="${*: -1}"
        if [[ "$target" == "$SNELL_VERSION_FILE" ]]; then
            gate record || return 1
        elif [[ "$target" == "$SNELL_BIN" && "$*" != *rollback* ]]; then
            gate replace || return 1
        fi
        command mv "$@"
    }
    get_mode() { printf 'native\n'; }
    get_latest_version() { printf '6.0.0\n'; }
    tui_yesno() { return 0; }
}

old_install() {
    printf 'old binary\n' > "$SNELL_BIN"
    command chmod 755 "$SNELL_BIN"
    printf 'v6.0.0rc2\n' > "$SNELL_VERSION_FILE"
    printf 'native\n' > "$STATE_FILE"
}

native_failure() {
    local context="$1" operation="$2"
    phase="$3"
    old_install
    native_stubs
    if [[ "$operation" == install ]]; then
        expect_failure "$context" native_install v6.0.0
    else
        expect_failure "$context" update_snell
    fi
    [[ "$(< "$SNELL_VERSION_FILE")" == v6.0.0rc2 ]] || fail 'failed operation changed old metadata'
    [[ "$(< "$SNELL_BIN")" == 'old binary' ]] || fail 'failed operation left new binary'
    [[ "$(get_native_version)" == 6.0.0rc2 ]] || fail 'failed reinstall reports incorrect version'
    if compgen -G "$fixture/stage*" >/dev/null \
        || compgen -G "${SNELL_VERSION_FILE}.tmp.*" >/dev/null; then fail 'native operation leaked stage or record'; fi
    case "$phase" in
        deps) no_event user ;;
        user) no_event download ;;
        download) no_event stop ;;
        stop) no_event replace ;;
        backup|copy) no_event replace ;;
        replace) no_event config; no_event start ;;
        config) no_event loglevel ;;
        loglevel) no_event service ;;
        service) no_event record ;;
        start) no_event record ;;
    esac
}

native_success() {
    local operation="$1"
    old_install
    native_stubs
    if [[ "$operation" == install ]]; then
        if native_install 6.0.0rc10 > "$fixture/stdout" 2> "$fixture/stderr"; then :; else fail 'native install failed'; fi
        [[ "$(< "$SNELL_VERSION_FILE")" == v6.0.0rc10 ]] || fail 'install did not record canonical exact version'
        [[ "$(get_native_version)" == 6.0.0rc10 ]] || fail 'install lost prerelease precision'
    else
        local status=0
        update_snell > "$fixture/stdout" 2> "$fixture/stderr" || status=$?
        [[ "$status" == 0 ]] || fail 'native update failed'
        [[ "$(< "$SNELL_VERSION_FILE")" == v6.0.0 ]] || fail 'update did not record exact version'
        [[ "$(get_native_version)" == 6.0.0 ]] || fail 'update reports wrong version'
    fi
    [[ "$(< "$SNELL_BIN")" == 'new binary' ]] || fail 'successful operation did not replace binary'
    grep -Fxq success "$calls" || fail 'successful operation did not report success'
    [[ ! -e "${SNELL_BIN}.rollback" && ! -e "$fixture/stage.rollback" ]] || fail 'successful operation retained rollback'
}

fresh_install_failure() {
    native_stubs
    phase=start
    expect_failure if native_install v6.0.0rc2
    [[ ! -e "$SNELL_BIN" && ! -e "$SNELL_VERSION_FILE" ]] || fail 'failed fresh install retained binary/version'
}

version_reading() {
    printf '#!/usr/bin/env bash\nprintf "Snell v6.0.0\\n"\n' > "$SNELL_BIN"
    command chmod 755 "$SNELL_BIN"
    [[ "$(get_native_version)" == 6.0.0 ]] || fail 'missing-metadata banner fallback failed'
    printf 'v6.0.0rc2\n' > "$SNELL_VERSION_FILE"
    [[ "$(get_native_version)" == 6.0.0rc2 ]] || fail 'metadata did not override inaccurate rc banner'
    printf '6.0.0rc10\n' > "$SNELL_VERSION_FILE"
    [[ "$(get_native_version)" == 6.0.0rc10 ]] || fail 'valid unprefixed metadata failed'
    printf 'not-a-version\n' > "$SNELL_VERSION_FILE"
    expect_failure if get_native_version
    [[ ! -s "$fixture/stdout" ]] || fail 'invalid metadata fell back to banner'
    rm -f "$SNELL_VERSION_FILE"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SNELL_BIN"
    expect_failure or get_native_version
    [[ ! -s "$fixture/stdout" ]] || fail 'empty banner returned output'
    rm -f "$SNELL_BIN"
    printf 'v6.0.0rc2\n' > "$SNELL_VERSION_FILE"
    expect_failure if get_native_version
}

record_failure() {
    phase="$1"
    old_install
    mktemp() { gate mktemp || return 1; command mktemp "$@"; }
    mv() { gate mv || return 1; command mv "$@"; }
    expect_failure or record_native_version 6.0.0
    [[ "$(< "$SNELL_VERSION_FILE")" == v6.0.0rc2 ]] || fail 'record failure changed old metadata'
    if compgen -G "${SNELL_VERSION_FILE}.tmp.*" >/dev/null; then fail 'record failure leaked temp'; fi
}

dependency_failure() {
    phase=packages
    command_exists() { [[ "$1" != curl ]]; }
    get_package_manager() { printf 'apt\n'; }
    install_packages() { gate packages; }
    expect_failure if ensure_native_dependencies
}

user_failure() {
    phase="$1"
    getent() { return 1; }
    id() { return 1; }
    command_exists() { [[ "$1" == groupadd || "$1" == useradd ]]; }
    groupadd() { gate group; }
    useradd() { gate user; }
    expect_failure or create_system_user
    if [[ "$phase" == group ]]; then no_event user; fi
}

service_failure() {
    phase="$1"
    systemd_usable() { return 0; }
    systemctl() { gate "$*"; }
    expect_failure if write_service_files
    [[ "$SERVICE_KIND" == manual ]] || fail 'failed service write changed service kind'
}

start_failure() {
    phase='enable --now snell'
    SERVICE_KIND=systemd
    systemctl() { gate "$*"; }
    wait_for_native() { gate wait; }
    expect_failure or native_start
    no_event wait
}

uninstall_metadata() {
    old_install
    has_native_install() { return 0; }
    has_docker_install() { return 1; }
    tui_yesno() { return 0; }
    uninstall_native() { :; }
    uninstall_snell > "$fixture/stdout" 2> "$fixture/stderr"
    [[ ! -e "$STATE_DIR" && ! -e "$SNELL_VERSION_FILE" ]] || fail 'uninstall retained metadata'
}

for context in if or; do
    for phase in arch temp stage mkdir curl zip-test extract missing-binary install; do
        run_case download_failure "$context" "$phase"
    done
    for phase in ensure write config down up wait state-dir state-write; do
        run_case docker_apply_failure "$context" "$phase"
    done
    for phase in ensure pull apply; do run_case docker_install_failure "$context" "$phase"; done
    for phase in defaults ensure pull up wait; do run_case docker_update_failure "$context" "$phase"; done
    run_case agent_validation_failure "$context"
    for phase in mkdir mktemp render chown chmod mv; do run_case writer_failure "$context" config "$phase"; done
    for phase in mktemp chown chmod mv; do run_case writer_failure "$context" loglevel "$phase"; done
    for phase in mkdir backup mktemp render-env render-compose chmod mv; do run_case writer_failure "$context" docker "$phase"; done
    for phase in deps user download stop backup copy replace config loglevel service start record; do
        run_case native_failure "$context" install "$phase"
    done
    for phase in download stop copy replace start record; do run_case native_failure "$context" update "$phase"; done
done
for phase in arch temp stage mkdir curl zip-test extract missing-binary install; do
    run_case download_failure assignment "$phase"
done
run_case download_success ''
run_case download_success official
run_case native_success install
run_case native_success update
run_case fresh_install_failure
run_case version_reading
run_case record_failure mktemp
run_case record_failure mv
run_case dependency_failure
run_case user_failure group
run_case user_failure user
run_case service_failure daemon-reload
run_case start_failure
run_case uninstall_metadata
printf 'Failure-path regression tests passed (%s cases).\n' "$count"
