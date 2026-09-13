apt_command() {
    if [ "$EUID" -eq 0 ]; then
        apt-get "$@"
    else
        sudo apt-get "$@"
    fi
}

refresh_apt_metadata() {
    local status

    [ "$APT_METADATA_REFRESHED" -eq 0 ] || return 0
    print_step 'refreshing:' 'apt metadata'
    apt_command update
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    APT_METADATA_REFRESHED=1
}

refresh_brew_metadata() {
    local status

    [ "$BREW_METADATA_REFRESHED" -eq 0 ] || return 0
    print_step 'refreshing:' 'brew metadata'
    brew update
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    BREW_METADATA_REFRESHED=1
    export HOMEBREW_NO_AUTO_UPDATE=1
}

apt_package_installed() {
    local output
    local status

    if [ "$APT_INSTALLED_CACHE_READY" -eq 0 ]; then
        output=$(dpkg-query -W -f='${binary:Package}\t${Status}\n' 2>&1)
        status=$?
        [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return "$status"; }
        APT_INSTALLED_PACKAGES=$(printf '%s\n' "$output" | awk '
            $2 == "install" && $3 == "ok" && $4 == "installed" {
                print $1
                package = $1
                sub(/:[^:]+$/, "", package)
                if (package != $1) print package
            }
        ')
        status=$?
        [ "$status" -eq 0 ] || return "$status"
        APT_INSTALLED_CACHE_READY=1
    fi

    installed_list_contains "$APT_INSTALLED_PACKAGES" "$1"
}

apt_package_has_update() {
    local candidate
    local installed
    local policy
    local status

    installed=$(dpkg-query -W -f='${Version}' "$1" 2>&1)
    status=$?
    [ "$status" -eq 0 ] || { printf '%s\n' "$installed" >&2; exit "$status"; }
    policy=$(LC_ALL=C apt-cache policy "$1" 2>&1)
    status=$?
    [ "$status" -eq 0 ] || { printf '%s\n' "$policy" >&2; exit "$status"; }
    candidate=$(printf '%s\n' "$policy" |
        awk '$1 == "Candidate:" {print $2; exit}')
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    [ -n "$candidate" ] && [ "$candidate" != '(none)' ] || return 1
    dpkg --compare-versions "$candidate" gt "$installed"
    status=$?
    case "$status" in
        0) return 0 ;;
        1) return 1 ;;
        *) exit "$status" ;;
    esac
}

installed_list_contains() {
    local installed=$1
    local package=$2

    case $'\n'"$installed"$'\n' in
        *$'\n'"$package"$'\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

package_manager_label() {
    case "$1" in
        apt) printf 'apt' ;;
        brew:formula) printf 'brew' ;;
        brew:cask) printf 'brew cask' ;;
        *) return 1 ;;
    esac
}

package_is_installed() {
    local kind=$1
    local package=$2

    case "$kind" in
        apt) apt_package_installed "$package" ;;
        brew:formula) brew_formula_installed "$package" ;;
        brew:cask) brew_cask_installed "$package" ;;
        *) return 2 ;;
    esac
}

tool_package_kind() {
    local source=${TOOL_SOURCES[$1]}

    if [ "$source" = brew ]; then
        printf 'brew:%s' "${TOOL_BREW_TYPES[$1]}"
    else
        printf '%s' "$source"
    fi
}

load_brew_installed_cache() {
    local brew_bin
    local output
    local status

    [ "$BREW_INSTALLED_CACHE_READY" -eq 0 ] || return 0
    if command -v _brew_find >/dev/null 2>&1; then
        if ! brew_bin=$(_brew_find); then
            BREW_INSTALLED_CACHE_READY=1
            return 0
        fi
    else
        if ! brew_bin=$(command -v brew); then
            BREW_INSTALLED_CACHE_READY=1
            return 0
        fi
    fi

    output=$("$brew_bin" list --formula 2>&1)
    status=$?
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return "$status"; }
    BREW_INSTALLED_FORMULAE=$output

    output=$("$brew_bin" list --cask 2>&1)
    status=$?
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return "$status"; }
    BREW_INSTALLED_CASKS=$output
    BREW_INSTALLED_CACHE_READY=1
}

brew_formula_installed() {
    load_brew_installed_cache || return $?
    installed_list_contains "$BREW_INSTALLED_FORMULAE" "$1"
}

brew_cask_installed() {
    load_brew_installed_cache || return $?
    installed_list_contains "$BREW_INSTALLED_CASKS" "$1"
}

tool_is_installed() {
    local is_installed_function
    local kind
    local package
    local status
    local tool_index=$1

    if [ "${TOOL_SOURCES[$tool_index]}" = custom ]; then
        is_installed_function="${TOOL_NAMES[$tool_index]}_is_installed"
        "$is_installed_function"
        return $?
    fi

    BATCH_PACKAGES=()
    append_tool_packages "$tool_index"
    kind=$(tool_package_kind "$tool_index") || return $?
    for package in "${BATCH_PACKAGES[@]}"; do
        package_is_installed "$kind" "$package"
        status=$?
        case "$status" in
            0) ;;
            1) return 1 ;;
            *) return "$status" ;;
        esac
    done
    return 0
}

brew_outdated_contains() {
    local line
    local outdated=$1
    local package=$2

    while IFS= read -r line; do
        [ "$line" = "$package" ] && return 0
    done <<<"$outdated"
    return 1
}

update_apt_packages() {
    local package
    local status
    local -a current_packages
    local -a update_packages

    current_packages=()
    update_packages=()
    for package in "$@"; do
        if apt_package_has_update "$package"; then
            update_packages[${#update_packages[@]}]=$package
        else
            current_packages[${#current_packages[@]}]=$package
        fi
    done

    if [ "${#update_packages[@]}" -eq 0 ]; then
        print_skip 'not updated (apt):' "${current_packages[@]}"
        return 1
    fi
    print_step 'updating (apt):' "${update_packages[@]}"
    apt_command install --only-upgrade -y "${update_packages[@]}"
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    print_success 'updated (apt):' "${update_packages[@]}"
    if [ "${#current_packages[@]}" -gt 0 ]; then
        print_skip 'not updated (apt):' "${current_packages[@]}"
    fi
    return 0
}

update_brew_packages() {
    local kind=$1
    local manager
    local outdated
    local package
    local status
    local -a current_packages
    local -a packages
    local -a update_packages

    shift
    manager=$(package_manager_label "$kind") || exit $?
    packages=("$@")
    current_packages=()
    update_packages=()
    case "$kind" in
        brew:formula)
            outdated=$(brew outdated --formula --quiet "${packages[@]}" 2>&1)
            ;;
        brew:cask)
            outdated=$(brew outdated --cask --quiet "${packages[@]}" 2>&1)
            ;;
    esac
    status=$?
    [ "$status" -eq 0 ] || { printf '%s\n' "$outdated" >&2; exit "$status"; }

    for package in "${packages[@]}"; do
        if brew_outdated_contains "$outdated" "$package"; then
            update_packages[${#update_packages[@]}]=$package
        else
            current_packages[${#current_packages[@]}]=$package
        fi
    done
    if [ "${#update_packages[@]}" -eq 0 ]; then
        print_skip "not updated (${manager}):" "${current_packages[@]}"
        return 1
    fi

    print_step "updating (${manager}):" "${update_packages[@]}"
    case "$kind" in
        brew:formula)
            brew upgrade "${update_packages[@]}"
            ;;
        brew:cask)
            brew upgrade --cask "${update_packages[@]}"
            ;;
    esac
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    print_success "updated (${manager}):" "${update_packages[@]}"
    if [ "${#current_packages[@]}" -gt 0 ]; then
        print_skip "not updated (${manager}):" "${current_packages[@]}"
    fi
    return 0
}

filter_batch_packages() {
    local kind=$1
    local manager
    local mode=$2
    local package
    local installed
    local index=0
    local -a skipped_packages

    FILTERED_PACKAGES=()
    skipped_packages=()
    manager=$(package_manager_label "$kind") || return $?
    while [ "$index" -lt "${#BATCH_PACKAGES[@]}" ]; do
        package=${BATCH_PACKAGES[$index]}
        installed=1
        package_is_installed "$kind" "$package" && installed=0

        if { [ "$mode" = 'install' ] && [ "$installed" -ne 0 ]; } ||
            { [ "$mode" = 'update' ] && [ "$installed" -eq 0 ]; }; then
            FILTERED_PACKAGES[${#FILTERED_PACKAGES[@]}]=$package
        else
            skipped_packages[${#skipped_packages[@]}]=$package
        fi
        index=$((index + 1))
    done

    if [ "${#skipped_packages[@]}" -gt 0 ]; then
        if [ "$mode" = install ]; then
            print_skip 'skipped:' "${skipped_packages[@]}"
        else
            print_skip "not updated (${manager}, not installed):" "${skipped_packages[@]}"
        fi
    fi
}

run_package_batch() {
    local kind=$1
    local manager
    local mode=$2
    local status

    shift 2
    manager=$(package_manager_label "$kind") || exit $?
    BATCH_PACKAGES=()
    while [ "$#" -gt 0 ]; do
        append_tool_packages "$1"
        shift
    done
    filter_batch_packages "$kind" "$mode"
    if [ "${#FILTERED_PACKAGES[@]}" -eq 0 ]; then
        [ "$mode" = update ] && return 1
        return 0
    fi

    case "$kind:$mode" in
        apt:install)
            refresh_apt_metadata
            print_step 'installing (apt):' "${FILTERED_PACKAGES[@]}"
            apt_command install -y "${FILTERED_PACKAGES[@]}"
            ;;
        apt:update)
            refresh_apt_metadata
            update_apt_packages "${FILTERED_PACKAGES[@]}"
            ;;
        brew:formula:install)
            refresh_brew_metadata
            print_step 'installing (brew):' "${FILTERED_PACKAGES[@]}"
            brew install --no-ask "${FILTERED_PACKAGES[@]}"
            ;;
        brew:formula:update)
            refresh_brew_metadata
            update_brew_packages brew:formula "${FILTERED_PACKAGES[@]}"
            ;;
        brew:cask:install)
            refresh_brew_metadata
            print_step 'installing (brew cask):' "${FILTERED_PACKAGES[@]}"
            brew install --cask --no-ask "${FILTERED_PACKAGES[@]}"
            ;;
        brew:cask:update)
            refresh_brew_metadata
            update_brew_packages brew:cask "${FILTERED_PACKAGES[@]}"
            ;;
    esac
    status=$?
    if [ "$mode" = update ] && [ "$status" -eq 1 ]; then
        return 1
    fi
    [ "$status" -eq 0 ] || exit "$status"
    if [ "$mode" = install ]; then
        case "$kind" in
            apt) APT_INSTALLED_CACHE_READY=0 ;;
            brew:formula|brew:cask) BREW_INSTALLED_CACHE_READY=0 ;;
        esac
    fi
    if [ "$mode" = install ]; then
        print_success "installed (${manager}):" "${FILTERED_PACKAGES[@]}"
    fi
}
