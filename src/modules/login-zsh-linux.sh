#!/usr/bin/env bash

_login_zsh_find() {
    local path

    path=$(command -v zsh) || return 1
    printf '%s' "$path"
}

_login_zsh_current() {
    local account
    local output
    local user

    user=$(id -un) || return 1
    output=$(getent passwd "$user") || return 1
    account=${output##*:}
    [ -n "$account" ] || return 1
    printf '%s' "$account"
}

_login_zsh_allowed() {
    local allowed
    local equivalent=''
    local shell_path=$1

    [ -r /etc/shells ] || return 1
    while IFS= read -r allowed; do
        case "$allowed" in
            ''|'#'*) continue ;;
        esac
        if [ "$allowed" = "$shell_path" ]; then
            printf '%s' "$allowed"
            return 0
        fi
        if [ -z "$equivalent" ] &&
            [ -e "$allowed" ] && [ -e "$shell_path" ] && [ "$allowed" -ef "$shell_path" ]; then
            equivalent=$allowed
        fi
    done < /etc/shells
    if [ -n "$equivalent" ]; then
        printf '%s' "$equivalent"
        return 0
    fi
    return 1
}

login-zsh_is_installed() {
    local current
    local shell_path

    shell_path=$(_login_zsh_find) || return 1
    current=$(_login_zsh_current) || return 1
    [ "$current" = "$shell_path" ] ||
        { [ -e "$current" ] && [ -e "$shell_path" ] && [ "$current" -ef "$shell_path" ]; }
}

login-zsh_install() {
    local allowed_shell
    local shell_path
    local status
    local user

    shell_path=$(_login_zsh_find)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    allowed_shell=$(_login_zsh_allowed "$shell_path")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    user=$(id -un)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    run_as_root chsh -s "$allowed_shell" "$user"
    printf '\n\033[1;31mACTION REQUIRED:\033[0m\n'
    printf 'Sign out and sign in again to use the new login shell.\n'
    printf '\n'
}
