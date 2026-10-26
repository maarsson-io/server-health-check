# Checks print findings and return 0 (OK), 3 (action required), or 1 (unknown).
# Keep stdout and normalized exit status together for both report formats.

collect_checks() {
    local check_function output result
    local print_findings=false
    if [[ ${1:-} == --print-findings ]]; then
        print_findings=true
        shift
    fi
    SHC_CHECK_NAMES=()
    SHC_CHECK_OUTPUTS=()
    SHC_CHECK_RESULTS=()
    SHC_OK_COUNT=0
    SHC_ACTION_COUNT=0
    SHC_UNKNOWN_COUNT=0
    SHC_CHECK_SUMMARY='CHECK FAILED OR UNKNOWN'

    if (( $# == 0 )); then
        log_error 'no checks were selected.'
        return 1
    fi

    for check_function in "$@"; do
        # Command substitution isolates exit/shell state while preserving stderr.
        if output=$("$check_function"); then
            result=0
        else
            result=$?
        fi
        case $result in
            0) SHC_OK_COUNT=$((SHC_OK_COUNT + 1)) ;;
            3) SHC_ACTION_COUNT=$((SHC_ACTION_COUNT + 1)) ;;
            *)
                SHC_UNKNOWN_COUNT=$((SHC_UNKNOWN_COUNT + 1))
                if (( result != 1 )); then
                    log_error "check ${check_function#check_} returned unexpected exit code $result."
                fi
                result=1
                ;;
        esac
        SHC_CHECK_NAMES+=("${check_function#check_}")
        SHC_CHECK_OUTPUTS+=("$output")
        SHC_CHECK_RESULTS+=("$result")
        if [[ $print_findings == true && -n $output ]]; then
            printf '%s\n' "$output"
        fi
    done

    if (( SHC_UNKNOWN_COUNT > 0 )); then
        return 1
    elif (( SHC_ACTION_COUNT > 0 )); then
        SHC_CHECK_SUMMARY='ACTION REQUIRED'
        return 3
    fi
    SHC_CHECK_SUMMARY='OK'
}

format_check_header() {
    local name separator=' '
    printf 'Checks performed:'
    for name in "$@"; do
        printf '%s%s' "$separator" "${name#check_}"
        separator=', '
    done
    printf '\n\n'
}

format_check_summary() {
    printf '\nSummary: %s\n' "$SHC_CHECK_SUMMARY"
    printf 'Results: %s OK, %s action required, %s failed or unknown\n' \
        "$SHC_OK_COUNT" "$SHC_ACTION_COUNT" "$SHC_UNKNOWN_COUNT"
}

format_check_results() {
    local name output
    local -a functions=()
    for name in "${SHC_CHECK_NAMES[@]}"; do functions+=("check_$name"); done
    format_check_header "${functions[@]}"
    for output in "${SHC_CHECK_OUTPUTS[@]}"; do
        [[ -z $output ]] || printf '%s\n' "$output"
    done
    format_check_summary
}

run_checks() {
    local result
    if (( $# == 0 )); then
        collect_checks
        return 1
    fi
    format_check_header "$@" || return 1
    if collect_checks --print-findings "$@"; then result=0; else result=$?; fi
    format_check_summary || return 1
    return "$result"
}

run_all_checks() {
    # Extend this explicit list as additional checks are implemented.
    local -a checks=(check_apt_updates check_reboot check_unattended_upgrades
        check_failed_services check_time_sync check_logrotate)
    if [[ ${SHC_REDIS_ENABLED:-false} == true ]]; then
        checks+=(check_redis_persistence)
    fi
    run_checks "${checks[@]}"
}
