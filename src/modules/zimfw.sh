#!/usr/bin/env bash

_zimfw_run_action() {
    local action=$1
    local zim_home=${ZIM_HOME:-$HOME/.zim}
    local zimrc=${ZIM_CONFIG_FILE:-$HOME/.zimrc}

    run_checked env ZIM_HOME="$zim_home" ZIM_CONFIG_FILE="$zimrc" \
        zsh -c 'source "$1" "$2" -q' -- "$zim_home/zimfw.zsh" "$action"
}

zimfw_is_installed() {
    local zim_home=${ZIM_HOME:-$HOME/.zim}
    local zimrc=${ZIM_CONFIG_FILE:-$HOME/.zimrc}

    [ -f "$zim_home/zimfw.zsh" ] &&
        [ -f "$zim_home/init.zsh" ] &&
        [ -f "$zimrc" ]
}

zimfw_needs_update() {
    return 0
}

zimfw_install() {
    local installer
    local status
    local temp_dir
    local zim_home=${ZIM_HOME:-$HOME/.zim}
    local zimrc=${ZIM_CONFIG_FILE:-$HOME/.zimrc}
    local zsh_bin

    if [ -f "$zim_home/zimfw.zsh" ] && [ -f "$zimrc" ]; then
        if [ ! "$zim_home/init.zsh" -nt "$zimrc" ]; then
            _zimfw_run_action init
        fi
        return 0
    fi
    if [ -e "$zim_home" ]; then
        printf '%s exists but is not a complete Zimfw installation\n' "$zim_home" >&2
        fatal 1
    fi

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-zimfw.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    installer=$temp_dir/install.zsh
    curl --fail --show-error --silent --location \
        --connect-timeout 10 --retry 3 --proto '=https' --tlsv1.2 \
        'https://raw.githubusercontent.com/zimfw/install/master/install.zsh' \
        -o "$installer"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    zsh_bin=$(command -v zsh)
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    env SHELL="$zsh_bin" ZIM_HOME="$zim_home" ZIM_CONFIG_FILE="$zimrc" \
        zsh "$installer"
    status=$?
    rm -rf "$temp_dir"
    [ "$status" -eq 0 ] || fatal "$status"
}

zimfw_update() {
    local zim_home=${ZIM_HOME:-$HOME/.zim}
    local zimrc=${ZIM_CONFIG_FILE:-$HOME/.zimrc}

    _zimfw_run_action upgrade
    if [ ! "$zim_home/init.zsh" -nt "$zimrc" ]; then
        _zimfw_run_action init
    fi
    _zimfw_run_action update
    return 0
}
