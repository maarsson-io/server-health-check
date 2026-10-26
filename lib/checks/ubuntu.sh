# Ubuntu standard support only; Ubuntu Pro/ESM does not extend this threshold.
parse_ubuntu_release() {
    LC_ALL=C awk '
        /^(ID|VERSION_ID|VERSION_CODENAME)=/ {
            at=index($0,"="); key=substr($0,1,at-1); value=substr($0,at+1)
            if (seen[key]++) bad=1
            quote=substr(value,1,1)
            if ((quote == "\"" || quote == "\047") && substr(value,length(value),1) == quote)
                value=substr(value,2,length(value)-2)
            values[key]=value
        }
        END {
            if (bad || values["ID"] != "ubuntu" ||
                values["VERSION_ID"] !~ /^[0-9][0-9]\.[0-9][0-9]$/ ||
                values["VERSION_CODENAME"] !~ /^[a-z][a-z0-9]+$/) exit 1
            printf "%s %s\n", values["VERSION_ID"], values["VERSION_CODENAME"]
        }
    '
}

read_ubuntu_release() {
    parse_ubuntu_release < /etc/os-release
}

ubuntu_eol_unknown() {
    printf 'Ubuntu standard support: Unknown\n'
    log_error "$1"
    return 1
}

check_ubuntu_eol() {
    local identity version codename today info remaining eol status
    local info_pattern='^([0-9]{2}\.[0-9]{2})( LTS)? (-?(0|[1-9][0-9]{0,5}))$'

    if ! command -v ubuntu-distro-info >/dev/null 2>&1 ||
        ! command -v date >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1 ||
        ! command -v timeout >/dev/null 2>&1; then
        ubuntu_eol_unknown 'Ubuntu support verification requires ubuntu-distro-info, GNU date, awk, and timeout.'
        return 1
    fi
    if ! identity=$(read_ubuntu_release 2>/dev/null); then
        ubuntu_eol_unknown 'could not identify a supported Ubuntu release from /etc/os-release.'
        return 1
    fi
    IFS=' ' read -r version codename <<< "$identity"
    if ! today=$(LC_ALL=C date '+%F' 2>/dev/null) || [[ ! $today =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        ubuntu_eol_unknown 'could not determine the current date for Ubuntu support verification.'
        return 1
    fi
    # Explicit --date avoids SOURCE_DATE_EPOCH overriding the real current date.
    # --release lets us also verify that the codename matches VERSION_ID.
    if info=$(LC_ALL=C timeout --kill-after=2s 5s ubuntu-distro-info \
        --series="$codename" --date="$today" --release --days=eol 2>/dev/null); then :; else
        status=$?
        ubuntu_eol_unknown "could not query Ubuntu standard support data (exit code $status)."
        return 1
    fi
    if [[ ! $info =~ $info_pattern || ${BASH_REMATCH[1]} != "$version" ]]; then
        ubuntu_eol_unknown 'Ubuntu support data is missing, unsupported, or inconsistent with the installed version.'
        return 1
    fi
    remaining=${BASH_REMATCH[3]}
    # UTC arithmetic on date-only values avoids DST changing a calendar-day count.
    if ! eol=$(LC_ALL=C date --utc --date="$today $remaining days" '+%F' 2>/dev/null) ||
        [[ ! $eol =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        ubuntu_eol_unknown 'could not calculate the Ubuntu standard support end date.'
        return 1
    fi
    printf 'Ubuntu release: %s (%s)\n' "$version" "$codename"
    if (( remaining < 0 )); then
        printf 'Ubuntu standard support: Ended on %s (%s days ago)\n' "$eol" "$((-remaining))"
        return 3
    elif (( remaining == 0 )); then
        printf 'Ubuntu standard support: Ends today (%s)\n' "$eol"
        return 3
    fi
    printf 'Ubuntu standard support: Ends on %s (%s days remaining)\n' "$eol" "$remaining"
    if (( remaining <= 90 )); then return 3; fi
    return 0
}
