# Inspect Ubuntu's marker without reading or modifying its contents.

check_reboot() {
    local run_directory=${1:-/run}
    local marker_type

    if [[ -L $run_directory || ! -d $run_directory ]]; then
        printf 'Reboot required: Unknown\n'
        log_error 'could not check reboot status: runtime directory is missing or not a regular directory.'
        return 1
    fi

    # A successful directory scan distinguishes an absent marker from a failed
    # lookup. find reports access/IO errors through its exit status.
    marker_type=$(find "$run_directory" -mindepth 1 -maxdepth 1 \
        -name reboot-required -printf '%y' 2>/dev/null) || {
        printf 'Reboot required: Unknown\n'
        log_error 'could not inspect the runtime directory for the reboot-required marker.'
        return 1
    }

    case $marker_type in
        '')
            printf 'Reboot required: No\n'
            ;;
        f)
            printf 'Reboot required: Yes\n'
            return 3
            ;;
        *)
            printf 'Reboot required: Unknown\n'
            log_error 'reboot-required marker has an unexpected file type.'
            return 1
            ;;
    esac
}
