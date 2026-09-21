# Status output goes to stderr; stdout remains available for returned data and
# native command output. Only the executor records final results.
REPORT_ACTIVE=0
REPORT_SUBSHELL=0
REPORT_TOTAL=0
CURRENT_STEP=''
FAILURE_REASON=''
OPERATION_RESULT=''
OPERATION_REASON=''
REPORT_TOOLS=()
CURRENT_TOOLS=()
REPORT_RESULTS=()
REPORT_POSITIONS=()
ACTION_TOOL_INDEXES=()
ACTION_MESSAGES=()

read_output_width() {
    local size=''
    local columns=${COLUMNS:-80}

    if [ -t 2 ]; then
        size=$(stty size <&2 2>/dev/null) || size=''
        [ -z "$size" ] || columns=${size#* }
    fi
    case "$columns" in
        ''|*[!0-9]*|0) columns=80 ;;
    esac
    while [[ "$columns" == 0* ]] && [ "${#columns}" -gt 1 ]; do columns=${columns#0}; done
    [ "$columns" -gt 0 ] || columns=80
    OUTPUT_COLUMNS=$columns
}

# Wrap prose at spaces, preserving explicit line breaks. Unbroken paths and
# indented command lines remain intact so copied commands keep their meaning.
wrap_text_lines() {
    local text=$1
    local width=$2
    local prefix=${3-}
    local continuation=${4-$prefix}
    local preserve_indented=${5:-1}
    local line
    local current_prefix
    local available
    local chunk
    local emitted
    local max_indent=$((width / 3))

    prefix=${prefix:0:$max_indent}
    continuation=${continuation:0:$max_indent}
    WRAPPED_LINES=()
    while IFS= read -r line || [ -n "$line" ]; do
        current_prefix=$prefix
        emitted=0
        if [ "$preserve_indented" -eq 1 ] && [[ "$line" == '  '* ]]; then
            WRAPPED_LINES[${#WRAPPED_LINES[@]}]="$current_prefix$line"
            continue
        fi
        available=$((width - ${#current_prefix}))
        while [ "${#line}" -gt "$available" ]; do
            chunk=${line:0:$available}
            if [[ "$chunk" == *' '* ]] && [ -n "${chunk% *}" ]; then
                chunk=${chunk% *}
            else
                chunk=${line%% *}
            fi
            WRAPPED_LINES[${#WRAPPED_LINES[@]}]="$current_prefix$chunk"
            emitted=1
            line=${line:${#chunk}}
            while [[ "$line" == ' '* ]]; do line=${line# }; done
            current_prefix=$continuation
            available=$((width - ${#current_prefix}))
        done
        if [ -n "$line" ] || [ "$emitted" -eq 0 ]; then
            WRAPPED_LINES[${#WRAPPED_LINES[@]}]="$current_prefix$line"
        fi
    done <<<"$text"
}

_output_line() {
    local color=$1
    local message=$2
    local prefix=${3-}
    local continuation=${4-$prefix}
    local line

    read_output_width
    wrap_text_lines "$message" "$OUTPUT_COLUMNS" "$prefix" "$continuation"
    for line in "${WRAPPED_LINES[@]}"; do
        if [ -t 2 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-}" != dumb ]; then
            printf '\033[%sm%s\033[0m\n' "$color" "$line" >&2
        else
            printf '%s\n' "$line" >&2
        fi
    done
}

print_info() {
    _output_line 0 "$1" '' '  '
}

print_step() {
    CURRENT_STEP=$1
    _output_line '1;36' "$CURRENT_STEP" '' '  '
}

print_prompt() {
    local prefix=${2-}
    local line
    local index

    read_output_width
    wrap_text_lines "$1" "$((OUTPUT_COLUMNS > 1 ? OUTPUT_COLUMNS - 1 : 1))" "$prefix"
    for ((index = 0; index < ${#WRAPPED_LINES[@]}; index++)); do
        line=${WRAPPED_LINES[$index]}
        if [ "$index" -eq $((${#WRAPPED_LINES[@]} - 1)) ]; then
            printf '%s ' "$line" >&2
        else
            printf '%s\n' "$line" >&2
        fi
    done
}

_output_action_message() {
    local line

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == '  '* ]]; then
            _output_line '1;33' "$line"
        else
            _output_line '1;33' "$line" '  '
        fi
    done <<<"$1"
}

print_action_required() {
    local index
    local tool_index=${CURRENT_TOOLS[0]:--1}

    if [ "$REPORT_ACTIVE" -ne 1 ] || [ "$BASH_SUBSHELL" -ne "$REPORT_SUBSHELL" ]; then
        _output_line '1;33' 'Action required:'
        _output_action_message "$1"
        return 0
    fi
    for ((index = 0; index < ${#ACTION_MESSAGES[@]}; index++)); do
        if [ "${ACTION_TOOL_INDEXES[$index]}" -eq "$tool_index" ] &&
            [ "${ACTION_MESSAGES[$index]}" = "$1" ]; then
            return 0
        fi
    done
    ACTION_TOOL_INDEXES[${#ACTION_TOOL_INDEXES[@]}]=$tool_index
    ACTION_MESSAGES[${#ACTION_MESSAGES[@]}]=$1
}

set_operation_result() {
    case "$1" in
        skipped|unchanged) ;;
        *) fatal 2 "Invalid operation result: $1" ;;
    esac
    [ -n "$2" ] || fatal 2 'An operation result must include a reason'
    OPERATION_RESULT=$1
    OPERATION_REASON=$2
}

start_report() {
    local index

    REPORT_ACTIVE=1
    REPORT_SUBSHELL=$BASH_SUBSHELL
    REPORT_TOTAL=0
    REPORT_TOOLS=()
    CURRENT_TOOLS=()
    REPORT_RESULTS=()
    REPORT_POSITIONS=()
    ACTION_TOOL_INDEXES=()
    ACTION_MESSAGES=()
    FAILURE_REASON=''
    for ((index = 0; index < TOOL_COUNT; index++)); do
        if [ "${TOOL_ENABLED[$index]}" -eq 1 ] && [ "${SELECTED_TOOLS[$index]}" -eq 1 ]; then
            REPORT_TOTAL=$((REPORT_TOTAL + 1))
            REPORT_TOOLS[${#REPORT_TOOLS[@]}]=$index
            REPORT_RESULTS[$index]=pending
            REPORT_POSITIONS[$index]=$REPORT_TOTAL
        fi
    done
}

begin_tools() {
    local index
    local first=$1
    local last=$1
    local labels=''
    local heading
    local position
    local verb='Installing'

    CURRENT_TOOLS=("$@")
    CURRENT_STEP='Checking installation status'
    FAILURE_REASON=''
    OPERATION_RESULT=''
    OPERATION_REASON=''
    for index in "$@"; do
        REPORT_RESULTS[$index]=running
        labels="${labels}${labels:+, }${TOOL_LABELS[$index]}"
        last=$index
    done
    position=${REPORT_POSITIONS[$first]}
    [ "$first" -eq "$last" ] || position="${position}-${REPORT_POSITIONS[$last]}"
    [ "$MODE" = update ] && verb='Updating'
    printf '\n' >&2
    heading="[${position}/${REPORT_TOTAL}] ${verb}: ${labels}"
    read_output_width
    if [ "$#" -gt 1 ] && [ "${#heading}" -gt "$OUTPUT_COLUMNS" ]; then
        _output_line '1;36' "[${position}/${REPORT_TOTAL}] ${verb} $# items:" '' '  '
        for index in "$@"; do
            _output_line 0 "${TOOL_LABELS[$index]}" '  - ' '    '
        done
    else
        _output_line '1;36' "$heading" '' '  '
    fi
}

record_result() {
    local tool_index=$1
    local result=$2
    local reason=${3:-}
    local color
    local label

    case "$result" in
        installed) label='Installed'; color='1;32' ;;
        updated) label='Updated'; color='1;32' ;;
        unchanged) label='No changes'; color=90 ;;
        skipped) label='Skipped'; color=90 ;;
        failed) label='Failed'; color='1;31' ;;
        *) fatal 2 "Invalid final result: $result" ;;
    esac
    REPORT_RESULTS[$tool_index]=$result
    if [ "$result" = failed ]; then
        _output_line "$color" "${label}: ${TOOL_LABELS[$tool_index]}"
        _output_line "$color" "$reason" '  '
    else
        _output_line "$color" "${label}: ${TOOL_LABELS[$tool_index]}${reason:+ (${reason})}" '' '  '
    fi
}

finish_report() {
    local status=${1:-0}
    local index
    local reason=$FAILURE_REASON
    local summary=''
    local action_tool_index
    local previous_tool_index=-1
    local installed=0 updated=0 unchanged=0 skipped=0 failed=0 pending=0

    [ "$REPORT_ACTIVE" -eq 1 ] || return 0
    [ "$BASH_SUBSHELL" -eq "$REPORT_SUBSHELL" ] || return 0
    if [ -z "$reason" ]; then
        case "$status" in
            130|143|129) reason="Interrupted (exit ${status})" ;;
            *) reason="${CURRENT_STEP:-Operation did not complete} (exit ${status})" ;;
        esac
    fi
    for index in "${REPORT_TOOLS[@]}"; do
        if [ "${REPORT_RESULTS[$index]}" = running ]; then
            record_result "$index" failed "$reason"
        fi
        case "${REPORT_RESULTS[$index]}" in
            installed) installed=$((installed + 1)) ;;
            updated) updated=$((updated + 1)) ;;
            unchanged) unchanged=$((unchanged + 1)) ;;
            skipped) skipped=$((skipped + 1)) ;;
            failed) failed=$((failed + 1)) ;;
            pending) pending=$((pending + 1)) ;;
        esac
    done
    [ "$installed" -eq 0 ] || summary="${installed} installed, "
    [ "$updated" -eq 0 ] || summary="${summary}${updated} updated, "
    [ "$unchanged" -eq 0 ] || summary="${summary}${unchanged} unchanged, "
    [ "$skipped" -eq 0 ] || summary="${summary}${skipped} skipped, "
    summary="${summary}${failed} failed"
    [ "$pending" -eq 0 ] || summary="${summary}, ${pending} not run"
    printf '\n' >&2
    _output_line 0 "Result: ${summary}" '' '  '
    if [ "$pending" -gt 0 ]; then
        _output_line 90 'Not run:' ''
        for index in "${REPORT_TOOLS[@]}"; do
            [ "${REPORT_RESULTS[$index]}" != pending ] || _output_line 90 "${TOOL_LABELS[$index]}" '  '
        done
    fi
    if [ "${#ACTION_MESSAGES[@]}" -gt 0 ]; then
        for ((index = 0; index < ${#ACTION_MESSAGES[@]}; index++)); do
            action_tool_index=${ACTION_TOOL_INDEXES[$index]}
            if [ "$action_tool_index" -ne "$previous_tool_index" ]; then
                printf '\n' >&2
                _output_line '1;33' "Action required: ${TOOL_LABELS[$action_tool_index]}" '' '  '
                previous_tool_index=$action_tool_index
            fi
            _output_action_message "${ACTION_MESSAGES[$index]}"
        done
    fi
    REPORT_ACTIVE=0
    CURRENT_TOOLS=()
}
