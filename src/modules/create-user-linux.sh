#!/usr/bin/env bash

create-user_install() {
    local notice
    local notice_dir
    local status
    local username
    local root_command=(bash)

    while :; do
        print_prompt 'New username:'
        if ! IFS= read -r username; then
            printf '\n' >&2
            set_operation_result skipped 'canceled before creating a user'
            return 0
        fi
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || [ "${#username}" -gt 32 ]; then
            print_info 'Use 1-32 lowercase letters, digits, underscores or hyphens; start with a letter or underscore'
        elif getent passwd "$username" >/dev/null; then
            print_info "User ${username} already exists. Choose a new username"
        else
            break
        fi
    done

    if ! command -v sudo >/dev/null 2>&1; then
        refresh_apt_metadata
        run_as_root apt-get install -y sudo
    fi

    notice_dir=$(mktemp -d "${TMPDIR:-/tmp}/hostinit-user-notices.XXXXXX") || fatal $? 'Could not create a temporary directory for user setup'
    : >"$notice_dir/actions"
    [ "$EUID" -eq 0 ] || root_command=(sudo bash)
    print_step "Creating user ${username} with passwordless sudo"
    "${root_command[@]}" -s -- "$username" "$notice_dir/actions" <<'CREATE_USER'
set -eu

username=$1
notice_file=$2
destination="/etc/sudoers.d/90-hostinit-${username}"
temporary=''
created=0
completed=0

require_action() {
    printf '%s\n' "$1" >>"$notice_file" || printf 'Action required:\n  %s\n' "$1" >&2
}

cleanup_create_user() {
    status=$?
    trap - EXIT
    if [ "$completed" -eq 0 ]; then
        if [ -n "$temporary" ] && [ "$temporary" -ef "$destination" ]; then
            if ! rm -f -- "$destination"; then
                require_action "Could not remove sudoers file ${destination}; remove it manually"
            fi
        fi
        if [ "$created" -eq 1 ]; then
            if userdel -r -- "$username"; then
                created=0
                printf 'Rollback: Removed user %s and its home directory.\n' "$username" >&2
            else
                rollback_status=$?
                require_action "Could not fully remove user ${username} (userdel exit ${rollback_status}); check the account and /home/${username} manually"
            fi
        fi
    fi
    [ -z "$temporary" ] || rm -f -- "$temporary"
    exit "$status"
}
trap cleanup_create_user EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Recheck under root before changing any account or sudoers files.
if getent passwd "$username" >/dev/null; then
    printf 'Error: User %s already exists.\n' "$username" >&2
    exit 1
fi
if [ -e "$destination" ] || [ -L "$destination" ] ||
    [ -e "/home/$username" ] || [ -L "/home/$username" ]; then
    printf 'Error: A home directory or sudoers file for %s already exists.\n' "$username" >&2
    exit 1
fi

visudo -c
install -d -m 0755 /etc/sudoers.d
# A dot in the temporary filename keeps sudo from loading an unfinished rule.
temporary=$(mktemp /etc/sudoers.d/.hostinit-user.XXXXXX)
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" >"$temporary"
chown root:root "$temporary"
chmod 0440 "$temporary"
visudo -cf "$temporary"

useradd --create-home --user-group --home-dir "/home/$username" --shell /bin/bash -- "$username"
created=1
printf 'Set the login password for %s (sudo will not ask for it):\n' "$username" >&2
passwd "$username" </dev/tty

# Publish atomically without replacing an existing rule.
ln -T -- "$temporary" "$destination"
visudo -c
# Also catches systems whose sudoers configuration does not include sudoers.d.
sudo -u "$username" -- sudo -n -- true
completed=1
CREATE_USER
    status=$?
    while IFS= read -r notice; do
        print_action_required "$notice"
    done <"$notice_dir/actions"
    rm -rf "$notice_dir"
    [ "$status" -eq 0 ] || fatal "$status" "Could not finish creating user ${username} (exit ${status})"
    print_info "Created ${username} with home directory /home/${username} and passwordless sudo"
}
