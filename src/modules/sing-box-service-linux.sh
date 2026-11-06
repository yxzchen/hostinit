#!/usr/bin/env bash

sing-box-service_is_installed() {
    local prefix

    prefix=$(brew --prefix sing-box 2>/dev/null) || return 1
    [ -x "$prefix/bin/sing-box" ] &&
        [ -f /etc/sing-box/config.json ] &&
        [ -f /etc/systemd/system/sing-box.service ] &&
        systemctl is-enabled --quiet sing-box.service
}

sing-box-service_install() (
    local binary
    local config_action=preserved
    local prefix
    local status
    local temp_dir

    command -v systemctl >/dev/null 2>&1 || fatal 1 'sing-box service requires systemd'
    command -v brew >/dev/null 2>&1 || fatal 1 'Install sing-box with Homebrew before registering its service'
    prefix=$(brew --prefix sing-box)
    status=$?
    [ "$status" -eq 0 ] || fatal "$status" 'Could not locate the Homebrew sing-box prefix'
    binary="$prefix/bin/sing-box"
    [ -x "$binary" ] || fatal 1 'Install sing-box with Homebrew before registering its service'

    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-sing-box.XXXXXX") || fatal $?
    trap 'rm -rf "$temp_dir"' EXIT

    if [ ! -e /etc/sing-box/config.json ]; then
        printf '%s\n' '{}' >"$temp_dir/config.json" || fatal $?
        run_as_root install -d -m 0755 /etc/sing-box
        run_as_root install -m 0600 "$temp_dir/config.json" /etc/sing-box/config.json
        config_action=created
    fi
    run_as_root install -d -m 0755 /var/lib/sing-box

    # Quote the binary path for systemd and escape its specifier character.
    binary=${binary//%/%%}
    binary=${binary//\\/\\\\}
    binary=${binary//\"/\\\"}
    printf '%s\n' \
        '[Unit]' \
        'Description=sing-box service' \
        'Wants=network-online.target' \
        'After=network-online.target' \
        '' \
        '[Service]' \
        'Type=simple' \
        "ExecStart=\"${binary}\" run --config /etc/sing-box/config.json --directory /var/lib/sing-box" \
        'Restart=on-failure' \
        'RestartSec=5s' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' >"$temp_dir/sing-box.service" || fatal $?
    print_step 'Registering the sing-box systemd service'
    run_as_root install -m 0644 "$temp_dir/sing-box.service" /etc/systemd/system/sing-box.service
    run_as_root systemctl daemon-reload
    run_as_root systemctl enable sing-box.service
    print_info "Configuration: /etc/sing-box/config.json (${config_action})"
    print_info 'Service: /etc/systemd/system/sing-box.service (autostart enabled)'
    print_action_required $'Edit /etc/sing-box/config.json, then run:\n  sudo systemctl start sing-box.service'
)
