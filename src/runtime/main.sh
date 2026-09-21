main() {
    local status

    if [ "$#" -ne 0 ]; then
        fatal 2 'hostinit.sh does not accept arguments'
    fi
    if ! detect_platform; then
        fatal 1 'Unsupported platform'
    fi

    configure_tools
    load_custom_modules
    run_tui
    status=$?
    if [ "$status" -ne 0 ]; then
        restore_terminal
        fatal "$status" "${FAILURE_REASON:-Could not read the interactive selection}"
    fi
    [ "$ACTION" = 'execute' ] || return 0
    restore_terminal
    execute_selected
}

main "$@"
exit $?
