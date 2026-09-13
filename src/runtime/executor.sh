run_custom_tool() {
    local tool_index=$1
    local tool_label=${TOOL_LABELS[$tool_index]}
    local function_prefix=${TOOL_NAMES[$tool_index]}
    local install_function="${function_prefix}_install"
    local is_installed_function="${function_prefix}_is_installed"
    local needs_update_function="${function_prefix}_needs_update"
    local update_function="${function_prefix}_update"
    local status

    "$is_installed_function"
    status=$?
    if [ "$MODE" = install ]; then
        case "$status" in
            0)
                print_skip "skipped: ${tool_label}"
                return 0
                ;;
            1)
                print_step "installing: ${tool_label}"
                "$install_function"
                status=$?
                [ "$status" -eq 0 ] || exit "$status"
                print_success "installed: ${tool_label}"
                return 0
                ;;
            *)
                exit "$status"
                ;;
        esac
    fi

    case "$status" in
        0) ;;
        1)
            print_skip "not updated (not installed): ${tool_label}"
            return 0
            ;;
        *)
            exit "$status"
            ;;
    esac

    "$needs_update_function"
    status=$?
    case "$status" in
        0) ;;
        1)
            print_skip "not updated: ${tool_label}"
            return 0
            ;;
        *)
            exit "$status"
            ;;
    esac

    print_step "updating: ${tool_label}"
    "$update_function"
    status=$?
    case "$status" in
        0) print_success "updated: ${tool_label}" ;;
        1) print_skip "not updated: ${tool_label}" ;;
        *) exit "$status" ;;
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
    local index=0
    local kind

    BATCH_KIND=''
    BATCH_TOOL_INDEXES=()
    while [ "$index" -lt "$TOOL_COUNT" ]; do
        if [ "${TOOL_ENABLED[$index]}" -ne 1 ] || [ "${SELECTED_TOOLS[$index]}" -ne 1 ]; then
            index=$((index + 1))
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
        index=$((index + 1))
    done
    flush_package_batch
}
