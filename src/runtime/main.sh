main() {
    local status

    if [ "$#" -ne 0 ]; then
        printf 'hostinit.sh does not accept arguments\n' >&2
        return 2
    fi
    if ! detect_platform; then
        printf 'unsupported platform\n' >&2
        return 1
    fi

    configure_tools
    load_custom_modules
    run_tui
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    [ "$ACTION" = 'execute' ] || return 0
    restore_terminal
    execute_selected
}

main "$@"
exit $?
