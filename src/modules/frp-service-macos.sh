#!/usr/bin/env bash

_frp_brew_service_ready() {
    local component=$1
    local prefix

    command -v "$component" >/dev/null 2>&1 || return 1
    prefix=$(brew --prefix) || return 1
    [ -f "$prefix/etc/frp/${component}.toml" ]
}

_frp_brew_service_registered() {
    local component=$1
    local info
    local registered

    info=$(brew services info "$component" --json 2>/dev/null) || return 1
    registered=$(printf '%s' "$info" |
        plutil -extract 0.registered raw -o - - 2>/dev/null) || return 1
    [ "$registered" = true ]
}

_frp_brew_print_next_step() {
    local component=$1
    local prefix
    local status

    prefix=$(brew --prefix)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    printf '\n\033[1;31mACTION REQUIRED:\033[0m\n'
    printf 'Edit %s/etc/frp/%s.toml, then start the Homebrew service:\n' \
        "$prefix" "$component"
    printf '  brew services start %s\n' "$component"
    printf '\n'
}

frpc-service_is_installed() {
    _frp_brew_service_registered frpc
}

frpc-service_install() {
    _frp_brew_service_ready frpc || fatal 1
    _frp_brew_print_next_step frpc
}

frps-service_is_installed() {
    _frp_brew_service_registered frps
}

frps-service_install() {
    _frp_brew_service_ready frps || fatal 1
    _frp_brew_print_next_step frps
}
