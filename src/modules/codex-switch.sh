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

    for filename in auth.json config.json; do
        if [ ! -f "$codex_dir/$filename.$suffix" ]; then
            printf 'Missing account file: %s/%s.%s\n' "$codex_dir" "$filename" "$suffix" >&2
            return 1
        fi
        if [ -e "$codex_dir/$filename" ] && [ ! -L "$codex_dir/$filename" ]; then
            printf 'Not a symlink; leaving unchanged: %s/%s\n' "$codex_dir" "$filename" >&2
            return 1
        fi
    done

    for filename in auth.json config.json; do
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
    local codex_dir=$HOME/.codex
    local suffix

    printf 'Codex account suffix: '
    IFS= read -r suffix || return 1
    case "$suffix" in
        ''|*[!a-zA-Z0-9._-]*)
            printf 'Use a non-empty suffix containing only letters, digits, dots, underscores or hyphens.\n' >&2
            return 1
            ;;
    esac

    _codex_switch_links "$codex_dir" "$suffix" || return 1
    printf 'Switched Codex account to %s.\n' "$suffix"
    _codex_switch_stop
}

codex-switch_update() {
    return 0
}
