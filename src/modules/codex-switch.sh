#!/usr/bin/env bash

_codex_switch_select() {
    local codex_dir=$1
    local accounts=()
    local auth_file
    local index
    local labels=()
    local selected=0
    local status=1
    local suffix

    # An empty selection means the user canceled.
    CODEX_SWITCH_SELECTION=''
    for auth_file in "$codex_dir"/auth.json.*; do
        [ -f "$auth_file" ] || continue
        suffix=${auth_file##*/auth.json.}
        case "$suffix" in
            ''|*[!a-zA-Z0-9._-]*) continue ;;
        esac
        accounts[${#accounts[@]}]=$suffix
        if [ -L "$codex_dir/auth.json" ] && [ "$codex_dir/auth.json" -ef "$auth_file" ]; then
            suffix="$suffix (current)"
        fi
        labels[${#labels[@]}]=$suffix
    done
    if [ "${#accounts[@]}" -eq 0 ]; then
        printf 'No auth.json.<provider> account files found in %s.\n' "$codex_dir" >&2
        return 1
    fi

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf 'Account selection requires an interactive terminal.\n' >&2
        return 1
    fi
    STTY_STATE=$(stty -g) || return 1
    activate_terminal || return 1
    while :; do
        printf '\033[HChoose account (j down, k up, Enter confirm, Esc cancel)\033[K\n\n'
        for ((index = 0; index < ${#accounts[@]}; index++)); do
            if [ "$index" -eq "$selected" ]; then
                printf '\033[7m > %s \033[0m\033[K\n' "${labels[$index]}"
            else
                printf '   %s\033[K\n' "${labels[$index]}"
            fi
        done
        printf '\033[J'
        read_tui_key || break
        case "$TUI_KEY" in
            k)
                selected=$(((selected + ${#accounts[@]} - 1) % ${#accounts[@]}))
                ;;
            j)
                selected=$(((selected + 1) % ${#accounts[@]}))
                ;;
            ''|$'\r')
                CODEX_SWITCH_SELECTION=${accounts[$selected]}
                status=0
                break
                ;;
            $'\033'|$'\004'|q)
                status=0
                break
                ;;
        esac
    done
    restore_terminal
    return "$status"
}

_codex_switch_render_config() {
    awk -v provider="$1" '
        /^[ \t]*\[/ { in_table = 1 }
        !in_table && /^[ \t]*model_provider[ \t]*=/ {
            match($0, /^[ \t]*model_provider[ \t]*=[ \t]*/)
            prefix = substr($0, 1, RLENGTH)
            value = substr($0, RLENGTH + 1)
            if (!match(value, /^("([^"\\]|\\.)*"|\047[^\047]*\047)/)) {
                invalid = 1
                exit 1
            }
            $0 = prefix "\"" provider "\"" substr(value, RLENGTH + 1)
            found = 1
        }
        { lines[NR] = $0 }
        END {
            if (invalid) exit 1
            if (!found) print "model_provider = \"" provider "\""
            for (i = 1; i <= NR; i++) print lines[i]
        }
    ' "$2" > "$3"
}

_codex_switch_account() {
    local codex_dir=$1
    local suffix=$2
    local status=0
    local work_dir

    # Set to 1 only after both the configuration and account are updated.
    CODEX_SWITCH_CHANGED=0
    case "$suffix" in
        ''|*[!a-zA-Z0-9._-]*)
            printf 'Invalid provider name: %s\n' "$suffix" >&2
            return 1
            ;;
    esac
    if [ ! -f "$codex_dir/auth.json.$suffix" ]; then
        printf 'Missing account file: %s/auth.json.%s\n' "$codex_dir" "$suffix" >&2
        return 1
    fi
    if [ -e "$codex_dir/auth.json" ] && [ ! -L "$codex_dir/auth.json" ]; then
        printf 'Not a symlink; leaving unchanged: %s/auth.json\n' "$codex_dir" >&2
        return 1
    fi

    work_dir=$(mktemp -d "$codex_dir/.codex-switch.XXXXXX") || return 1
    # Write through config.toml so existing links and file permissions survive.
    if ! cp "$codex_dir/config.toml" "$work_dir/original" ||
        ! _codex_switch_render_config "$suffix" "$work_dir/original" "$work_dir/updated"; then
        printf 'Could not update model_provider in %s/config.toml.\n' "$codex_dir" >&2
        status=1
    elif [ "$codex_dir/auth.json" -ef "$codex_dir/auth.json.$suffix" ] &&
        cmp -s "$work_dir/original" "$work_dir/updated"; then
        # Already current; leave both files untouched.
        :
    elif ! cat "$work_dir/updated" > "$codex_dir/config.toml" ||
        ! ln -sfn "auth.json.$suffix" "$codex_dir/auth.json"; then
        cat "$work_dir/original" > "$codex_dir/config.toml"
        status=1
    else
        CODEX_SWITCH_CHANGED=1
    fi
    rm -rf "$work_dir"
    return "$status"
}

_codex_switch_stop() {
    local count=0
    local executable
    local owner
    local pid
    local processes
    local status=0

    processes=$(ps -axo uid=,pid=,comm=) || return 1
    while read -r owner pid executable; do
        [ "$owner" = "$EUID" ] || continue
        # Match executable names, never arbitrary arguments containing "codex".
        case "${executable##*/}" in
            codex|Codex|codex-*|'Codex '*)
                if kill -TERM "$pid" 2>/dev/null; then
                    count=$((count + 1))
                elif kill -0 "$pid" 2>/dev/null; then
                    printf 'Could not stop Codex process %s.\n' "$pid" >&2
                    status=1
                fi
                ;;
        esac
    done <<<"$processes"
    printf 'Sent termination requests to %s Codex processes.\n' "$count"
    return "$status"
}

codex-switch_is_installed() {
    # Actions remain available each time hostinit runs.
    return 1
}

codex-switch_needs_update() {
    return 1
}

codex-switch_install() {
    local codex_dir=${CODEX_HOME:-$HOME/.codex}
    # Helpers write their results into this invocation's local scope.
    local CODEX_SWITCH_SELECTION=''
    local CODEX_SWITCH_CHANGED=0

    _codex_switch_select "$codex_dir" || return 1
    [ -n "$CODEX_SWITCH_SELECTION" ] || return 0

    _codex_switch_account "$codex_dir" "$CODEX_SWITCH_SELECTION" || return 1
    if [ "$CODEX_SWITCH_CHANGED" -eq 0 ]; then
        printf 'Codex account %s is already current.\n' "$CODEX_SWITCH_SELECTION"
        return 0
    fi
    printf 'Switched Codex account to %s.\n' "$CODEX_SWITCH_SELECTION"
    _codex_switch_stop
}

codex-switch_update() {
    return 0
}
