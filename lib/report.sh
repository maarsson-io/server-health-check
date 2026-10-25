# Compose a report from the existing checks, including failed/unknown results.
# Configuration and the check/email libraries must already be loaded.

format_report_html() {
    local body=$1 summary=$2 color line escaped

    case $summary in
        OK) color='#15803d' ;;
        'ACTION REQUIRED') color='#b91c1c' ;;
        *) color='#a16207' ;;
    esac

    printf '<!doctype html>\n<html><body><div style="font-family:Arial,sans-serif;line-height:1.5;">\n'
    while IFS= read -r line || [[ -n $line ]]; do
        # Treat all report content as text, including names and package versions.
        escaped=${line//&/\&amp;}
        escaped=${escaped//</\&lt;}
        escaped=${escaped//>/\&gt;}
        escaped=${escaped//\"/\&quot;}
        escaped=${escaped//\'/\&#39;}
        case $line in
            '') printf '<br>\n' ;;
            'Summary: '*)
                printf '<div><strong style="color:%s;">%s</strong></div>\n' "$color" "$escaped"
                ;;
            'Server: '*|'Available updates: '*|'Eligible for apt-get upgrade: '*|\
            'Deferred due to phasing: '*|'Kept back for other reasons: '*|\
            'APT package index refresh: '*|'Reboot required: '*|'Report status: '*)
                printf '<div><strong>%s</strong></div>\n' "$escaped"
                ;;
            *) printf '<div>%s</div>\n' "$escaped" ;;
        esac
    done <<< "$body"
    printf '</div></body></html>\n'
}

send_health_report() {
    local timestamp findings check_status summary subject body html_body

    if ! timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)'); then
        log_error 'could not determine the report timestamp.'
        return 1
    fi

    # Capture only the checks' report output. Errors still reach stderr and the
    # system log; neither credentials nor raw external-command errors are added.
    if findings=$(run_all_checks); then
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

    subject="[$SHC_SERVER_NAME] $summary"
    body=$(printf 'Server: %s\nDate: %s\n\n%s\n\nReport status: %s\nScope: implemented checks only.\n' \
        "$SHC_SERVER_NAME" "$timestamp" "$findings" "$summary") || return 1
    html_body=$(format_report_html "$body" "$summary") || return 1

    # Send even a healthy or incomplete report. Delivery failure takes
    # precedence; successful delivery must not hide a check failure.
    if ! send_mailgun_email "$subject" "$body" "$html_body"; then
        return 1
    fi
    return "$check_status"
}
