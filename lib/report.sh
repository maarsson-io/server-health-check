# Compose a report from the existing checks, including failed/unknown results.
# Configuration and the check/email/HTML libraries must already be loaded.

send_health_report() {
    local timestamp findings check_status summary subject body html_body

    if ! timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)'); then
        log_error 'could not determine the report timestamp.'
        return 1
    fi

    # Capture only the checks' report output. Errors still reach stderr and the
    # system log; neither credentials nor raw external-command errors are added.
    if run_all_checks >/dev/null; then
        check_status=0
    else
        check_status=$?
    fi

    case $check_status in
        0) summary='OK' ;;
        3) summary='ACTION REQUIRED' ;;
        *)
            summary='CHECK FAILED OR UNKNOWN'
            check_status=1
            ;;
    esac

    findings=$(format_check_results) || return 1
    subject="[$SHC_SERVER_NAME] $summary"
    body=$(printf 'Server: %s\nCheck date: %s\n\n%s\n\nReport status: %s\n' \
        "$SHC_SERVER_NAME" "$timestamp" "$findings" "$summary") || return 1
    html_body=$(format_report_html "$timestamp") || return 1

    # Send even a healthy or incomplete report. Delivery failure takes
    # precedence; successful delivery must not hide a check failure.
    if ! send_mailgun_email "$subject" "$body" "$html_body"; then
        return 1
    fi
    return "$check_status"
}
