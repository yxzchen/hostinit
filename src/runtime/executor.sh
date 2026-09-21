run_custom_tool() {
    local tool_index=$1
    local tool_label=${TOOL_LABELS[$tool_index]}
    local function_prefix=${TOOL_NAMES[$tool_index]}
    local status

    if ! tool_supports_action "$tool_index" "$MODE"; then
        print_skip "Skipped (${MODE} not supported): ${tool_label}"
        return 0
    fi

    CURRENT_OPERATION=$tool_label
    tool_is_installed "$tool_index"
    status=$?
    case "$MODE:$status" in
        install:0)
            print_skip "Skipped (already installed): ${tool_label}"
            CURRENT_OPERATION=''
            return 0
            ;;
        install:1)
            print_step "Installing: ${tool_label}"
            run_checked "${function_prefix}_install"
            print_success "Installed: ${tool_label}"
            CURRENT_OPERATION=''
            return 0
            ;;
        update:0) ;;
        update:1)
            print_skip "Skipped (not installed): ${tool_label}"
            CURRENT_OPERATION=''
            return 0
            ;;
        *)
            exit "$status"
            ;;
    esac

    print_step "Updating: ${tool_label}"
    "${function_prefix}_update"
    status=$?
    case "$status" in
        0) print_success "Updated: ${tool_label}" ;;
        1) print_skip "No changes: ${tool_label}" ;;
        *) exit "$status" ;;
    esac
    CURRENT_OPERATION=''
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
}
