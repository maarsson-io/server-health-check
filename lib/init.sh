# Configuration initialization. Loaded by bin/server-health-check after its root check.

init_config() (
    local template=$1
    local destination=$2
    local temporary_file

    umask 077

    # Also reject dangling symbolic links and non-file paths.
    if [[ -e $destination || -L $destination ]]; then
        printf 'Error: configuration path already exists; nothing was changed.\n' >&2
        return 1
    fi

    if [[ ! -f $template || ! -r $template ]]; then
        printf 'Error: example configuration is missing or unreadable.\n' >&2
        return 1
    fi

    temporary_file=$(mktemp "${destination}.tmp.XXXXXXXXXX") || {
        printf 'Error: could not create a temporary configuration file.\n' >&2
        return 1
    }
    trap 'rm -f -- "$temporary_file"' EXIT
    trap 'exit 1' HUP INT TERM

    if ! cat -- "$template" > "$temporary_file"; then
        printf 'Error: could not copy the example configuration.\n' >&2
        return 1
    fi

    if ! chown 0:0 "$temporary_file" || ! chmod 0600 "$temporary_file"; then
        printf 'Error: could not set configuration ownership or permissions.\n' >&2
        return 1
    fi

    # GNU ln -T treats the destination as an exact path, including for directories
    # and symlinks. Linking fails if it exists, even after a concurrent init.
    if ! ln -T -- "$temporary_file" "$destination"; then
        printf 'Error: could not create configuration; an existing path will not be overwritten.\n' >&2
        return 1
    fi

    printf 'Created %s. Edit it to set your server name and email credentials.\n' "$destination"
)
