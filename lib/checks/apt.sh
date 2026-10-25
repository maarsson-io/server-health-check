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
