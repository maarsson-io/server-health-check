# Query system clock synchronization without assuming a particular NTP daemon.

check_time_sync() {
    local synchronization status

    if ! command -v timedatectl >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        printf 'System clock synchronized: Unknown\n'
        log_error 'time synchronization verification requires timedatectl and timeout.'
        return 1
    fi

    if synchronization=$(LC_ALL=C timeout --kill-after=2s 15s \
        timedatectl show --property=NTPSynchronized 2>/dev/null); then
        :
    else
        status=$?
        printf 'System clock synchronized: Unknown\n'
        log_error "could not query time synchronization (exit code $status)."
        return 1
    fi

    case $synchronization in
        NTPSynchronized=yes)
            printf 'System clock synchronized: Yes\n'
            ;;
        NTPSynchronized=no)
            printf 'System clock synchronized: No\n'
            printf 'Check the time synchronization service.\n'
            return 3
            ;;
        *)
            printf 'System clock synchronized: Unknown\n'
            log_error 'time synchronization query returned an unsupported result.'
            return 1
            ;;
    esac
}
