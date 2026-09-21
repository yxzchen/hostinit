TUI_ACTIVE=0
STTY_STATE=''
ACTION=''
MODE='install'
CURRENT_OPERATION=''
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
    exit "$status"
}

run_checked() {
    local status

    "$@"
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
}

run_as_root() {
    if [ "$EUID" -eq 0 ]; then
        run_checked "$@"
    else
        run_checked sudo "$@"
    fi
}

_print_status() {
    local color=$1
    local item
    local message=$2

    shift 2
    printf '\n\033[%sm==> %s' "$color" "$message"
    for item in "$@"; do
        printf ' %s' "$item"
    done
    printf '\033[0m\n'
}

print_step() {
    _print_status '1;36' "$@"
}

print_success() {
    _print_status '1;32' "$@"
}

print_skip() {
    _print_status '90' "$@"
}

print_failure() {
    _print_status '1;31' "$@" >&2
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
    if [ "$status" -ne 0 ] && [ -n "$CURRENT_OPERATION" ]; then
        print_failure "Failed: ${CURRENT_OPERATION} (exit ${status})"
    fi
    return "$status"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
