#!/usr/bin/env bash

_warp_codename() {
    _os_release_value VERSION_CODENAME || fatal $?
}

_warp_configure() {
    if ! warp-cli --accept-tos registration show >/dev/null 2>&1; then
        run_checked warp-cli --accept-tos registration new
    fi
    run_checked warp-cli --accept-tos mode proxy
    run_checked warp-cli --accept-tos proxy port 40000
    run_checked warp-cli --accept-tos connect
}

_warp_refresh_key() {
    local actual_fingerprint
    local dearmored
    local key
    local status
    local temp_dir

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-warp-key.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    key=$temp_dir/key.gpg
    dearmored=$temp_dir/keyring.gpg

    curl --fail --show-error --silent --location \
        --connect-timeout 10 --retry 3 --proto '=https' --tlsv1.2 \
        'https://pkg.cloudflareclient.com/pubkey.gpg' -o "$key"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    actual_fingerprint=$(gpg --batch --show-keys --with-colons "$key" |
        awk -F: '$1 == "fpr" {print $10; exit}')
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    if [ "$actual_fingerprint" != C068A2B5771775193CBE1F2F6E2DD2174FA1C3BA ]; then
        rm -rf "$temp_dir"
        fatal 1
    fi
    gpg --batch --yes --dearmor --output "$dearmored" "$key"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    run_as_root install -m 0644 "$dearmored" \
        /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -rf "$temp_dir"
}

_warp_install_package() {
    local arch
    local codename
    local source
    local status
    local temp_dir

    arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64|arm64) ;;
        *) fatal 1 ;;
    esac
    codename=$(_warp_codename)
    _warp_refresh_key

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-warp-source.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    source=$temp_dir/cloudflare-client.list
    printf 'deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] ' >"$source"
    printf 'https://pkg.cloudflareclient.com/ %s main\n' "$codename" >>"$source"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    run_as_root install -m 0644 "$source" /etc/apt/sources.list.d/cloudflare-client.list
    rm -rf "$temp_dir"
    run_as_root apt-get update
    run_as_root apt-get install -y cloudflare-warp
}

warp_is_installed() {
    apt_package_installed cloudflare-warp &&
        systemctl is-enabled --quiet warp-svc.service &&
        systemctl is-active --quiet warp-svc.service &&
        warp-cli --accept-tos registration show >/dev/null 2>&1
}

warp_install() {
    apt_package_installed cloudflare-warp || _warp_install_package
    run_as_root systemctl enable --now warp-svc.service
    _warp_configure
}

warp_update() {
    local after
    local before
    local status

    _warp_refresh_key
    refresh_apt_metadata
    apt_package_has_update cloudflare-warp || return 1
    before=$(dpkg-query -W -f='${Version}' cloudflare-warp)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    run_as_root apt-get install --only-upgrade -y cloudflare-warp
    after=$(dpkg-query -W -f='${Version}' cloudflare-warp)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    [ "$after" != "$before" ] || return 1
    run_as_root systemctl enable --now warp-svc.service
    _warp_configure
    return 0
}
