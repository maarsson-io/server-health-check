# HTML presentation only. Check statuses and counts come from collect_checks.

report_html_escape() {
    local text=$1
    text=${text//&/\&amp;}
    text=${text//</\&lt;}
    text=${text//>/\&gt;}
    text=${text//\"/\&quot;}
    text=${text//\'/\&#39;}
    printf '%s' "$text"
}

report_html_color() {
    case $1 in
        0) printf '#15803d' ;;
        3) printf '#b91c1c' ;;
        *) printf '#a16207' ;;
    esac
}

report_html_status() {
    case $1 in
        0) printf 'OK' ;;
        3) printf 'ACTION REQUIRED' ;;
        *) printf 'CHECK FAILED OR UNKNOWN' ;;
    esac
}

report_html_result_class() {
    case $1 in
        '#15803d') printf 'result-ok' ;;
        '#b91c1c') printf 'result-action' ;;
        '#a16207') printf 'result-unknown' ;;
        *) printf 't1' ;;
    esac
}

report_html_check_names() {
    local name separator=''
    for name in "${SHC_CHECK_NAMES[@]}"; do
        printf '%s' "$separator"
        report_html_escape "$name"
        separator=', '
    done
}

report_html_check_rows() {
    local i color
    for ((i=0; i<${#SHC_CHECK_NAMES[@]}; i++)); do
        color=$(report_html_color "${SHC_CHECK_RESULTS[i]}")
        printf '<tr><td class="t1 mono line" style="padding:10px 0;border-top:1px solid #ececec;font-size:14px;color:#18181b;word-break:break-word;">%s</td>' \
            "$(report_html_escape "${SHC_CHECK_NAMES[i]}")"
        printf '<td align="right" class="line %s" style="padding:10px 0;border-top:1px solid #ececec;font-size:13px;font-weight:600;color:%s;">%s</td></tr>\n' \
            "$(report_html_result_class "$color")" "$color" "$(report_html_status "${SHC_CHECK_RESULTS[i]}")"
    done
}

report_html_metric() {
    printf '<tr><td class="t2" style="padding:5px 0;color:#71717a;">%s</td><td align="right" class="%s" style="padding:5px 0;font-weight:600;color:%s;word-break:break-word;">%s</td></tr>\n' \
        "$(report_html_escape "$1")" "$(report_html_result_class "$3")" "$3" "$(report_html_escape "$2")"
}

report_html_package_row() {
    local entry=$1 name versions installed candidate
    if [[ $entry == *': '* && $entry == *' -> '* ]]; then
        name=${entry%%: *}; versions=${entry#*: }
        installed=${versions%% -> *}; candidate=${versions#* -> }
        printf '<tr><td class="line" style="padding:8px 0;border-bottom:1px solid #ececec;"><strong class="t1" style="color:#18181b;">%s</strong> <span class="pkg-ver t2" style="color:#71717a;word-break:break-all;">%s &rarr; <span class="t1" style="color:#18181b;">%s</span></span></td></tr>\n' \
            "$(report_html_escape "$name")" "$(report_html_escape "$installed")" "$(report_html_escape "$candidate")"
    else
        report_html_list_row "$entry"
    fi
}

report_html_list_row() {
    printf '<tr><td class="t1 line" style="padding:8px 0;border-bottom:1px solid #ececec;color:#18181b;word-break:break-word;">%s</td></tr>\n' \
        "$(report_html_escape "$1")"
}

report_html_service_row() {
    local entry=$1
    if [[ $entry == *'.service: '* ]]; then
        printf '<tr><td class="t1 line" style="padding:8px 0;border-bottom:1px solid #ececec;color:#18181b;word-break:break-word;"><strong>%s</strong>.service: %s</td></tr>\n' \
            "$(report_html_escape "${entry%%.service: *}")" "$(report_html_escape "${entry#*.service: }")"
    else
        report_html_list_row "$entry"
    fi
}

report_html_list_table() {
    printf '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" class="soft" style="background:#fafafa;border-radius:8px;"><tr><td style="padding:6px 16px;"><table role="presentation" width="100%%" cellpadding="0" cellspacing="0" class="mono" style="font-size:12px;line-height:1.5;">\n%s</table></td></tr></table>\n' "$1"
}

report_html_list_block() {
    printf '<tr><td colspan="2" style="padding:8px 0;">'
    report_html_list_table "$1"
    printf '</td></tr>\n'
}

report_html_package_group() {
    [[ -n $2 ]] || return 0
    printf '<div class="t2" style="margin:14px 0 6px;font-size:12px;color:#71717a;">%s</div>\n' "$(report_html_escape "$1")"
    report_html_list_table "$2"
}

report_html_details() {
    local i name title color value_color line label value group row
    local eligible phased held items
    for ((i=0; i<${#SHC_CHECK_NAMES[@]}; i++)); do
        name=${SHC_CHECK_NAMES[i]}
        case $name in
            apt_updates) title='APT updates' ;;
            reboot) title='Reboot' ;;
            unattended_upgrades) title='Unattended upgrades' ;;
            failed_services) title='Failed services' ;;
            critical_services) title='Critical services' ;;
            time_sync) title='Time synchronization' ;;
            logrotate) title='Logrotate' ;;
            redis_persistence) title='Redis persistence' ;;
            listening_interfaces) title='Listening interfaces' ;;
            *) title=$name ;;
        esac
        color=$(report_html_color "${SHC_CHECK_RESULTS[i]}")
        eligible=''; phased=''; held=''; group=''; items=''
        printf '<tr><td class="px" style="padding:28px 32px 8px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif;"><div class="t1" style="font-size:16px;font-weight:600;color:#18181b;">%s</div>\n' "$(report_html_escape "$title")"
        printf '<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="margin-top:12px;font-size:14px;">\n'
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ -n $items && $line != '- '* ]]; then
                report_html_list_block "$items"
                items=''
            fi
            case $line in
                '') continue ;;
                '- '*)
                    if [[ $name == apt_updates && -n $group ]]; then
                        row=$(report_html_package_row "${line#- }")
                        case $group in
                            eligible) eligible+="$row"$'\n' ;;
                            phased) phased+="$row"$'\n' ;;
                            held) held+="$row"$'\n' ;;
                        esac
                    elif [[ $name == listening_interfaces || $name == critical_services ]]; then
                        if [[ $name == critical_services ]]; then
                            row=$(report_html_service_row "${line#- }")
                        else
                            row=$(report_html_list_row "${line#- }")
                        fi
                        items+="$row"$'\n'
                    else
                        printf '<tr><td colspan="2" class="t1 mono" style="padding:5px 0;color:#18181b;word-break:break-word;">%s</td></tr>\n' "$(report_html_escape "$line")"
                    fi
                    ;;
                *': '*)
                    label=${line%%: *}; value=${line#*: }
                    value_color=$color
                    if [[ $name == apt_updates ]]; then
                        # APT's overall action status must not color a successful
                        # index refresh red or treat phased counts as failures.
                        value_color='#18181b'
                        if [[ $label == 'APT package index refresh' && $value == OK ]]; then
                            value_color='#15803d'
                        elif [[ $value == Unknown ]]; then
                            value_color='#a16207'
                        fi
                        case $label in
                            'Eligible for apt-get upgrade') group=eligible ;;
                            'Deferred due to phasing') group=phased ;;
                            'Kept back for other reasons') group=held ;;
                            *) group='' ;;
                        esac
                    fi
                    report_html_metric "$label" "$value" "$value_color"
                    ;;
                *)
                    group=''
                    printf '<tr><td colspan="2" class="t2" style="padding:5px 0;color:#71717a;">%s</td></tr>\n' "$(report_html_escape "$line")"
                    ;;
            esac
        done <<< "${SHC_CHECK_OUTPUTS[i]}"
        [[ -z $items ]] || report_html_list_block "$items"
        printf '</table>\n'
        report_html_package_group 'Eligible for apt-get upgrade' "$eligible"
        report_html_package_group 'Deferred due to phasing' "$phased"
        report_html_package_group 'Kept back for other reasons' "$held"
        printf '</td></tr>\n'
    done
}

format_report_html() {
    local timestamp=$1 template_path template line remainder token
    local color background border summary_text
    template_path="$(dirname -- "${BASH_SOURCE[0]}")/../templates/report.html"
    if ! template=$(cat -- "$template_path" 2>/dev/null); then
        log_error 'could not read the HTML report template.'
        return 1
    fi
    case $SHC_CHECK_SUMMARY in
        OK)
            color='#15803d'; background='#f0fdf4'; border='#bbf7d0'
            summary_text='All implemented checks passed.' ;;
        'ACTION REQUIRED')
            color='#b91c1c'; background='#fef2f2'; border='#fecaca'
            summary_text='Maintenance is required. Review the findings above.' ;;
        *)
            color='#a16207'; background='#fffbeb'; border='#fde68a'
            summary_text='One or more checks failed or could not be verified. Review the findings above.' ;;
    esac
    # Expand a fixed set of tokens in one pass. Inserted values are never
    # evaluated or expanded again, even when they contain token-like text.
    while IFS= read -r line || [[ -n $line ]]; do
        while [[ $line == *'{{'* ]]; do
            printf '%s' "${line%%'{{'*}"
            remainder=${line#*'{{'}
            if [[ $remainder != *'}}'* ]]; then
                log_error 'the HTML report template contains an incomplete placeholder.'
                return 1
            fi
            token=${remainder%%'}}'*}; line=${remainder#*'}}'}
            case $token in
                SERVER_NAME) report_html_escape "$SHC_SERVER_NAME" ;;
                TIMESTAMP) report_html_escape "$timestamp" ;;
                STATUS) report_html_escape "$SHC_CHECK_SUMMARY" ;;
                STATUS_COLOR) printf '%s' "$color" ;;
                STATUS_BG) printf '%s' "$background" ;;
                STATUS_BORDER) printf '%s' "$border" ;;
                OK_COUNT) printf '%s' "$SHC_OK_COUNT" ;;
                ACTION_COUNT) printf '%s' "$SHC_ACTION_COUNT" ;;
                UNKNOWN_COUNT) printf '%s' "$SHC_UNKNOWN_COUNT" ;;
                CHECK_ROWS) report_html_check_rows ;;
                CHECK_NAMES) report_html_check_names ;;
                DETAIL_SECTIONS) report_html_details ;;
                SUMMARY_TEXT) report_html_escape "$summary_text" ;;
                *) log_error 'the HTML report template contains an unsupported placeholder.'; return 1 ;;
            esac
        done
        printf '%s\n' "$line"
    done <<< "$template"
}
