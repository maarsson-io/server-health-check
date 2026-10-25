# Checks print their findings and return 0 (OK), 3 (action required), or
# 1 (failed/unknown). Only application-defined check functions are passed here.

run_checks() {
    local check_function result summary separator=' '
    local ok_count=0 action_count=0 unknown_count=0

    if (( $# == 0 )); then
        log_error 'no checks were selected.'
        return 1
    fi

    printf 'Checks performed:'
    for check_function in "$@"; do
        printf '%s%s' "$separator" "${check_function#check_}"
        separator=', '
    done
    printf '\n\n'

    for check_function in "$@"; do
        # Isolate each check so an exit or shell-state change cannot stop later checks.
        if ( "$check_function" ); then
            result=0
        else
            result=$?
        fi

        case $result in
            0) ok_count=$((ok_count + 1)) ;;
            3) action_count=$((action_count + 1)) ;;
            1) unknown_count=$((unknown_count + 1)) ;;
            *)
                unknown_count=$((unknown_count + 1))
                log_error "check ${check_function#check_} returned unexpected exit code $result."
                ;;
        esac
    done

    # An incomplete result takes precedence over maintenance findings.
    if (( unknown_count > 0 )); then
        summary='CHECK FAILED OR UNKNOWN'
        result=1
    elif (( action_count > 0 )); then
        summary='ACTION REQUIRED'
        result=3
    else
        summary='OK'
        result=0
    fi

    printf '\nSummary: %s\n' "$summary"
    printf 'Results: %s OK, %s action required, %s failed or unknown\n' \
        "$ok_count" "$action_count" "$unknown_count"
    return "$result"
}

run_all_checks() {
    # Extend this explicit list as additional checks are implemented.
    run_checks check_apt_updates check_reboot check_unattended_upgrades check_failed_services check_time_sync
}
