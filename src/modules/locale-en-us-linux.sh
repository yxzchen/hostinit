#!/usr/bin/env bash

_locale_en_us_generated() {
    locale -a 2>/dev/null | grep -Eiq '^en_US\.utf-?8$'
}

_locale_en_us_default() {
    [ -r /etc/default/locale ] && grep -Fqx 'LANG=en_US.UTF-8' /etc/default/locale
}

locale-en-us_is_installed() {
    _locale_en_us_generated && _locale_en_us_default
}

locale-en-us_install() {
    if ! _locale_en_us_generated; then
        if grep -Eq '^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8[[:space:]]*$' \
            /etc/locale.gen; then
            :
        elif grep -Eq '^[[:space:]]*#[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8[[:space:]]*$' \
            /etc/locale.gen; then
            run_as_root sed -i -E \
                's/^[[:space:]]*#[[:space:]]*(en_US\.UTF-8[[:space:]]+UTF-8)[[:space:]]*$/\1/' \
                /etc/locale.gen
        else
            fatal 1
        fi
        run_as_root locale-gen
        _locale_en_us_generated || fatal 1
    fi
    if ! _locale_en_us_default; then
        run_as_root env LC_ALL=C LANG=C update-locale LANG=en_US.UTF-8
        _locale_en_us_default || fatal 1
    fi
}
