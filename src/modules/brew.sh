#!/usr/bin/env bash

_brew_find() {
    if command -v brew >/dev/null 2>&1; then
        command -v brew
    elif [ -x /opt/homebrew/bin/brew ]; then
        printf '/opt/homebrew/bin/brew'
    elif [ -x /usr/local/bin/brew ]; then
        printf '/usr/local/bin/brew'
    elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
        printf '/home/linuxbrew/.linuxbrew/bin/brew'
    elif [ -x "$HOME/.linuxbrew/bin/brew" ]; then
        printf '%s' "$HOME/.linuxbrew/bin/brew"
    else
        return 1
    fi
}

_brew_shellenv_line() {
    printf 'eval "$(%s shellenv)"' "$1"
}

_brew_configure_shellenv() {
    local brew_bin=$1
    local line
    local shellenv
    local status

    line=$(_brew_shellenv_line "$brew_bin")
    if [ ! -f "$HOME/.zprofile" ] || ! grep -Fqx "$line" "$HOME/.zprofile"; then
        printf '\n%s\n' "$line" >>"$HOME/.zprofile"
        status=$?
        [ "$status" -eq 0 ] || fatal "$status"
    fi
    shellenv=$("$brew_bin" shellenv)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    eval "$shellenv"
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
}

brew_is_installed() {
    local brew_bin
    local line
    local shellenv

    brew_bin=$(_brew_find) || return 1
    line=$(_brew_shellenv_line "$brew_bin")
    [ -f "$HOME/.zprofile" ] && grep -Fqx "$line" "$HOME/.zprofile" || return 1
    shellenv=$("$brew_bin" shellenv) || return 1
    eval "$shellenv" || return 1
}

brew_install() {
    local brew_bin
    local installer
    local status
    local temp_dir

    if brew_bin=$(_brew_find); then
        _brew_configure_shellenv "$brew_bin"
        return 0
    fi

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-brew.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    installer=$temp_dir/install.sh
    curl --fail --show-error --silent --location \
        --connect-timeout 10 --retry 3 --proto '=https' --tlsv1.2 \
        'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' \
        -o "$installer"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    env NONINTERACTIVE=1 /bin/bash "$installer"
    status=$?
    rm -rf "$temp_dir"
    [ "$status" -eq 0 ] || fatal "$status"

    brew_bin=$(_brew_find)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    _brew_configure_shellenv "$brew_bin"
}

brew_update() {
    local brew_bin
    local output
    local status

    brew_bin=$(_brew_find)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    output=$("$brew_bin" update 2>&1)
    status=$?
    printf '%s\n' "$output"
    [ "$status" -eq 0 ] || fatal "$status"
    BREW_METADATA_REFRESHED=1
    export HOMEBREW_NO_AUTO_UPDATE=1
    printf '%s\n' "$output" | grep -Fqx 'Already up-to-date.' && return 1
    return 0
}
