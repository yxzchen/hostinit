#!/usr/bin/env bash

ZIMFW_MODULE_UPDATE_NEEDED=0
ZIMFW_UPGRADE_NEEDED=0

_zimfw_run_action() {
    local action=$1
    local zim_home=${ZIM_HOME:-$HOME/.zim}
    local zimrc=${ZIM_CONFIG_FILE:-$HOME/.zimrc}

    print_step "Applying Zimfw action: ${action}"
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

_zimfw_check_updates() {
    local module_output
    local status
    local version_output
    local zim_home=${ZIM_HOME:-$HOME/.zim}
    local zimrc=${ZIM_CONFIG_FILE:-$HOME/.zimrc}

    print_step 'Checking Zimfw and module updates'
    ZIMFW_MODULE_UPDATE_NEEDED=0
    ZIMFW_UPGRADE_NEEDED=0
    version_output=$(env ZIM_HOME="$zim_home" ZIM_CONFIG_FILE="$zimrc" \
        zsh -c 'source "$1" "$2" -v' \
        -- "$zim_home/zimfw.zsh" check-version 2>&1)
    status=$?
    [ "$status" -eq 0 ] || { print_info "$version_output"; fatal "$status" 'Could not check the Zimfw version'; }
    case "$version_output" in
        *'Latest zimfw version is '*) ZIMFW_UPGRADE_NEEDED=1 ;;
    esac

    module_output=$(env ZIM_HOME="$zim_home" ZIM_CONFIG_FILE="$zimrc" \
        zsh -c 'source "$1" "$2" -v' \
        -- "$zim_home/zimfw.zsh" check 2>&1)
    status=$?
    [ "$status" -eq 0 ] || { print_info "$module_output"; fatal "$status" 'Could not check Zimfw modules'; }
    case "$module_output" in
        *': Update available'*) ZIMFW_MODULE_UPDATE_NEEDED=1 ;;
    esac

    [ "$ZIMFW_UPGRADE_NEEDED" -eq 1 ] || [ "$ZIMFW_MODULE_UPDATE_NEEDED" -eq 1 ]
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
        fatal 1 "${zim_home} exists but is not a complete Zimfw installation"
    fi

    print_step 'Downloading the Zimfw installer'
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
    print_step 'Installing Zimfw'
    env SHELL="$zsh_bin" ZIM_HOME="$zim_home" ZIM_CONFIG_FILE="$zimrc" \
        zsh "$installer"
    status=$?
    rm -rf "$temp_dir"
    [ "$status" -eq 0 ] || fatal "$status"
}

zimfw_update() {
    local changed=0
    local zim_home=${ZIM_HOME:-$HOME/.zim}
    local zimrc=${ZIM_CONFIG_FILE:-$HOME/.zimrc}

    _zimfw_check_updates || return 1
    if [ "$ZIMFW_UPGRADE_NEEDED" -eq 1 ]; then
        _zimfw_run_action upgrade
        changed=1
    fi
    if [ ! "$zim_home/init.zsh" -nt "$zimrc" ]; then
        _zimfw_run_action init
    fi
    if [ "$ZIMFW_MODULE_UPDATE_NEEDED" -eq 1 ]; then
        _zimfw_run_action update
        changed=1
    fi
    [ "$changed" -eq 1 ] || return 1
    return 0
}
