#!/usr/bin/env bash

_dotfiles_zshrc_loads_local() {
    [ -f "$1" ] && grep -Eq '^[[:space:]]*[^#[:space:]].*\.zshrc\.local' "$1"
}

_dotfiles_gitconfig_includes_local() {
    local include
    local includes

    [ -f "$1" ] || return 1
    includes=$(git config --file "$1" --get-all include.path 2>/dev/null)
    while IFS= read -r include; do
        case "$include" in
            '~/.gitconfig.local'|'$HOME/.gitconfig.local'|.gitconfig.local|./.gitconfig.local|"$HOME/.gitconfig.local")
                return 0
                ;;
        esac
    done <<<"$includes"
    return 1
}

_dotfiles_set_expected_files() {
    DOTFILES_EXPECTED_FILES=(.zimrc .zshrc.local .gitconfig.local)
    case "$PLATFORM" in
        debian|ubuntu)
            DOTFILES_EXPECTED_FILES[${#DOTFILES_EXPECTED_FILES[@]}]=.zshenv
            ;;
    esac
}

dotfiles_is_installed() {
    local filename

    _dotfiles_set_expected_files
    for filename in "${DOTFILES_EXPECTED_FILES[@]}"; do
        [ -f "$HOME/$filename" ] || return 1
    done
    return 0
}

dotfiles_needs_update() {
    return 0
}

dotfiles_install() {
    local base_url=${DOTFILES_BASE_URL:-https://raw.githubusercontent.com/yxzchen/hostinit/master/dotfiles}
    local filename
    local gitconfig=$HOME/.gitconfig
    local local_loader='[[ -r "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"'
    local source_dir
    local status
    local temp_dir
    local zim_home=${ZIM_HOME:-$HOME/.zim}

    _dotfiles_set_expected_files
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-dotfiles.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    source_dir=$temp_dir/dotfiles
    mkdir -p "$source_dir"
    status=$?
    if [ "$status" -ne 0 ]; then
        rm -rf "$temp_dir"
        fatal "$status"
    fi

    for filename in "${DOTFILES_EXPECTED_FILES[@]}"; do
        curl --fail --show-error --silent --location \
            --connect-timeout 10 --retry 3 --proto '=https' --tlsv1.2 \
            "$base_url/$filename" -o "$source_dir/$filename"
        status=$?
        if [ "$status" -ne 0 ]; then
            rm -rf "$temp_dir"
            fatal "$status"
        fi
    done
    for filename in "${DOTFILES_EXPECTED_FILES[@]}"; do
        install -m 0644 "$source_dir/$filename" "$HOME/$filename"
        status=$?
        if [ "$status" -ne 0 ]; then
            rm -rf "$temp_dir"
            fatal "$status"
        fi
    done
    rm -rf "$temp_dir"

    if ! _dotfiles_zshrc_loads_local "$HOME/.zshrc"; then
        printf '\n%s\n%s\n' \
            '# Load custom Zsh configuration.' \
            "$local_loader" >>"$HOME/.zshrc"
        status=$?
        [ "$status" -eq 0 ] || fatal "$status"
    fi
    if ! _dotfiles_gitconfig_includes_local "$gitconfig"; then
        run_checked git config --file "$gitconfig" --add include.path .gitconfig.local
    fi
    if [ -f "$zim_home/zimfw.zsh" ]; then
        run_checked env ZIM_HOME="$zim_home" ZIM_CONFIG_FILE="$HOME/.zimrc" \
            zsh -c 'source "$1" install -q' -- "$zim_home/zimfw.zsh"
    fi
}

dotfiles_update() {
    dotfiles_install
}
