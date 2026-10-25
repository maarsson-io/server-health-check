# Verify the standard Ubuntu logrotate timer and completed oneshot executions.

logrotate_unknown() {
    printf 'Logrotate: Unknown\n'
    log_error "$1"
    return 1
}

read_logrotate_event_time() {
    # These are system-manager events, not messages emitted by logrotate.
    # Only the numeric timestamp reaches the shell; message text is discarded.
    LC_ALL=C timeout --kill-after=2s 5s journalctl \
        --quiet --no-pager --since=-36h --output=short-unix --lines=1 \
        _PID=1 UNIT=logrotate.service "$@" 2>/dev/null |
        LC_ALL=C awk '
            NF {
                count++
                if (count > 1 || $1 !~ /^[1-9][0-9]*[.][0-9]+$/ ||
                    length($1) != 17 || substr($1, 11, 1) != ".") bad=1
                timestamp=$1
            }
            END {
                if (bad) exit 1
                print timestamp
            }
        '
}

check_logrotate() {
    local tool timer service success failure started now_us success_us failure_us started_us event_us run_time

    for tool in logrotate systemctl journalctl timeout date awk; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            logrotate_unknown 'logrotate verification requires the standard Ubuntu logrotate, systemd, and journal-reading tools.'
            return 1
        fi
    done

    if ! timer=$(LC_ALL=C timeout --kill-after=2s 5s systemctl show logrotate.timer \
        -p LoadState -p ActiveState -p UnitFileState 2>/dev/null) ||
        ! service=$(LC_ALL=C timeout --kill-after=2s 5s systemctl show logrotate.service \
        -p LoadState -p Type -p ActiveState -p Result 2>/dev/null); then
        logrotate_unknown 'could not inspect the logrotate scheduler.'
        return 1
    fi
    timer=$'\n'"$timer"$'\n'; service=$'\n'"$service"$'\n'
    if [[ $timer != *$'\nLoadState=loaded\n'* || $service != *$'\nLoadState=loaded\n'* ||
        $service != *$'\nType=oneshot\n'* ]]; then
        logrotate_unknown 'the standard logrotate timer and oneshot service could not be verified.'
        return 1
    fi
    if [[ $timer != *$'\nActiveState=active\n'* || $timer != *$'\nUnitFileState=enabled\n'* ]]; then
        printf 'Logrotate: ACTION REQUIRED (timer is not active and enabled)\n'
        return 3
    fi
    if [[ $service == *$'\nActiveState=activating\n'* || $service == *$'\nActiveState=active\n'* ||
        $service == *$'\nActiveState=deactivating\n'* ]]; then
        logrotate_unknown 'logrotate is still running.'
        return 1
    fi
    if [[ $service == *$'\nActiveState=failed\n'* ||
        ( $service == *$'\nResult='* && $service != *$'\nResult=success\n'* ) ]]; then
        printf 'Logrotate: ACTION REQUIRED (service failed; check its journal and available disk space)\n'
        return 3
    fi
    if [[ $service != *$'\nActiveState=inactive\n'* || $service != *$'\nResult=success\n'* ]]; then
        logrotate_unknown 'logrotate service state could not be interpreted.'
        return 1
    fi

    # Stable systemd message IDs: UNIT_STARTED (successful oneshot completion),
    # UNIT_FAILED / UNIT_FAILURE, and UNIT_STARTING. Search across boots.
    # Read starts last so a newer unfinished attempt cannot be hidden by an
    # older successful completion. Missing history is never evidence of OK.
    if ! success=$(read_logrotate_event_time MESSAGE_ID=39f53479d3a045ac8e11786248231fbf) ||
        ! failure=$(read_logrotate_event_time MESSAGE_ID=be02cf6855d2428ba40df7e9d022f03d \
            MESSAGE_ID=d9b373ed55a64feb8242e02dbe79a49c) ||
        ! started=$(read_logrotate_event_time MESSAGE_ID=7d4958e842da4a758f6c1cdc7b36dcc5) ||
        ! now_us=$(date '+%s%6N') || [[ ! $now_us =~ ^[1-9][0-9]{15}$ ]]; then
        logrotate_unknown 'could not read logrotate execution history.'
        return 1
    fi
    success_us=${success/./}; failure_us=${failure/./}; started_us=${started/./}
    for event_us in "$success_us" "$failure_us" "$started_us"; do
        [[ -z $event_us ]] && continue
        if (( event_us > now_us || now_us - event_us > 129600000000 )); then
            logrotate_unknown 'logrotate execution history contains timestamps outside the last 36 hours.'
            return 1
        fi
    done
    if [[ -n $started ]] && (( started_us > ${success_us:-0} && started_us > ${failure_us:-0} )); then
        logrotate_unknown 'the latest recorded logrotate execution has no completion result.'
        return 1
    fi
    if [[ -n $failure ]] && (( failure_us >= ${success_us:-0} )); then
        printf 'Logrotate: ACTION REQUIRED (latest recorded execution failed; check its journal and available disk space)\n'
        return 3
    fi
    if [[ -z $success || -z $started ]] || (( started_us > success_us || now_us - success_us > 129600000000 )); then
        logrotate_unknown 'no completed successful logrotate run could be verified within the last 36 hours.'
        return 1
    fi
    if ! run_time=$(date -d "@$success" '+%Y-%m-%d %H:%M' 2>/dev/null); then
        logrotate_unknown 'could not format the successful logrotate run time.'
        return 1
    fi
    printf 'Logrotate: OK (successful run at %s)\n' "$run_time"
}
