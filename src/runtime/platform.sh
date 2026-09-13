detect_platform() {
    local system_name
    local os_id

    system_name=$(uname -s) || return $?
    case "$system_name" in
        Darwin)
            PLATFORM='macos'
            return 0
            ;;
        Linux)
            os_id=$(_os_release_value ID) || return $?
            case "$os_id" in
                debian|ubuntu)
                    PLATFORM=$os_id
                    return 0
                    ;;
            esac
            ;;
    esac
    return 1
}
