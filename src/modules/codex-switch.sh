#!/usr/bin/env bash

codex-switch_is_installed() {
    # Actions remain available each time hostinit runs.
    return 1
}

codex-switch_needs_update() {
    return 1
}

_codex_switch_links() {
    local codex_dir=$1
    local suffix=$2
    local filename

    for filename in auth.json config.toml; do
        if [ ! -f "$codex_dir/$filename.$suffix" ]; then
            printf 'Missing account file: %s/%s.%s\n' "$codex_dir" "$filename" "$suffix" >&2
            return 1
        fi
        if [ -e "$codex_dir/$filename" ] && [ ! -L "$codex_dir/$filename" ]; then
            printf 'Not a symlink; leaving unchanged: %s/%s\n' "$codex_dir" "$filename" >&2
            return 1
        fi
    done

    for filename in auth.json config.toml; do
        ln -sfn "$filename.$suffix" "$codex_dir/$filename" || return 1
    done
}

_codex_switch_stop() {
    local processes
    local owner
    local pid
    local executable
    local count=0
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

codex-switch_install() {
    local codex_dir=${CODEX_HOME:-$HOME/.codex}
    local auth_file
    local suffix
    local accounts=()
    local selected=0
    local index
    local status=1

    for auth_file in "$codex_dir"/auth.json.*; do
        [ -f "$auth_file" ] || continue
        suffix=${auth_file##*/auth.json.}
        [ -n "$suffix" ] && [ -f "$codex_dir/config.toml.$suffix" ] || continue
        accounts[${#accounts[@]}]=$suffix
    done
    if [ "${#accounts[@]}" -eq 0 ]; then
        printf 'No matching account files found in %s.\n' "$codex_dir" >&2
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
                printf '\033[7m > %s \033[0m\033[K\n' "${accounts[$index]}"
            else
                printf '   %s\033[K\n' "${accounts[$index]}"
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
            ''|$'\r') status=0; break ;;
            $'\033'|$'\004'|q) break ;;
        esac
    done
    restore_terminal
    [ "$status" -eq 0 ] || return "$status"
    suffix=${accounts[$selected]}

    _codex_switch_links "$codex_dir" "$suffix" || return 1
    printf 'Switched Codex account to %s.\n' "$suffix"
    _codex_switch_stop
}

codex-switch_update() {
    return 0
}
