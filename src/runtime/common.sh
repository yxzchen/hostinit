TUI_ACTIVE=0
STTY_STATE=''
ACTION=''
MODE='install'
APT_METADATA_REFRESHED=0
APT_INSTALLED_CACHE_READY=0
APT_INSTALLED_PACKAGES=''
BREW_METADATA_REFRESHED=0
BREW_INSTALLED_CACHE_READY=0
BREW_INSTALLED_FORMULAE=''
BREW_INSTALLED_CASKS=''

fatal() {
    local status=${1:-1}

    case "$status" in
        ''|*[!0-9]*|0)
            status=1
            ;;
    esac
    FAILURE_REASON=${2:-"${CURRENT_STEP:-Operation failed} (exit ${status})"}
    if [ "${REPORT_ACTIVE:-0}" -ne 1 ] || [ "$BASH_SUBSHELL" -ne "$REPORT_SUBSHELL" ]; then
        restore_terminal
        _output_line '1;31' "Error: ${FAILURE_REASON}"
    fi
    exit "$status"
}

run_checked() {
    local status

    "$@"
    status=$?
    [ "$status" -eq 0 ] || fatal "$status" "${FAILURE_REASON:-${CURRENT_STEP:-Command failed}: $1 (exit ${status})}"
}

run_as_root() {
    if [ "$EUID" -eq 0 ]; then
        run_checked "$@"
    else
        run_checked sudo "$@"
    fi
}

_os_release_value() {
    local requested_key=$1
    local key
    local value

    [ -r /etc/os-release ] || return 1
    while IFS='=' read -r key value; do
        [ "$key" = "$requested_key" ] || continue
        value=${value#\"}
        value=${value%\"}
        [ -n "$value" ] || return 1
        printf '%s' "$value"
        return 0
    done < /etc/os-release
    return 1
}

restore_terminal() {
    local status=$?

    if [ "$TUI_ACTIVE" -eq 1 ]; then
        stty "$STTY_STATE"
        TUI_ACTIVE=0
        printf '\033[?25h\033[?1049l'
    fi
    return "$status"
}

finish() {
    local status=$?

    restore_terminal
    finish_report "$status"
    return "$status"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
