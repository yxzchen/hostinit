#!/usr/bin/env bash

create-user_install() {
    local username

    while :; do
        printf 'New username: '
        IFS= read -r username || return 1
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || [ "${#username}" -gt 32 ]; then
            printf 'Use 1-32 lowercase letters, digits, underscores or hyphens; start with a letter or underscore.\n' >&2
        elif getent passwd "$username" >/dev/null; then
            printf 'User %s already exists. Choose a new username.\n' "$username" >&2
        else
            break
        fi
    done

    if ! command -v sudo >/dev/null 2>&1; then
        refresh_apt_metadata
        run_as_root apt-get install -y sudo
    fi

    run_as_root bash -s -- "$username" <<'CREATE_USER'
set -eu

username=$1
destination="/etc/sudoers.d/90-hostinit-${username}"
temporary=''
created=0
completed=0

cleanup_create_user() {
    status=$?
    trap - EXIT
    if [ "$completed" -eq 0 ]; then
        if [ -n "$temporary" ] && [ "$temporary" -ef "$destination" ]; then
            if ! rm -f -- "$destination"; then
                printf 'Could not remove sudoers file %s; remove it manually.\n' "$destination" >&2
            fi
        fi
        if [ "$created" -eq 1 ]; then
            if userdel -r -- "$username"; then
                created=0
                printf 'User setup did not complete; removed user %s and its home directory.\n' "$username" >&2
            else
                rollback_status=$?
                printf 'Could not fully remove user %s (userdel exit %s); check the account and /home/%s manually.\n' \
                    "$username" "$rollback_status" "$username" >&2
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
    printf 'User %s already exists.\n' "$username" >&2
    exit 1
fi
if [ -e "$destination" ] || [ -L "$destination" ] ||
    [ -e "/home/$username" ] || [ -L "/home/$username" ]; then
    printf 'A home directory or sudoers file for %s already exists.\n' "$username" >&2
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
printf 'Set the login password for %s (sudo will not ask for it):\n' "$username"
passwd "$username" </dev/tty

# Publish atomically without replacing an existing rule.
ln -T -- "$temporary" "$destination"
visudo -c
# Also catches systems whose sudoers configuration does not include sudoers.d.
sudo -u "$username" -- sudo -n -- true
completed=1
printf 'Created %s with home directory /home/%s and passwordless sudo.\n' "$username" "$username"
CREATE_USER
}
