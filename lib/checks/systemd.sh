# Inspect failed system-wide services without changing their state.

parse_failed_services() {
    awk '
        NF == 0 { next }
        {
            # --plain --no-legend --full yields UNIT LOAD ACTIVE SUB DESCRIPTION.
            # Preserve systemd escaped names, but never include descriptions in
            # the report: they are unnecessary and may contain private details.
            if (NF < 4 || $1 !~ /^([A-Za-z0-9:_.@-]|\\x[0-9A-Fa-f][0-9A-Fa-f])+\.service$/ ||
                $3 != "failed" || $4 != "failed" || seen[$1]++) {
                bad=1
                next
            }
            units[++count]=$1
        }
        END {
            if (bad) exit 1
            printf "Failed systemd services: %d\n", count
            for (i=1; i<=count; i++) print "- " units[i]
            if (count > 0) {
                print "Review the failed service journals."
                exit 3
            }
        }
    '
}

check_failed_services() {
    local services report status

    if ! command -v systemctl >/dev/null 2>&1 ||
        ! command -v timeout >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
        printf 'Failed systemd services: Unknown\n'
        log_error 'failed-service verification requires systemctl, timeout, and awk.'
        return 1
    fi

    if services=$(LC_ALL=C SYSTEMD_COLORS=0 timeout --kill-after=2s 15s \
        systemctl --system list-units --type=service --state=failed --all \
        --plain --no-legend --no-pager --full 2>/dev/null); then
        :
    else
        status=$?
        printf 'Failed systemd services: Unknown\n'
        log_error "could not query failed systemd services (exit code $status)."
        return 1
    fi

    if report=$(printf '%s\n' "$services" | LC_ALL=C parse_failed_services); then
        status=0
    else
        status=$?
    fi
    case $status in
        0|3)
            printf '%s\n' "$report"
            return "$status"
            ;;
        *)
            printf 'Failed systemd services: Unknown\n'
            log_error 'failed-service query returned an unsupported or inconsistent result.'
            return 1
            ;;
    esac
}
