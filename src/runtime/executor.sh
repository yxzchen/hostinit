run_custom_tool() {
    local tool_index=$1
    local function_prefix=${TOOL_NAMES[$tool_index]}
    local status

    begin_tools "$tool_index"
    if ! tool_supports_action "$tool_index" "$MODE"; then
        record_result "$tool_index" skipped "${MODE} not supported"
        return 0
    fi

    tool_is_installed "$tool_index"
    status=$?
    case "$MODE:$status" in
        install:0)
            record_result "$tool_index" skipped 'already installed'
            return 0
            ;;
        install:1)
            CURRENT_STEP='Installing selected item'
            run_checked "${function_prefix}_install"
            record_result "$tool_index" "${OPERATION_RESULT:-installed}" "$OPERATION_REASON"
            return 0
            ;;
        update:0) ;;
        update:1)
            record_result "$tool_index" skipped 'not installed'
            return 0
            ;;
        *)
            fatal "$status" "Could not check installation status (exit ${status})"
            ;;
    esac

    CURRENT_STEP='Updating selected item'
    "${function_prefix}_update"
    status=$?
    case "$status" in
        0) record_result "$tool_index" "${OPERATION_RESULT:-updated}" "$OPERATION_REASON" ;;
        1) record_result "$tool_index" "${OPERATION_RESULT:-unchanged}" "${OPERATION_REASON:-no changes needed}" ;;
        *) fatal "$status" ;;
    esac
}

flush_package_batch() {
    local status

    [ "${#BATCH_TOOL_INDEXES[@]}" -gt 0 ] || return 0
    run_package_batch "$BATCH_KIND" "$MODE" "${BATCH_TOOL_INDEXES[@]}"
    status=$?
    if [ "$MODE" != update ] || [ "$status" -ne 1 ]; then
        [ "$status" -eq 0 ] || exit "$status"
    fi
    BATCH_KIND=''
    BATCH_TOOL_INDEXES=()
}

execute_selected() {
    local index
    local kind

    start_report
    BATCH_KIND=''
    BATCH_TOOL_INDEXES=()
    for ((index = 0; index < TOOL_COUNT; index++)); do
        if [ "${TOOL_ENABLED[$index]}" -ne 1 ] || [ "${SELECTED_TOOLS[$index]}" -ne 1 ]; then
            continue
        fi

        if [ "${TOOL_SOURCES[$index]}" = 'custom' ]; then
            flush_package_batch
            run_custom_tool "$index"
        else
            kind=$(tool_package_kind "$index") || exit $?
            if [ -n "$BATCH_KIND" ] && [ "$BATCH_KIND" != "$kind" ]; then
                flush_package_batch
            fi
            BATCH_KIND=$kind
            BATCH_TOOL_INDEXES[${#BATCH_TOOL_INDEXES[@]}]=$index
        fi
    done
    flush_package_batch
    finish_report
}
