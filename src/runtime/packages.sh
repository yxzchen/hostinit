apt_command() {
    if [ "$EUID" -eq 0 ]; then
        apt-get "$@"
    else
        sudo apt-get "$@"
    fi
}

refresh_apt_metadata() {
    [ "$APT_METADATA_REFRESHED" -eq 0 ] || return 0
    print_step 'Refreshing apt metadata'
    run_checked apt_command update
    APT_METADATA_REFRESHED=1
}

refresh_brew_metadata() {
    [ "$BREW_METADATA_REFRESHED" -eq 0 ] || return 0
    print_step 'Refreshing Homebrew metadata'
    run_checked brew update
    BREW_METADATA_REFRESHED=1
    export HOMEBREW_NO_AUTO_UPDATE=1
}

apt_package_installed() {
    local output
    local status

    if [ "$APT_INSTALLED_CACHE_READY" -eq 0 ]; then
        output=$(dpkg-query -W -f='${binary:Package}\t${Status}\n' 2>&1)
        status=$?
        if [ "$status" -ne 0 ]; then
            restore_terminal
            print_info "$output"
            fatal "$status" 'Could not read installed apt packages'
        fi
        APT_INSTALLED_PACKAGES=$(printf '%s\n' "$output" | awk '
            $2 == "install" && $3 == "ok" && $4 == "installed" {
                print $1
                package = $1
                sub(/:[^:]+$/, "", package)
                if (package != $1) print package
            }
        ')
        status=$?
        [ "$status" -eq 0 ] || fatal "$status" 'Could not parse the installed apt package list'
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
    [ "$status" -eq 0 ] || { print_info "$installed"; fatal "$status" "Could not read the installed version of $1"; }
    policy=$(LC_ALL=C apt-cache policy "$1" 2>&1)
    status=$?
    [ "$status" -eq 0 ] || { print_info "$policy"; fatal "$status" "Could not read available versions of $1"; }
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
    if [ "$status" -ne 0 ]; then
        restore_terminal
        print_info "$output"
        fatal "$status" 'Could not read installed Homebrew formulae'
    fi
    BREW_INSTALLED_FORMULAE=$output

    output=$("$brew_bin" list --cask 2>&1)
    status=$?
    if [ "$status" -ne 0 ]; then
        restore_terminal
        print_info "$output"
        fatal "$status" 'Could not read installed Homebrew casks'
    fi
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

# Custom modules expose only supported actions. Updates also require an
# installation check; actions without one remain available in install mode.
tool_supports_action() {
    local tool_index=$1
    local action=$2

    [ "${TOOL_SOURCES[$tool_index]}" = custom ] || return 0
    declare -F "${TOOL_NAMES[$tool_index]}_${action}" >/dev/null || return 1
    if [ "$action" = update ]; then
        declare -F "${TOOL_NAMES[$tool_index]}_is_installed" >/dev/null || return 1
    fi
    return 0
}

tool_is_installed() {
    local kind
    local package
    local tool_index=$1

    if [ "${TOOL_SOURCES[$tool_index]}" = custom ]; then
        declare -F "${TOOL_NAMES[$tool_index]}_is_installed" >/dev/null || return 1
        "${TOOL_NAMES[$tool_index]}_is_installed"
        return $?
    fi

    BATCH_PACKAGES=()
    append_tool_packages "$tool_index"
    kind=$(tool_package_kind "$tool_index") || return $?
    for package in "${BATCH_PACKAGES[@]}"; do
        package_is_installed "$kind" "$package" || return $?
    done
    return 0
}

filter_package_updates() {
    local kind=$1
    local outdated=''
    local package
    local status

    UPDATE_TARGETS=()
    print_step 'Checking package updates'
    case "$kind" in
        brew:*)
            outdated=$(brew outdated "--${kind#brew:}" --quiet 2>&1)
            status=$?
            [ "$status" -eq 0 ] || {
                print_info "$outdated"
                fatal "$status" 'Could not check Homebrew updates'
            }
            ;;
    esac
    for package in "${FILTERED_PACKAGES[@]}"; do
        if [ "$kind" = apt ]; then
            apt_package_has_update "$package"
            status=$?
        else
            installed_list_contains "$outdated" "$package"
            status=$?
        fi
        case "$status" in
            0) UPDATE_TARGETS[${#UPDATE_TARGETS[@]}]=$package ;;
            1) ;;
            *) fatal "$status" "Could not check updates for ${package}" ;;
        esac
    done
}

run_package_batch() {
    local kind=$1
    local manager
    local mode=$2
    local status
    local tool_index
    local package
    local eligible
    local changed
    local planned=''
    local targets=''
    local -a tool_indexes
    local -a package_targets

    shift 2
    tool_indexes=("$@")
    begin_tools "${tool_indexes[@]}"
    manager=$(package_manager_label "$kind") || fatal 2 "Unknown package manager: ${kind}"
    FILTERED_PACKAGES=()
    for tool_index in "${tool_indexes[@]}"; do
        BATCH_PACKAGES=()
        append_tool_packages "$tool_index"
        eligible=0
        for package in "${BATCH_PACKAGES[@]}"; do
            package_is_installed "$kind" "$package"
            status=$?
            case "$status" in
                0|1) ;;
                *) fatal "$status" "Could not check installation of ${package}" ;;
            esac
            if { [ "$mode" = install ] && [ "$status" -eq 1 ]; } ||
                { [ "$mode" = update ] && [ "$status" -eq 0 ]; }; then
                eligible=1
                if ! installed_list_contains "$planned" "$package"; then
                    FILTERED_PACKAGES[${#FILTERED_PACKAGES[@]}]=$package
                    planned="${planned}${planned:+$'\n'}${package}"
                fi
            fi
        done
        if [ "$eligible" -eq 0 ]; then
            if [ "$mode" = install ]; then
                record_result "$tool_index" skipped 'already installed'
            else
                record_result "$tool_index" skipped 'not installed'
            fi
        fi
    done
    [ "${#FILTERED_PACKAGES[@]}" -gt 0 ] || return 0

    case "$kind" in
        apt) refresh_apt_metadata ;;
        brew:*) refresh_brew_metadata ;;
    esac
    package_targets=("${FILTERED_PACKAGES[@]}")
    if [ "$mode" = update ]; then
        filter_package_updates "$kind"
        package_targets=("${UPDATE_TARGETS[@]}")
        for package in "${package_targets[@]}"; do
            targets="${targets}${targets:+$'\n'}${package}"
        done
        for tool_index in "${tool_indexes[@]}"; do
            [ "${REPORT_RESULTS[$tool_index]}" = running ] || continue
            BATCH_PACKAGES=()
            append_tool_packages "$tool_index"
            changed=0
            for package in "${BATCH_PACKAGES[@]}"; do
                if installed_list_contains "$targets" "$package"; then
                    changed=1
                    break
                fi
            done
            [ "$changed" -eq 1 ] || record_result "$tool_index" unchanged 'no updates available'
        done
    fi
    [ "${#package_targets[@]}" -gt 0 ] || return 0

    if [ "$mode" = install ]; then
        print_step "Installing packages (${manager}): ${package_targets[*]}"
        case "$kind" in
            apt) apt_command install -y "${package_targets[@]}" ;;
            brew:formula) brew install --no-ask "${package_targets[@]}" ;;
            brew:cask) brew install --cask --no-ask "${package_targets[@]}" ;;
        esac
    else
        print_step "Updating packages (${manager}): ${package_targets[*]}"
        case "$kind" in
            apt) apt_command install --only-upgrade -y "${package_targets[@]}" ;;
            brew:formula) brew upgrade "${package_targets[@]}" ;;
            brew:cask) brew upgrade --cask "${package_targets[@]}" ;;
        esac
    fi
    status=$?
    [ "$status" -eq 0 ] || fatal "$status" \
        "Could not complete ${mode} batch (${manager}, exit ${status}); some packages may have changed"
    APT_INSTALLED_CACHE_READY=0
    BREW_INSTALLED_CACHE_READY=0
    for tool_index in "${tool_indexes[@]}"; do
        [ "${REPORT_RESULTS[$tool_index]}" = running ] || continue
        if [ "$mode" = install ]; then
            record_result "$tool_index" installed
        else
            record_result "$tool_index" updated
        fi
    done
}
