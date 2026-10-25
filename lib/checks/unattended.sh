# Verify the standard Ubuntu APT daily-upgrade setup without running it.
# A fresh success stamp AND a matching completed log are required for OK.

unattended_unknown() {
    printf 'Unattended upgrades: Unknown\n'
    log_error "$1"
    return 1
}

parse_unattended_history() {
    timeout --kill-after=2s 10s awk '
        BEGIN { complete=0; errors=0; simulation=0; warnings=0; malformed=0 }
        /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9],[0-9][0-9][0-9] (DEBUG|INFO|WARNING|ERROR|CRITICAL) / {
            last=substr($0, 1, 23)
            level=$3
            message=substr($0, length($1)+length($2)+length($3)+4)
            if (message == "Starting unattended upgrades script") {
                start=last; complete=0; errors=0; simulation=0; warnings=0; malformed=0
            } else if (start != "") {
                if (level == "ERROR" || level == "CRITICAL") errors=1
                if (level == "WARNING") warnings=1
                if (message ~ /--dry-run|download-only/) simulation=1
                if (level == "INFO" && (message == "All upgrades installed" ||
                    message == "No packages found that can be upgraded unattended and no pending auto-removals")) complete=1
            }
            next
        }
        NF { malformed=1 }
        END { printf "%s|%s|%d|%d|%d|%d|%d\n", start, last, complete, errors, simulation, warnings, malformed }
    '
}

read_unattended_history() {
    local directory=$1 path
    # Ubuntu rotates monthly and normally compresses .1 immediately. Reading
    # the previous file also handles a run that straddled log rotation.
    for path in "$directory/unattended-upgrades.log.1" "$directory/unattended-upgrades.log.1.gz"; do
        if [[ -e $path || -L $path ]]; then
            [[ -f $path && ! -L $path ]] || return 1
            if [[ $path == *.gz ]]; then
                timeout --kill-after=2s 5s gzip -cd -- "$path" || return 1
            else
                timeout --kill-after=2s 5s cat -- "$path" || return 1
            fi
        fi
    done
    path=$directory/unattended-upgrades.log
    [[ -f $path && ! -L $path ]] || return 1
    timeout --kill-after=2s 5s cat -- "$path"
}

check_unattended_upgrades() {
    # Optional internal paths support isolated fixtures, not CLI options.
    local log_directory=${1:-/var/log/unattended-upgrades}
    local success_stamp=${2:-/var/lib/apt/periodic/upgrade-stamp}
    local tool settings line key value timer service stamp_before stamp_after history
    local start last complete errors simulation warnings malformed
    local now_ms stamp_ms start_ms last_ms age_ms
    local cfg_ENABLE=1 cfg_INTERVAL=0 cfg_STATE=/var/lib/apt/
    local cfg_LOGDIR='' cfg_LOGFILE='' cfg_OLD_LOGDIR='' cfg_OLD_LOGFILE=''

    for tool in unattended-upgrade apt-config systemctl timeout stat date awk gzip cat; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            unattended_unknown 'unattended-upgrades verification requires the standard Ubuntu APT, systemd, and log-reading tools.'
            return 1
        fi
    done

    # apt-config shell produces assignments, but they are parsed as data,
    # never sourced/evaluated. Only these non-secret settings are requested.
    if ! settings=$(LC_ALL=C timeout --kill-after=2s 10s apt-config shell \
        ENABLE APT::Periodic::Enable INTERVAL APT::Periodic::Unattended-Upgrade \
        STATE Dir::State/d LOGDIR Unattended-Upgrade::LogDir \
        LOGFILE Unattended-Upgrade::LogFile OLD_LOGDIR APT::UnattendedUpgrades::LogDir \
        OLD_LOGFILE APT::UnattendedUpgrades::LogFile 2>/dev/null); then
        unattended_unknown 'could not read unattended-upgrades settings.'
        return 1
    fi
    while IFS= read -r line; do
        [[ -z $line ]] && continue
        key=${line%%=*}; value=${line#*=}
        case $key in
            ENABLE|INTERVAL|STATE|LOGDIR|LOGFILE|OLD_LOGDIR|OLD_LOGFILE) ;;
            *) unattended_unknown 'unsupported unattended-upgrades settings output.'; return 1 ;;
        esac
        if [[ $value != \'*\' ]]; then
            unattended_unknown 'unsupported unattended-upgrades setting syntax.'
            return 1
        fi
        value=${value#\'}; value=${value%\'}
        if [[ $value == *\'* ]]; then
            unattended_unknown 'unsupported unattended-upgrades setting syntax.'
            return 1
        fi
        printf -v "cfg_$key" '%s' "$value"
    done <<< "$settings"

    if [[ $cfg_ENABLE == 0 || $cfg_INTERVAL == 0 ]]; then
        printf 'Unattended upgrades: ACTION REQUIRED (automatic upgrades are disabled)\n'
        return 3
    fi
    value=${cfg_LOGDIR:-${cfg_OLD_LOGDIR:-/var/log/unattended-upgrades/}}
    if [[ $cfg_ENABLE != 1 || ( $cfg_INTERVAL != always && ! $cfg_INTERVAL =~ ^[1-9][0-9]*$ ) ||
        ${cfg_STATE%/} != /var/lib/apt || ${value%/} != /var/log/unattended-upgrades ||
        ${cfg_LOGFILE:-${cfg_OLD_LOGFILE:-unattended-upgrades.log}} != unattended-upgrades.log ]]; then
        unattended_unknown 'unattended-upgrades uses a configuration outside the supported standard Ubuntu setup.'
        return 1
    fi

    if ! timer=$(LC_ALL=C timeout --kill-after=2s 10s systemctl show apt-daily-upgrade.timer \
        -p LoadState -p ActiveState -p UnitFileState 2>/dev/null) ||
        ! service=$(LC_ALL=C timeout --kill-after=2s 10s systemctl show apt-daily-upgrade.service \
        -p LoadState -p ActiveState -p Result 2>/dev/null); then
        unattended_unknown 'could not inspect the daily APT scheduler.'
        return 1
    fi
    timer=$'\n'"$timer"$'\n'; service=$'\n'"$service"$'\n'
    if [[ $timer != *$'\nLoadState=loaded\n'* || $service != *$'\nLoadState=loaded\n'* ]]; then
        unattended_unknown 'the standard daily APT units could not be verified.'
        return 1
    fi
    if [[ $timer != *$'\nActiveState=active\n'* || $timer != *$'\nUnitFileState=enabled\n'* ]]; then
        printf 'Unattended upgrades: ACTION REQUIRED (daily upgrade timer is not active and enabled)\n'
        return 3
    fi
    if [[ $service == *$'\nActiveState=activating\n'* || $service == *$'\nActiveState=active\n'* ||
        $service == *$'\nActiveState=deactivating\n'* ]]; then
        unattended_unknown 'daily APT upgrade activity is still in progress.'
        return 1
    fi
    if [[ $service != *$'\nResult=success\n'* ]]; then
        printf 'Unattended upgrades: ACTION REQUIRED (daily APT service did not complete successfully)\n'
        return 3
    fi

    if [[ -L $log_directory || ! -d $log_directory ]]; then
        unattended_unknown 'the unattended-upgrades log directory could not be verified.'
        return 1
    fi
    if [[ -L $success_stamp || ! -f $success_stamp ]] ||
        ! stamp_before=$(stat -c '%y' -- "$success_stamp" 2>/dev/null); then
        unattended_unknown 'the daily APT success stamp is missing, unreadable, or not a regular file.'
        return 1
    fi
    if ! history=$(read_unattended_history "$log_directory" 2>/dev/null | LC_ALL=C parse_unattended_history) ||
        ! stamp_after=$(stat -c '%y' -- "$success_stamp" 2>/dev/null) || [[ $stamp_before != "$stamp_after" ]]; then
        unattended_unknown 'unattended-upgrades history could not be read consistently.'
        return 1
    fi
    IFS='|' read -r start last complete errors simulation warnings malformed <<< "$history"
    if [[ $simulation == 1 || $malformed == 1 || -z $start || -z $last ]]; then
        unattended_unknown 'the latest unattended-upgrades log does not establish a real completed run.'
        return 1
    fi
    if [[ $errors == 1 ]]; then
        printf 'Unattended upgrades: ACTION REQUIRED (latest logged attempt reports an error)\n'
        return 3
    fi
    if [[ $complete != 1 || $warnings == 1 ]]; then
        unattended_unknown 'the latest unattended-upgrades log has warnings or no recognized completion.'
        return 1
    fi

    # Milliseconds distinguish a new run from an older success in the same
    # second. Log times are local; the stamp includes an explicit UTC offset.
    if ! now_ms=$(date '+%s%3N') || ! stamp_ms=$(date -d "$stamp_before" '+%s%3N' 2>/dev/null) ||
        ! start_ms=$(date -d "${start/,/.}" '+%s%3N' 2>/dev/null) ||
        ! last_ms=$(date -d "${last/,/.}" '+%s%3N' 2>/dev/null) ||
        [[ ! $now_ms =~ ^[0-9]{13}$ || ! $stamp_ms =~ ^[0-9]{13}$ ||
           ! $start_ms =~ ^[0-9]{13}$ || ! $last_ms =~ ^[0-9]{13}$ ]]; then
        unattended_unknown 'could not interpret unattended-upgrades history timestamps.'
        return 1
    fi
    age_ms=$((now_ms - stamp_ms))
    if (( age_ms < 0 || now_ms - start_ms > 172800000 ||
        age_ms > 172800000 || start_ms > last_ms || last_ms > stamp_ms )); then
        unattended_unknown 'unattended-upgrades has no matching successful run within the last 48 hours.'
        return 1
    fi
    printf 'Unattended upgrades: OK (successful run verified within the last 48 hours)\n'
}
