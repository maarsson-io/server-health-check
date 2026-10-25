# Configuration initialization. Loaded by bin/server-health-check after its root check.

init_config() (
    local template=$1
    local destination=$2
    local temporary_file

    umask 077

    # Also reject dangling symbolic links and non-file paths.
    if [[ -e $destination || -L $destination ]]; then
        log_error 'configuration path already exists; nothing was changed.'
        return 1
    fi

    if [[ ! -f $template || ! -r $template ]]; then
        log_error 'example configuration is missing or unreadable.'
        return 1
    fi

    temporary_file=$(mktemp "${destination}.tmp.XXXXXXXXXX") || {
        log_error 'could not create a temporary configuration file.'
        return 1
    }
    trap 'rm -f -- "$temporary_file"' EXIT
    trap 'exit 1' HUP INT TERM

    if ! cat -- "$template" > "$temporary_file"; then
        log_error 'could not copy the example configuration.'
        return 1
    fi

    if ! chown 0:0 "$temporary_file" || ! chmod 0600 "$temporary_file"; then
        log_error 'could not set configuration ownership or permissions.'
        return 1
    fi

    # GNU ln -T treats the destination as an exact path, including for directories
    # and symlinks. Linking fails if it exists, even after a concurrent init-config.
    if ! ln -T -- "$temporary_file" "$destination"; then
        log_error 'could not create configuration; an existing path will not be overwritten.'
        return 1
    fi

    printf 'Created %s. Edit it to set your server name and email credentials.\n' "$destination"
)
