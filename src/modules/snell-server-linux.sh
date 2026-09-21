#!/usr/bin/env bash

snell-server_is_installed() {
    [ -x /usr/local/bin/snell-server ] &&
        [ -f /etc/snell/snell.conf ] &&
        [ -f /etc/systemd/system/snell.service ]
}

_snell_server_install_files() (
    local arch
    local config_action=preserved
    local psk
    local status
    local temp_dir

    set -o pipefail
    arch=$(uname -m) || fatal $?
    case "$arch" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=aarch64 ;;
        *)
            fatal 1 "Snell Server supports only amd64 and aarch64 (detected: ${arch})"
            ;;
    esac
    if ! command -v systemctl >/dev/null 2>&1; then
        fatal 1 'Snell Server requires systemd'
    fi

    for dependency in curl unzip tr head mktemp install cat rm; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            fatal 1 "Snell Server requires ${dependency}; install it before continuing"
        fi
    done

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-snell.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    trap 'rm -rf "$temp_dir"' EXIT

    print_step 'Downloading Snell Server'
    run_checked curl --fail --show-error --silent --location \
        --connect-timeout 10 --retry 3 --proto '=https' --tlsv1.2 \
        "https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-${arch}.zip" \
        -o "$temp_dir/snell-server.zip"
    run_checked unzip -q "$temp_dir/snell-server.zip" snell-server -d "$temp_dir"

    if [ ! -e /etc/snell/snell.conf ]; then
        set +o pipefail
        psk=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
        status=$?
        set -o pipefail
        [ "$status" -eq 0 ] || fatal "$status"
        [ "${#psk}" -eq 32 ] || fatal 1
        printf '%s\n' \
            '[snell-server]' \
            'listen = 0.0.0.0:5506' \
            "psk = ${psk}" \
            'ipv6 = false' >"$temp_dir/snell.conf" || fatal $?
        run_as_root install -d -m 0755 /etc/snell
        run_as_root install -m 0600 "$temp_dir/snell.conf" /etc/snell/snell.conf
        config_action=created
    fi

    printf '%s\n' \
        '[Unit]' \
        'Description=Snell Server' \
        'Wants=network-online.target' \
        'After=network-online.target' \
        '' \
        '[Service]' \
        'Type=simple' \
        'ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell.conf' \
        'Restart=on-failure' \
        'RestartSec=5s' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' >"$temp_dir/snell.service" || fatal $?
    print_step 'Installing Snell Server files and registering the service'
    run_as_root install -d -m 0755 /usr/local/bin
    run_as_root install -m 0755 "$temp_dir/snell-server" /usr/local/bin/snell-server
    run_as_root install -m 0644 "$temp_dir/snell.service" \
        /etc/systemd/system/snell.service
    run_as_root systemctl daemon-reload
    run_as_root systemctl enable snell.service
    print_info 'Binary: /usr/local/bin/snell-server'
    print_info 'Service: /etc/systemd/system/snell.service (autostart enabled)'
    print_info "Configuration: /etc/snell/snell.conf (${config_action})"
)

snell-server_install() {
    print_step 'Installing Snell Server'
    _snell_server_install_files || return $?
    print_action_required $'Review /etc/snell/snell.conf, then run:\n  sudo systemctl start snell.service'
}
