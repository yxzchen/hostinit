activate_terminal() {
    stty -echo -icanon min 1 time 0 || return $?
    TUI_ACTIVE=1
    printf '\033[?1049h\033[?25l\033[2J\033[H'
}

node_is_descendant() {
    local ancestor=$2
    local candidate=$1

    while [ "$candidate" -ge 0 ]; do
        [ "$candidate" -eq "$ancestor" ] && return 0
        candidate=${NODE_PARENTS[$candidate]}
    done
    return 1
}

visit_node_and_ancestors() {
    local node_index=$1
    local visitor=$2

    shift 2
    while [ "$node_index" -ge 0 ]; do
        "$visitor" "$node_index" "$@"
        node_index=${NODE_PARENTS[$node_index]}
    done
}

increment_node_selectable_tools() {
    local node_index=$1

    NODE_SELECTABLE_TOOLS[$node_index]=$((${NODE_SELECTABLE_TOOLS[$node_index]} + 1))
}

include_tool_in_node_counts() {
    local installed=$2
    local node_index=$1

    NODE_ENABLED[$node_index]=1
    NODE_TOTAL_TOOLS[$node_index]=$((${NODE_TOTAL_TOOLS[$node_index]} + 1))
    if [ "$installed" -eq 1 ]; then
        NODE_INSTALLED_TOOLS[$node_index]=$((${NODE_INSTALLED_TOOLS[$node_index]} + 1))
    fi
}

increment_node_selected_tools() {
    local node_index=$1

    NODE_SELECTED_TOOLS[$node_index]=$((${NODE_SELECTED_TOOLS[$node_index]} + 1))
}

rebuild_visible_nodes() {
    local node_index=0
    local parent
    local visible

    VISIBLE_NODES=()
    while [ "$node_index" -lt "$NODE_COUNT" ]; do
        if [ "${NODE_ENABLED[$node_index]}" -ne 1 ]; then
            node_index=$((node_index + 1))
            continue
        fi

        visible=1
        parent=${NODE_PARENTS[$node_index]}
        while [ "$parent" -ge 0 ]; do
            if [ "${EXPANDED_NODES[$parent]}" -ne 1 ]; then
                visible=0
                break
            fi
            parent=${NODE_PARENTS[$parent]}
        done
        if [ "$visible" -eq 1 ]; then
            VISIBLE_NODES[${#VISIBLE_NODES[@]}]=$node_index
        fi
        node_index=$((node_index + 1))
    done
}

check_installed_tools() {
    local status
    local tool_index=0

    TOOL_INSTALLED=()
    while [ "$tool_index" -lt "$TOOL_COUNT" ]; do
        TOOL_INSTALLED[$tool_index]=0
        if [ "${TOOL_ENABLED[$tool_index]}" -eq 1 ]; then
            tool_is_installed "$tool_index"
            status=$?
            case "$status" in
                0) TOOL_INSTALLED[$tool_index]=1 ;;
                1) ;;
                *) return "$status" ;;
            esac
        fi
        tool_index=$((tool_index + 1))
    done
}

tool_is_selectable() {
    local tool_index=$1

    [ "${TOOL_ENABLED[$tool_index]}" -eq 1 ] || return 1
    if [ "$MODE" = install ]; then
        [ "${TOOL_INSTALLED[$tool_index]}" -eq 0 ]
    else
        [ "${TOOL_INSTALLED[$tool_index]}" -eq 1 ]
    fi
}

refresh_selectable_counts() {
    local node_index=0
    local tool_index

    NODE_SELECTABLE_TOOLS=()
    while [ "$node_index" -lt "$NODE_COUNT" ]; do
        NODE_SELECTABLE_TOOLS[$node_index]=0
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        if [ "$tool_index" -ge 0 ] && tool_is_selectable "$tool_index"; then
            visit_node_and_ancestors "$node_index" increment_node_selectable_tools
        fi
        node_index=$((node_index + 1))
    done
}

clear_selection() {
    local tool_index=0

    while [ "$tool_index" -lt "$TOOL_COUNT" ]; do
        SELECTED_TOOLS[$tool_index]=0
        tool_index=$((tool_index + 1))
    done
    refresh_selectable_counts
    refresh_selection_counts
}

initialize_tui() {
    local node_index=0
    local tool_index=0

    check_installed_tools || return $?

    SELECTED_TOOLS=()
    while [ "$tool_index" -lt "$TOOL_COUNT" ]; do
        SELECTED_TOOLS[$tool_index]=0
        tool_index=$((tool_index + 1))
    done

    EXPANDED_NODES=()
    NODE_ENABLED=()
    NODE_INSTALLED_TOOLS=()
    NODE_SELECTED_TOOLS=()
    NODE_TOTAL_TOOLS=()
    while [ "$node_index" -lt "$NODE_COUNT" ]; do
        EXPANDED_NODES[$node_index]=0
        NODE_ENABLED[$node_index]=0
        NODE_INSTALLED_TOOLS[$node_index]=0
        NODE_SELECTED_TOOLS[$node_index]=0
        NODE_TOTAL_TOOLS[$node_index]=0
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        if [ "$tool_index" -ge 0 ] && [ "${TOOL_ENABLED[$tool_index]}" -eq 1 ]; then
            visit_node_and_ancestors "$node_index" include_tool_in_node_counts \
                "${TOOL_INSTALLED[$tool_index]}"
        fi
        node_index=$((node_index + 1))
    done

    CURRENT_POSITION=0
    SELECTED_TOOL_COUNT=0
    VIEWPORT_START=0
    TUI_MESSAGE=''
    refresh_selectable_counts
    rebuild_visible_nodes
}

refresh_selection_counts() {
    local node_index=0
    local tool_index

    SELECTED_TOOL_COUNT=0
    while [ "$node_index" -lt "$NODE_COUNT" ]; do
        NODE_SELECTED_TOOLS[$node_index]=0
        node_index=$((node_index + 1))
    done

    node_index=0
    while [ "$node_index" -lt "$NODE_COUNT" ]; do
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        if [ "${NODE_ENABLED[$node_index]}" -eq 1 ] &&
            [ "$tool_index" -ge 0 ] &&
            [ "${SELECTED_TOOLS[$tool_index]}" -eq 1 ]; then
            SELECTED_TOOL_COUNT=$((SELECTED_TOOL_COUNT + 1))
            visit_node_and_ancestors "$node_index" increment_node_selected_tools
        fi
        node_index=$((node_index + 1))
    done
}

node_selection_state() {
    local node_index=$1
    local selected=${NODE_SELECTED_TOOLS[$node_index]}
    local total=${NODE_SELECTABLE_TOOLS[$node_index]}

    if [ "$selected" -eq 0 ]; then
        NODE_SELECTION_STATE='none'
    elif [ "$selected" -eq "$total" ]; then
        NODE_SELECTION_STATE='all'
    else
        NODE_SELECTION_STATE='partial'
    fi
}

node_is_selectable() {
    local node_index=$1
    local tool_index=${NODE_TOOL_INDEXES[$node_index]}

    if [ "$tool_index" -ge 0 ]; then
        tool_is_selectable "$tool_index"
    else
        [ "${NODE_SELECTABLE_TOOLS[$node_index]}" -gt 0 ]
    fi
}

read_terminal_size() {
    local columns
    local rows
    local size

    size=$(stty size 2>/dev/null) || size=''
    rows=${size%% *}
    columns=${size#* }
    case "$rows" in
        ''|*[!0-9]*|0) rows=${LINES:-24} ;;
    esac
    case "$columns" in
        ''|*[!0-9]*|0) columns=${COLUMNS:-80} ;;
    esac
    case "$rows" in
        ''|*[!0-9]*|0) rows=24 ;;
    esac
    case "$columns" in
        ''|*[!0-9]*|0) columns=80 ;;
    esac
    [ "$rows" -ge 3 ] || rows=3
    [ "$columns" -ge 1 ] || columns=1

    TERMINAL_ROWS=$rows
    TERMINAL_COLUMNS=$columns
    if [ "$TERMINAL_ROWS" -ge 5 ]; then
        TUI_VERTICAL_PADDING=1
        TUI_NODE_CAPACITY=$((TERMINAL_ROWS - 4))
    else
        TUI_VERTICAL_PADDING=0
        TUI_NODE_CAPACITY=$((TERMINAL_ROWS - 2))
    fi
}

update_viewport() {
    local count=${#VISIBLE_NODES[@]}
    local maximum_start

    read_terminal_size
    if [ "$count" -eq 0 ]; then
        VIEWPORT_START=0
        return 0
    fi
    if [ "$CURRENT_POSITION" -lt "$VIEWPORT_START" ]; then
        VIEWPORT_START=$CURRENT_POSITION
    elif [ "$CURRENT_POSITION" -ge $((VIEWPORT_START + TUI_NODE_CAPACITY)) ]; then
        VIEWPORT_START=$((CURRENT_POSITION - TUI_NODE_CAPACITY + 1))
    fi

    maximum_start=$((count - TUI_NODE_CAPACITY))
    [ "$maximum_start" -ge 0 ] || maximum_start=0
    [ "$VIEWPORT_START" -le "$maximum_start" ] || VIEWPORT_START=$maximum_start
    [ "$VIEWPORT_START" -ge 0 ] || VIEWPORT_START=0
}

print_tui_line() {
    local line=$1
    local style=${2:-}

    printf '%s%.*s\033[0m\033[K' "$style" "$TERMINAL_COLUMNS" "$line"
}

build_footer() {
    local available_columns
    local position_prefix=''

    if [ "${#VISIBLE_NODES[@]}" -gt "$TUI_NODE_CAPACITY" ]; then
        position_prefix="$((CURRENT_POSITION + 1))/${#VISIBLE_NODES[@]} | "
    fi
    available_columns=$((TERMINAL_COLUMNS - ${#position_prefix}))

    if [ "$available_columns" -ge 96 ]; then
        TUI_FOOTER='Space select | a all | Tab mode | h/l fold | j/k move | Ctrl+u/d page | Enter review | q quit'
    elif [ "$available_columns" -ge 71 ]; then
        TUI_FOOTER='Space select | a all | Tab mode | h/l fold | j/k move | Enter review | q quit'
    elif [ "$available_columns" -ge 48 ]; then
        TUI_FOOTER='Space select | Tab mode | Enter review | q quit'
    elif [ "$available_columns" -ge 30 ]; then
        TUI_FOOTER='Space | Tab mode | Enter | q quit'
    else
        TUI_FOOTER='Enter | q'
    fi
    TUI_FOOTER="${position_prefix}${TUI_FOOTER}"
}

render_tui() {
    local cursor
    local depth
    local depth_index
    local indent
    local indicator
    local line
    local marker
    local mode_label='Install'
    local node_index
    local position
    local position_end
    local state
    local style
    local tool_index
    local visible_count=${#VISIBLE_NODES[@]}

    [ "$MODE" = 'update' ] && mode_label='Update'
    update_viewport
    position=$VIEWPORT_START
    position_end=$((VIEWPORT_START + TUI_NODE_CAPACITY))
    [ "$position_end" -le "$visible_count" ] || position_end=$visible_count

    printf '\033[H'
    print_tui_line "hostinit - ${PLATFORM} - ${mode_label} | Selected: ${SELECTED_TOOL_COUNT}"
    printf '\n'
    [ "$TUI_VERTICAL_PADDING" -eq 0 ] || printf '\033[K\n'
    while [ "$position" -lt "$position_end" ]; do
        node_index=${VISIBLE_NODES[$position]}
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        depth=${NODE_DEPTHS[$node_index]}
        indent=''
        depth_index=0
        while [ "$depth_index" -lt "$depth" ]; do
            indent="${indent}  "
            depth_index=$((depth_index + 1))
        done

        cursor=' '
        [ "$position" -eq "$CURRENT_POSITION" ] && cursor='>'
        style=''
        if ! node_is_selectable "$node_index"; then
            style=$'\033[90m'
        fi
        if [ "$position" -eq "$CURRENT_POSITION" ]; then
            if [ -n "$style" ]; then
                style=$'\033[1;90m'
            else
                style=$'\033[1m'
            fi
        fi
        node_selection_state "$node_index"
        state=$NODE_SELECTION_STATE
        case "$state" in
            all) marker='x' ;;
            partial) marker='-' ;;
            *) marker=' ' ;;
        esac
        indicator=''
        if [ "$tool_index" -lt 0 ]; then
            if [ "${EXPANDED_NODES[$node_index]}" -eq 1 ]; then
                indicator='v'
            else
                indicator='>'
            fi
        fi
        line="$cursor $indent[$marker] ${NODE_LABELS[$node_index]}"
        [ -z "$indicator" ] || line="$line $indicator"
        if [ "$tool_index" -lt 0 ]; then
            line="$line (${NODE_INSTALLED_TOOLS[$node_index]}/${NODE_TOTAL_TOOLS[$node_index]})"
        fi
        print_tui_line "$line" "$style"
        printf '\n'
        position=$((position + 1))
    done
    [ "$TUI_VERTICAL_PADDING" -eq 0 ] || printf '\033[K\n'
    if [ -n "$TUI_MESSAGE" ]; then
        print_tui_line "$TUI_MESSAGE" $'\033[1;33m'
    else
        build_footer
        print_tui_line "$TUI_FOOTER" $'\033[2m'
    fi
    printf '\033[J'
}

toggle_current_node() {
    local candidate=0
    local node_index
    local state
    local target=1
    local tool_index

    [ "${#VISIBLE_NODES[@]}" -gt 0 ] || return 0
    node_index=${VISIBLE_NODES[$CURRENT_POSITION]}
    tool_index=${NODE_TOOL_INDEXES[$node_index]}
    if [ "$tool_index" -ge 0 ]; then
        tool_is_selectable "$tool_index" || return 0
        if [ "${SELECTED_TOOLS[$tool_index]}" -eq 1 ]; then
            SELECTED_TOOLS[$tool_index]=0
        else
            SELECTED_TOOLS[$tool_index]=1
        fi
        refresh_selection_counts
        return 0
    fi

    node_selection_state "$node_index"
    state=$NODE_SELECTION_STATE
    [ "$state" = all ] && target=0
    while [ "$candidate" -lt "$NODE_COUNT" ]; do
        tool_index=${NODE_TOOL_INDEXES[$candidate]}
        if [ "${NODE_ENABLED[$candidate]}" -eq 1 ] &&
            [ "$tool_index" -ge 0 ] &&
            tool_is_selectable "$tool_index" &&
            node_is_descendant "$candidate" "$node_index"; then
            SELECTED_TOOLS[$tool_index]=$target
        fi
        candidate=$((candidate + 1))
    done
    refresh_selection_counts
}

toggle_all_tools() {
    local target=0
    local tool_index=0

    while [ "$tool_index" -lt "$TOOL_COUNT" ]; do
        if tool_is_selectable "$tool_index" &&
            [ "${SELECTED_TOOLS[$tool_index]}" -eq 0 ]; then
            target=1
            break
        fi
        tool_index=$((tool_index + 1))
    done

    tool_index=0
    while [ "$tool_index" -lt "$TOOL_COUNT" ]; do
        if tool_is_selectable "$tool_index"; then
            SELECTED_TOOLS[$tool_index]=$target
        fi
        tool_index=$((tool_index + 1))
    done
    refresh_selection_counts
}

move_down() {
    local count=${#VISIBLE_NODES[@]}

    [ "$count" -gt 0 ] || return 0
    CURRENT_POSITION=$(((CURRENT_POSITION + 1) % count))
}

move_up() {
    local count=${#VISIBLE_NODES[@]}

    [ "$count" -gt 0 ] || return 0
    CURRENT_POSITION=$(((CURRENT_POSITION + count - 1) % count))
}

page_down() {
    local count=${#VISIBLE_NODES[@]}

    [ "$count" -gt 0 ] || return 0
    CURRENT_POSITION=$((CURRENT_POSITION + TUI_NODE_CAPACITY))
    if [ "$CURRENT_POSITION" -ge "$count" ]; then
        CURRENT_POSITION=$((count - 1))
    fi
}

page_up() {
    [ "${#VISIBLE_NODES[@]}" -gt 0 ] || return 0
    CURRENT_POSITION=$((CURRENT_POSITION - TUI_NODE_CAPACITY))
    [ "$CURRENT_POSITION" -ge 0 ] || CURRENT_POSITION=0
}

set_current_node() {
    local node_index=$1
    local position=0

    while [ "$position" -lt "${#VISIBLE_NODES[@]}" ]; do
        if [ "${VISIBLE_NODES[$position]}" -eq "$node_index" ]; then
            CURRENT_POSITION=$position
            return 0
        fi
        position=$((position + 1))
    done
    return 1
}

expand_current_node() {
    local node_index

    [ "${#VISIBLE_NODES[@]}" -gt 0 ] || return 0
    node_index=${VISIBLE_NODES[$CURRENT_POSITION]}
    [ "${NODE_TOOL_INDEXES[$node_index]}" -lt 0 ] || return 0
    EXPANDED_NODES[$node_index]=1
    rebuild_visible_nodes
    set_current_node "$node_index"
}

collapse_node() {
    local candidate=0
    local node_index=$1

    while [ "$candidate" -lt "$NODE_COUNT" ]; do
        if [ "${NODE_TOOL_INDEXES[$candidate]}" -lt 0 ] &&
            node_is_descendant "$candidate" "$node_index"; then
            EXPANDED_NODES[$candidate]=0
        fi
        candidate=$((candidate + 1))
    done
}

collapse_current_node() {
    local node_index
    local target

    [ "${#VISIBLE_NODES[@]}" -gt 0 ] || return 0
    node_index=${VISIBLE_NODES[$CURRENT_POSITION]}
    target=$node_index
    if [ "${NODE_TOOL_INDEXES[$node_index]}" -ge 0 ] ||
        [ "${EXPANDED_NODES[$node_index]}" -eq 0 ]; then
        target=${NODE_PARENTS[$node_index]}
    fi
    [ "$target" -ge 0 ] || return 0
    collapse_node "$target"
    rebuild_visible_nodes
    set_current_node "$target"
}

print_confirmation_tree() {
    local depth
    local depth_index
    local indent
    local node_index=0
    local selected
    local tool_index

    while [ "$node_index" -lt "$NODE_COUNT" ]; do
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        selected=0
        if [ "${NODE_ENABLED[$node_index]}" -eq 1 ]; then
            if [ "$tool_index" -lt 0 ]; then
                [ "${NODE_SELECTED_TOOLS[$node_index]}" -gt 0 ] && selected=1
            elif [ "${SELECTED_TOOLS[$tool_index]}" -eq 1 ]; then
                selected=1
            fi
        fi
        if [ "$selected" -eq 1 ]; then
            depth=${NODE_DEPTHS[$node_index]}
            indent=''
            depth_index=0
            while [ "$depth_index" -lt "$depth" ]; do
                indent="${indent}  "
                depth_index=$((depth_index + 1))
            done
            if [ "$tool_index" -lt 0 ]; then
                printf '%s%s\n' "$indent" "${NODE_LABELS[$node_index]}"
            else
                printf '%s- %s\n' "$indent" "${NODE_LABELS[$node_index]}"
            fi
        fi
        node_index=$((node_index + 1))
    done
}

confirm_selection() {
    local answer
    local mode_label='Install'

    [ "$MODE" = 'update' ] && mode_label='Update'
    if [ "$SELECTED_TOOL_COUNT" -eq 0 ]; then
        TUI_MESSAGE='Select at least one item'
        return 0
    fi

    TUI_MESSAGE=''
    restore_terminal
    printf '\n%s selected tools:\n\n' "$mode_label"
    print_confirmation_tree
    printf '\n%s %s selected tools? [y/N] ' "$mode_label" "$SELECTED_TOOL_COUNT"
    IFS= read -r answer || answer=''
    case "$answer" in
        y|Y)
            ACTION='execute'
            return 0
            ;;
    esac
    activate_terminal
}

read_tui_key() {
    local remainder=''

    TUI_KEY=''
    IFS= read -r -n 1 TUI_KEY || return $?
    if [ "$TUI_KEY" = $'\033' ]; then
        IFS= read -r -n 2 -t 1 remainder || true
        TUI_KEY="${TUI_KEY}${remainder}"
    fi
}

toggle_mode() {
    if [ "$MODE" = install ]; then
        MODE='update'
    else
        MODE='install'
    fi
    clear_selection
}

handle_tui_key() {
    case "$1" in
        ' ') toggle_current_node ;;
        a) toggle_all_tools ;;
        $'\t') toggle_mode ;;
        h|$'\033[D'|$'\033OD') collapse_current_node ;;
        l|$'\033[C'|$'\033OC') expand_current_node ;;
        j|$'\033[B'|$'\033OB') move_down ;;
        k|$'\033[A'|$'\033OA') move_up ;;
        $'\025') page_up ;;
        $'\004') page_down ;;
        q)
            ACTION='quit'
            restore_terminal
            ;;
        ''|$'\r') confirm_selection ;;
    esac
}

run_tui() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf 'hostinit requires an interactive terminal\n' >&2
        return 1
    fi
    STTY_STATE=$(stty -g) || return $?
    activate_terminal || return $?
    printf 'hostinit - %s\033[K\n\033[K\nChecking installed tools...\033[K\n\033[J' "$PLATFORM"
    initialize_tui || return $?

    while [ -z "$ACTION" ]; do
        render_tui
        read_tui_key || return $?
        TUI_MESSAGE=''
        handle_tui_key "$TUI_KEY" || return $?
    done
    return 0
}
