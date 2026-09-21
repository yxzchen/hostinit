#!/usr/bin/env bash

_frp_systemd_is_installed() {
    local component=$1

    command -v "$component" >/dev/null 2>&1 &&
        [ -f "/etc/frp/${component}.toml" ] &&
        [ -f "/etc/systemd/system/${component}.service" ] &&
        systemctl is-enabled --quiet "${component}.service"
}

_frp_systemd_create_config() {
    local component=$1
    local destination="/etc/frp/${component}.toml"
    local status
    local template
    local temp_dir

    [ -e "$destination" ] && return 0
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-frp-config.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    template="$temp_dir/${component}.toml"
    case "$component" in
        frpc)
            printf '%s\n' \
                'serverAddr = "127.0.0.1"' \
                'serverPort = 7000' \
                '' \
                '# [[proxies]]' \
                '# name = "ssh"' \
                '# type = "tcp"' \
                '# localIP = "127.0.0.1"' \
                '# localPort = 22' \
                '# remotePort = 6000' >"$template"
            ;;
        frps)
            printf '%s\n' \
                'bindPort = 7000' \
                '' \
                '# auth.method = "token"' \
                '# auth.token = "replace-me"' >"$template"
            ;;
    esac
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    run_as_root install -d -m 0755 /etc/frp
    run_as_root install -m 0640 "$template" "$destination"
    rm -rf "$temp_dir"
}

_frp_systemd_print_next_step() {
    local component=$1

    printf '\n\033[1;33mACTION REQUIRED:\033[0m\n'
    printf 'Edit /etc/frp/%s.toml, then start the registered service:\n' "$component"
    printf '  sudo systemctl start %s.service\n' "$component"
    printf '\n'
}

_frp_systemd_register() {
    local binary
    local component=$1
    local description
    local destination="/etc/systemd/system/${component}.service"
    local status
    local temp_dir
    local unit

    binary=$(command -v "$component")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    case "$component" in
        frpc) description='FRP client' ;;
        frps) description='FRP server' ;;
    esac
    _frp_systemd_create_config "$component"
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-frp-service.XXXXXX")
    status=$?
    [ "$status" -eq 0 ] || fatal "$status"
    unit="$temp_dir/${component}.service"
    printf '%s\n' \
        '[Unit]' \
        "Description=${description}" \
        'Wants=network-online.target' \
        'After=network-online.target' \
        '' \
        '[Service]' \
        'Type=simple' \
        "ExecStart=${binary} -c /etc/frp/${component}.toml" \
        'Restart=on-failure' \
        'RestartSec=5s' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' >"$unit"
    status=$?
    [ "$status" -eq 0 ] || { rm -rf "$temp_dir"; fatal "$status"; }
    run_as_root install -m 0644 "$unit" "$destination"
    rm -rf "$temp_dir"
    run_as_root systemctl daemon-reload
    run_as_root systemctl enable "${component}.service"
    _frp_systemd_print_next_step "$component"
}

frpc-service_is_installed() {
    _frp_systemd_is_installed frpc
}

frpc-service_install() {
    _frp_systemd_register frpc
}

frps-service_is_installed() {
    _frp_systemd_is_installed frps
}

frps-service_install() {
    _frp_systemd_register frps
}
