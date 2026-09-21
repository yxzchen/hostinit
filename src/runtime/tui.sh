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

increment_node_selectable_tools() {
    local node_index=$1

    NODE_SELECTABLE_TOOLS[$node_index]=$((${NODE_SELECTABLE_TOOLS[$node_index]} + 1))
}

rebuild_visible_nodes() {
    local node_index
    local parent
    local visible

    VISIBLE_NODES=()
    for ((node_index = 0; node_index < NODE_COUNT; node_index++)); do
        if [ "${NODE_ENABLED[$node_index]}" -ne 1 ]; then
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
    done
}

check_installed_tools() {
    local status
    local tool_index

    TOOL_INSTALLED=()
    for ((tool_index = 0; tool_index < TOOL_COUNT; tool_index++)); do
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
    done
}

tool_is_selectable() {
    local tool_index=$1

    [ "${TOOL_ENABLED[$tool_index]}" -eq 1 ] || return 1
    tool_supports_action "$tool_index" "$MODE" || return 1
    if [ "$MODE" = install ]; then
        [ "${TOOL_INSTALLED[$tool_index]}" -eq 0 ]
    else
        [ "${TOOL_INSTALLED[$tool_index]}" -eq 1 ]
    fi
}

refresh_selectable_counts() {
    local node_index
    local tool_index

    # Count supported actions using the installation status cached by the TUI.
    NODE_SELECTABLE_TOOLS=()
    for ((node_index = 0; node_index < NODE_COUNT; node_index++)); do
        NODE_SELECTABLE_TOOLS[$node_index]=0
    done
    for ((node_index = 0; node_index < NODE_COUNT; node_index++)); do
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        if [ "$tool_index" -ge 0 ] && tool_is_selectable "$tool_index"; then
            visit_node_and_ancestors "$node_index" increment_node_selectable_tools
        fi
    done
}

clear_selection() {
    local tool_index

    for ((tool_index = 0; tool_index < TOOL_COUNT; tool_index++)); do
        SELECTED_TOOLS[$tool_index]=0
    done
    refresh_selectable_counts
    refresh_selection_counts
}

initialize_tui() {
    local node_index
    local tool_index

    check_installed_tools || return $?

    SELECTED_TOOLS=()
    EXPANDED_NODES=()
    NODE_ENABLED=()
    NODE_INSTALLED_TOOLS=()
    NODE_SELECTED_TOOLS=()
    NODE_TOTAL_TOOLS=()
    for ((node_index = 0; node_index < NODE_COUNT; node_index++)); do
        EXPANDED_NODES[$node_index]=0
        NODE_ENABLED[$node_index]=0
        NODE_INSTALLED_TOOLS[$node_index]=0
        NODE_TOTAL_TOOLS[$node_index]=0
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        if [ "$tool_index" -ge 0 ] && [ "${TOOL_ENABLED[$tool_index]}" -eq 1 ]; then
            visit_node_and_ancestors "$node_index" include_tool_in_node_counts \
                "${TOOL_INSTALLED[$tool_index]}"
        fi
    done

    CURRENT_POSITION=0
    VIEWPORT_START=0
    TUI_MESSAGE=''
    TUI_HELP_OPEN=0
    clear_selection
    INSTALL_SELECTED_TOOLS=("${SELECTED_TOOLS[@]}")
    UPDATE_SELECTED_TOOLS=("${SELECTED_TOOLS[@]}")
    rebuild_visible_nodes
}

refresh_selection_counts() {
    local node_index
    local tool_index

    SELECTED_TOOL_COUNT=0
    for ((node_index = 0; node_index < NODE_COUNT; node_index++)); do
        NODE_SELECTED_TOOLS[$node_index]=0
    done

    for ((node_index = 0; node_index < NODE_COUNT; node_index++)); do
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        if [ "${NODE_ENABLED[$node_index]}" -eq 1 ] &&
            [ "$tool_index" -ge 0 ] &&
            [ "${SELECTED_TOOLS[$tool_index]}" -eq 1 ]; then
            SELECTED_TOOL_COUNT=$((SELECTED_TOOL_COUNT + 1))
            visit_node_and_ancestors "$node_index" increment_node_selected_tools
        fi
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
    [ "${NODE_SELECTABLE_TOOLS[$1]}" -gt 0 ]
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
    local detail=${3:-}
    local remaining

    line=${line:0:$TERMINAL_COLUMNS}
    remaining=$((TERMINAL_COLUMNS - ${#line}))
    printf '%s%s' "$style" "$line"
    if [ "$remaining" -gt 0 ] && [ -n "$detail" ]; then
        printf '\033[2m%.*s' "$remaining" "$detail"
    fi
    printf '\033[0m\033[K'
}

build_footer() {
    local available_columns
    local candidate
    local position_prefix=''

    if [ "${#VISIBLE_NODES[@]}" -gt "$TUI_NODE_CAPACITY" ]; then
        position_prefix="$((CURRENT_POSITION + 1))/${#VISIBLE_NODES[@]} | "
    fi
    available_columns=$((TERMINAL_COLUMNS - ${#position_prefix}))
    if [ "$available_columns" -lt 6 ]; then
        position_prefix=''
        available_columns=$TERMINAL_COLUMNS
    fi
    TUI_FOOTER='?'
    for candidate in \
        'Space toggle | a all/none | Tab mode | Enter review | ? help | q quit' \
        'Space toggle | Tab mode | Enter review | ? help' \
        'Space | Tab | Enter | ? help | q quit' \
        'Space | Tab | Enter | ? help' \
        '? help | q quit' \
        '? help'; do
        if [ "${#candidate}" -le "$available_columns" ]; then
            TUI_FOOTER=$candidate
            break
        fi
    done
    TUI_FOOTER="${position_prefix}${TUI_FOOTER}"
}

render_tui() {
    local cursor
    local detail
    local indent
    local indicator
    local line
    local marker
    local mode_tabs='[Install]  Update '
    local node_index
    local position
    local position_end
    local state
    local style
    local tool_index
    local visible_count=${#VISIBLE_NODES[@]}

    [ "$MODE" = 'update' ] && mode_tabs=' Install  [Update]'
    update_viewport
    position_end=$((VIEWPORT_START + TUI_NODE_CAPACITY))
    [ "$position_end" -le "$visible_count" ] || position_end=$visible_count

    printf '\033[H'
    print_tui_line "hostinit - ${PLATFORM}    ${mode_tabs}"
    printf '\n'
    [ "$TUI_VERTICAL_PADDING" -eq 0 ] || printf '\033[K\n'
    for ((position = VIEWPORT_START; position < position_end; position++)); do
        node_index=${VISIBLE_NODES[$position]}
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        printf -v indent '%*s' "$((${NODE_DEPTHS[$node_index]} * 2))" ''

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
        detail=''
        if [ "$tool_index" -lt 0 ]; then
            if [ "$MODE" = update ]; then
                detail=" (${NODE_SELECTED_TOOLS[$node_index]}/${NODE_SELECTABLE_TOOLS[$node_index]})"
            else
                detail=" (${NODE_INSTALLED_TOOLS[$node_index]}/${NODE_TOTAL_TOOLS[$node_index]})"
            fi
        fi
        print_tui_line "$line" "$style" "$detail"
        printf '\n'
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

show_help() {
    TUI_HELP_OPEN=1
    HELP_POSITION=0
    HELP_LINES=(
        'Selection'
        '  Space       Toggle item or group'
        '  a           Select all / clear all'
        '  Tab         Switch install / update'
        '  Selections are saved for each mode.'
        ''
        'Navigation'
        '  Up / k      Previous row'
        '  Down / j    Next row'
        '  Left / h    Collapse group / parent'
        '  Right / l   Expand group'
        '  Ctrl+u / d  Page up / down'
        ''
        'Review and exit'
        '  Enter       Review current mode only'
        '  ?           Show this help'
        '  q           Quit without running'
        ''
        'Markers: [ ] none, [-] some, [x] all'
    )
}

clamp_help_position() {
    local maximum=$((${#HELP_LINES[@]} - TUI_NODE_CAPACITY))

    [ "$maximum" -ge 0 ] || maximum=0
    [ "$HELP_POSITION" -le "$maximum" ] || HELP_POSITION=$maximum
    [ "$HELP_POSITION" -ge 0 ] || HELP_POSITION=0
}

render_help() {
    local index
    local position_end
    local footer='j/k scroll | ?/Esc/Enter/q back'

    read_terminal_size
    clamp_help_position
    position_end=$((HELP_POSITION + TUI_NODE_CAPACITY))
    [ "$position_end" -le "${#HELP_LINES[@]}" ] || position_end=${#HELP_LINES[@]}
    printf '\033[H'
    print_tui_line 'Keyboard help' $'\033[1m'
    printf '\n'
    [ "$TUI_VERTICAL_PADDING" -eq 0 ] || printf '\033[K\n'
    for ((index = HELP_POSITION; index < position_end; index++)); do
        print_tui_line "${HELP_LINES[$index]}"
        printf '\n'
    done
    [ "$TUI_VERTICAL_PADDING" -eq 0 ] || printf '\033[K\n'
    [ "$TERMINAL_COLUMNS" -ge "${#footer}" ] || footer='? back | j/k scroll'
    print_tui_line "$footer" $'\033[2m'
    printf '\033[J'
}

handle_help_key() {
    case "$1" in
        '?'|q|$'\033'|''|$'\r') TUI_HELP_OPEN=0 ;;
        j|$'\033[B'|$'\033OB') HELP_POSITION=$((HELP_POSITION + 1)) ;;
        k|$'\033[A'|$'\033OA') HELP_POSITION=$((HELP_POSITION - 1)) ;;
        $'\025') HELP_POSITION=$((HELP_POSITION - TUI_NODE_CAPACITY)) ;;
        $'\004') HELP_POSITION=$((HELP_POSITION + TUI_NODE_CAPACITY)) ;;
    esac
    clamp_help_position
}

toggle_current_node() {
    local candidate
    local node_index
    local target=1
    local tool_index

    [ "${#VISIBLE_NODES[@]}" -gt 0 ] || return 0
    node_index=${VISIBLE_NODES[$CURRENT_POSITION]}
    node_is_selectable "$node_index" || return 0

    node_selection_state "$node_index"
    [ "$NODE_SELECTION_STATE" = all ] && target=0
    for ((candidate = 0; candidate < NODE_COUNT; candidate++)); do
        tool_index=${NODE_TOOL_INDEXES[$candidate]}
        if [ "${NODE_ENABLED[$candidate]}" -eq 1 ] &&
            [ "$tool_index" -ge 0 ] &&
            tool_is_selectable "$tool_index" &&
            node_is_descendant "$candidate" "$node_index"; then
            SELECTED_TOOLS[$tool_index]=$target
        fi
    done
    refresh_selection_counts
}

toggle_all_tools() {
    local target=0
    local tool_index

    for ((tool_index = 0; tool_index < TOOL_COUNT; tool_index++)); do
        if tool_is_selectable "$tool_index" &&
            [ "${SELECTED_TOOLS[$tool_index]}" -eq 0 ]; then
            target=1
            break
        fi
    done

    for ((tool_index = 0; tool_index < TOOL_COUNT; tool_index++)); do
        if tool_is_selectable "$tool_index"; then
            SELECTED_TOOLS[$tool_index]=$target
        fi
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
    local position

    for ((position = 0; position < ${#VISIBLE_NODES[@]}; position++)); do
        if [ "${VISIBLE_NODES[$position]}" -eq "$node_index" ]; then
            CURRENT_POSITION=$position
            return 0
        fi
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
    local candidate
    local node_index=$1

    for ((candidate = 0; candidate < NODE_COUNT; candidate++)); do
        if [ "${NODE_TOOL_INDEXES[$candidate]}" -lt 0 ] &&
            node_is_descendant "$candidate" "$node_index"; then
            EXPANDED_NODES[$candidate]=0
        fi
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
    local indent
    local node_index
    local tool_index

    for ((node_index = 0; node_index < NODE_COUNT; node_index++)); do
        tool_index=${NODE_TOOL_INDEXES[$node_index]}
        if [ "${NODE_SELECTED_TOOLS[$node_index]}" -gt 0 ]; then
            printf -v indent '%*s' "$((${NODE_DEPTHS[$node_index]} * 2))" ''
            if [ "$tool_index" -lt 0 ]; then
                printf '%s%s\n' "$indent" "${NODE_LABELS[$node_index]}"
            else
                printf '%s- %s\n' "$indent" "${NODE_LABELS[$node_index]}"
            fi
        fi
    done
}

confirm_selection() {
    local answer
    local mode_label='Install'

    [ "$MODE" = 'update' ] && mode_label='Update'
    if [ "$SELECTED_TOOL_COUNT" -eq 0 ]; then
        TUI_MESSAGE='Select an item with Space, then press Enter'
        return 0
    fi

    TUI_MESSAGE=''
    restore_terminal
    printf '\nReview selected items (%s):\n\n' "$mode_label"
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
        INSTALL_SELECTED_TOOLS=("${SELECTED_TOOLS[@]}")
        MODE='update'
        SELECTED_TOOLS=("${UPDATE_SELECTED_TOOLS[@]}")
    else
        UPDATE_SELECTED_TOOLS=("${SELECTED_TOOLS[@]}")
        MODE='install'
        SELECTED_TOOLS=("${INSTALL_SELECTED_TOOLS[@]}")
    fi
    refresh_selectable_counts
    refresh_selection_counts
}

handle_tui_key() {
    if [ "${TUI_HELP_OPEN:-0}" -eq 1 ]; then
        handle_help_key "$1"
        return $?
    fi
    case "$1" in
        '?') show_help ;;
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
        if [ "$TUI_HELP_OPEN" -eq 1 ]; then
            render_help
        else
            render_tui
        fi
        read_tui_key || return $?
        TUI_MESSAGE=''
        handle_tui_key "$TUI_KEY" || return $?
    done
    return 0
}
