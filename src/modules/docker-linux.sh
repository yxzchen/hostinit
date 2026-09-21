#!/usr/bin/env bash

_docker_components_installed() {
    apt_package_installed docker-ce &&
        apt_package_installed docker-ce-cli &&
        apt_package_installed containerd.io
}

_docker_codename() {
    _os_release_value VERSION_CODENAME || fatal $?
}

_docker_configure_service() {
    local user
    local user_groups

    print_step 'Configuring the Docker service and user access'
    run_as_root systemctl enable docker
    run_as_root systemctl start docker
    user=$(id -un)
    [ "$user" = root ] && return 0
    user_groups=$(id -nG "$user")
    case " $user_groups " in
        *' docker '*) ;;
        *)
            run_as_root usermod -aG docker "$user"
            print_action_required 'Sign out and sign in again before using Docker without sudo'
            ;;
    esac
}

_docker_setup_repository() {
    local actual_fingerprint
    local arch
    local codename
    local gnupg_home
    local key
    local source
    local status
    local temp_dir

    print_step 'Configuring the Docker package repository'
    arch=$(dpkg --print-architecture) || fatal $? 'Could not determine the package architecture'
    codename=$(_docker_codename) || fatal $? 'Could not determine the distribution codename'
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-docker.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    key=$temp_dir/docker.asc
    source=$temp_dir/docker.list
    gnupg_home=$temp_dir/gnupg
    mkdir -m 0700 "$gnupg_home"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    curl --fail --show-error --silent --location \
        --connect-timeout 10 --retry 3 --proto '=https' --tlsv1.2 \
        "https://download.docker.com/linux/${PLATFORM}/gpg" -o "$key"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    actual_fingerprint=$(GNUPGHOME="$gnupg_home" gpg --batch --show-keys --with-colons "$key" |
        awk -F: '$1 == "fpr" && !fingerprint {fingerprint = $10} END {print fingerprint}')
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    if [ "$actual_fingerprint" != 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 ]; then
        rm -rf "$temp_dir"
        fatal 1 'The Docker repository signing key has an unexpected fingerprint'
    fi
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] ' "$arch" >"$source"
    printf 'https://download.docker.com/linux/%s %s stable\n' \
        "$PLATFORM" "$codename" >>"$source"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    run_as_root install -d -m 0755 /etc/apt/keyrings
    run_as_root install -m 0644 "$key" /etc/apt/keyrings/docker.asc
    run_as_root install -m 0644 "$source" /etc/apt/sources.list.d/docker.list
    rm -rf "$temp_dir"
}

_docker_install_missing_components() {
    local package
    local missing=()

    for package in docker-ce docker-ce-cli containerd.io; do
        apt_package_installed "$package" || missing[${#missing[@]}]=$package
    done
    [ "${#missing[@]}" -gt 0 ] || return 0
    _docker_setup_repository
    run_as_root apt-get update
    for package in "${missing[@]}"; do
        apt-cache policy "$package" | awk '$1 == "Candidate:" && $2 != "(none)" {found = 1} END {exit !found}'
        [ "$?" -eq 0 ] || fatal 1
    done
    print_step 'Installing Docker components'
    run_as_root apt-get install -y --no-install-recommends "${missing[@]}"
}

docker_is_installed() {
    local user
    local user_groups

    _docker_components_installed || return 1
    systemctl is-enabled --quiet docker || return 1
    systemctl is-active --quiet docker || return 1
    user=$(id -un)
    [ "$user" = root ] && return 0
    user_groups=$(id -nG "$user")
    case " $user_groups " in
        *' docker '*) return 0 ;;
        *) return 1 ;;
    esac
}

docker_install() {
    _docker_install_missing_components
    _docker_configure_service
}

docker_update() {
    local after
    local before
    local package
    local status
    local update_available=0

    refresh_apt_metadata
    for package in docker-ce docker-ce-cli containerd.io; do
        if apt_package_has_update "$package"; then
            update_available=1
            break
        fi
    done
    [ "$update_available" -eq 1 ] || return 1
    print_step 'Updating Docker components'
    before=$(dpkg-query -W -f='${binary:Package}=${Version}\n' \
        docker-ce docker-ce-cli containerd.io)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    run_as_root apt-get install --only-upgrade -y docker-ce docker-ce-cli containerd.io
    after=$(dpkg-query -W -f='${binary:Package}=${Version}\n' \
        docker-ce docker-ce-cli containerd.io)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    [ "$after" != "$before" ] || return 1
    _docker_configure_service
    return 0
}
