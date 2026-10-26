# Refresh package metadata only. Never install packages or bypass APT locks.

check_apt_index() {
    local status reason

    if ! command -v apt-get >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        printf 'APT package index refresh: Unknown\n'
        log_error 'APT index refresh requires apt-get and timeout.'
        return 1
    fi

    # --error-on=any makes partial/transient repository failures fail the check.
    # APT's normal list locking remains enabled. timeout signals only this
    # invocation and its process group, never another APT lock holder.
    # Raw output may contain private repository URLs, so do not print/log it.
    if LC_ALL=C timeout --kill-after=5s 120s apt-get \
        --error-on=any \
        -o Acquire::Retries=0 \
        -o Acquire::http::Timeout=15 \
        -o Acquire::https::Timeout=15 \
        -o DPkg::Lock::Timeout=0 \
        update >/dev/null 2>&1; then
        printf 'APT package index refresh: OK\n'
        return 0
    else
        status=$?
    fi

    case $status in
        124) reason='APT index refresh exceeded its 120-second time limit' ;;
        137) reason='APT index refresh was forcibly terminated after a timeout or external signal' ;;
        100) reason='APT index refresh failed; check repository access, metadata signatures, and APT locks' ;;
        *) reason='APT index refresh failed' ;;
    esac
    printf 'APT package index refresh: Unknown\n'
    log_error "$reason (exit code $status)."
    return 1
}

# Parse only the C-locale APT upgrade summary, package lists, and Inst records.
# Cross-check the lists against the summary before publishing any result.
# Kept-back packages marked with apt-mark hold ($1) are intentional, not actionable.
parse_apt_upgrade() {
    SHC_APT_HOLDS="$1" awk '
        function valid_package(name) {
            return name ~ /^[a-z0-9][a-z0-9+.-]+(:[a-z0-9][a-z0-9-]*)?$/
        }
        BEGIN {
            count=split(ENVIRON["SHC_APT_HOLDS"], hold_list, "\n")
            for (i=1; i<=count; i++) {
                if (hold_list[i] == "") continue
                if (!valid_package(hold_list[i])) bad=1
                holds[hold_list[i]]=1
            }
        }
        /^The following upgrades have been deferred due to phasing:$/ { section="phased"; next }
        /^The following packages have been kept back:$/ { section="held"; next }
        /^The following packages will be upgraded:$/ { section="upgrade"; next }
        /^  / {
            if (section != "") {
                for (i=1; i<=NF; i++) {
                    if (!valid_package($i) || seen[$i]++) bad=1
                    if (section == "phased") phased[++np]=$i
                    if (section == "held") held[++nh]=$i
                    if (section == "upgrade") upgrades[$i]=1
                }
            }
            next
        }
        { section="" }
        /^[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove and [0-9]+ not upgraded\.$/ {
            summaries++
            total_upgrade=$1; total_new=$3; total_remove=$6; total_deferred=$10
            next
        }
        /^Inst / {
            name=$2; old=$3; new=$4
            if (!valid_package(name) || !upgrades[name] || installed[name]++ ||
                old !~ /^\[[A-Za-z0-9.+:~_-]+\]$/ || new !~ /^\([A-Za-z0-9.+:~_-]+$/) bad=1
            sub(/^\[/, "", old); sub(/\]$/, "", old); sub(/^\(/, "", new)
            details[++ni]="- " name ": " old " -> " new
            next
        }
        /^Remv / { bad=1 }
        /^[WE]:/ { bad=1 }
        END {
            listed=0
            for (name in upgrades) listed++
            if (bad || summaries != 1 || total_new != 0 || total_remove != 0 ||
                total_upgrade != ni || listed != ni || total_deferred != np+nh) exit 1
            for (i=1; i<=nh; i++) {
                if (held[i] in holds) on_hold[++no]=held[i]
                else kept[++nk]=held[i]
            }
            printf "Available updates: %d\n", ni+np+nh
            printf "Eligible for apt-get upgrade: %d\n", ni
            for (i=1; i<=ni; i++) print details[i]
            printf "Deferred due to phasing: %d\n", np
            for (i=1; i<=np; i++) print "- " phased[i]
            printf "On hold (apt-mark): %d\n", no
            for (i=1; i<=no; i++) print "- " on_hold[i]
            printf "Kept back for other reasons: %d\n", nk
            for (i=1; i<=nk; i++) print "- " kept[i]
            exit (ni+nk > 0 ? 3 : 0)
        }
    '
}

check_apt_updates() {
    local holds simulation report status

    if ! check_apt_index; then
        printf 'Available updates: Unknown\n'
        return 1
    fi
    if ! command -v awk >/dev/null 2>&1 || ! command -v apt-mark >/dev/null 2>&1; then
        printf 'Available updates: Unknown\n'
        log_error 'APT update analysis requires awk and apt-mark.'
        return 1
    fi

    if holds=$(LC_ALL=C timeout --kill-after=5s 30s apt-mark showhold 2>/dev/null); then
        :
    else
        status=$?
        printf 'Available updates: Unknown\n'
        log_error "could not list packages on hold (exit code $status)."
        return 1
    fi

    # Simulation never installs packages. Use the same dependency policy as the
    # operator command, apt-get upgrade; preserve normal holds and phasing.
    if simulation=$(LC_ALL=C timeout --kill-after=5s 60s apt-get \
        --simulate \
        -o APT::Get::Show-Upgraded=true \
        -o APT::Color=false -o quiet=0 \
        upgrade 2>&1); then
        :
    else
        status=$?
        printf 'Available updates: Unknown\n'
        log_error "APT upgrade simulation failed (exit code $status)."
        return 1
    fi

    if report=$(printf '%s\n' "$simulation" | LC_ALL=C parse_apt_upgrade "$holds"); then
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
            printf 'Available updates: Unknown\n'
            log_error 'APT upgrade simulation returned an inconsistent or unsupported result.'
            return 1
            ;;
    esac
}
