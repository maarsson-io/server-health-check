# Pass only application-generated messages here, never configuration values
# or raw command/API output.

log_error() {
    local message=$1

    printf 'Error: %s\n' "$message" >&2
    # Bound local logging too. Socket errors must not be silently ignored.
    if ! timeout 5 logger --socket-errors=on --tag server-health-check \
        --priority user.err -- "$message" 2>/dev/null; then
        printf 'Warning: could not write the error to the system log.\n' >&2
    fi

    # The caller keeps responsibility for the original operation's exit code.
    return 0
}
