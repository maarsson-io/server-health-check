# Configuration initialization. Loaded by bin/server-health-check after its root check.

# Validate literal KEY=value syntax without evaluating values or requiring fully
# configured credentials. Print only the key set, never the configuration values.
init_config_keys() {
    local path=$1 label=$2 line key value status line_number=0 seen='|'
    local LC_ALL=C
    grep -aq '[[:cntrl:]]' -- "$path"
    status=$?
    case $status in
        1) ;;
        0) log_error "$label contains control characters; use LF line endings."; return 1 ;;
        *) log_error "could not inspect $label."; return 1 ;;
    esac
    while IFS= read -r line || [[ -n $line ]]; do
        line_number=$((line_number + 1))
        [[ -z $line || $line == \#* ]] && continue
        key=${line%%=*}; value=${line#*=}
        if [[ $line != *=* || ! $key =~ ^[A-Z][A-Z0-9_]*$ || -z $value ||
            $value == [[:space:]]* || $value == *[[:space:]] ]]; then
            log_error "invalid $label syntax on line $line_number."
            return 1
        fi
        if [[ $seen == *"|$key|"* ]]; then
            log_error "duplicate key in $label on line $line_number."
            return 1
        fi
        seen+="$key|"
    done < "$path"
    printf '%s' "$seen"
}

init_config() (
    # Existing files contain credentials. Tracing must never print their values.
    set +x
    set +v
    local template=$1 destination=$2 directory temporary_file=''
    local existing=false metadata='' current_metadata keys line key missing=''

    umask 077
    if [[ ! -f $template || ! -r $template || -L $template ]]; then
        log_error 'example configuration is missing, unreadable, or a symbolic link.'
        return 1
    fi
    directory=$(dirname -- "$destination") || return 1
    # Serialize cooperating initializers without creating a permanent lock file.
    # The subshell releases the directory lock when it exits.
    if ! { exec 9< "$directory"; } || ! flock --exclusive --wait 10 9; then
        log_error 'could not lock the configuration directory.'
        return 1
    fi
    if [[ -e $destination || -L $destination ]]; then
        if [[ ! -f $destination || -L $destination ]]; then
            log_error 'configuration must be a regular file, not a symbolic link.'
            return 1
        fi
        metadata=$(stat -c '%u:%g:%a:%d:%i:%s:%y:%z' -- "$destination") || {
            log_error 'could not inspect configuration ownership and permissions.'
            return 1
        }
        if [[ $metadata != 0:0:600:* ]]; then
            log_error 'configuration must be owned by root:root with mode 0600.'
            return 1
        fi
        existing=true
    fi
    init_config_keys "$template" 'example configuration' >/dev/null || return 1
    if [[ $existing == true ]]; then
        keys=$(init_config_keys "$destination" 'configuration') || return 1
        while IFS= read -r line || [[ -n $line ]]; do
            [[ -z $line || $line == \#* ]] && continue
            key=${line%%=*}
            if [[ $keys != *"|$key|"* ]]; then
                missing+="$line"$'\n'
            fi
        done < "$template"
        if [[ -z $missing ]]; then
            printf 'Configuration is already up to date; nothing was changed.\n'
            return 0
        fi
    fi

    temporary_file=$(mktemp "${destination}.tmp.XXXXXXXXXX") || {
        log_error 'could not create a temporary configuration file.'
        return 1
    }
    trap 'rm -f -- "$temporary_file"' EXIT
    trap 'exit 1' HUP INT TERM
    if [[ $existing == true ]]; then
        if ! cat -- "$destination" > "$temporary_file" ||
            ! printf '\n# Settings added by init-config.\n%s' "$missing" >> "$temporary_file"; then
            log_error 'could not prepare the updated configuration.'
            return 1
        fi
    elif ! cat -- "$template" > "$temporary_file"; then
        log_error 'could not copy the example configuration.'
        return 1
    fi
    if ! chown 0:0 "$temporary_file" || ! chmod 0600 "$temporary_file"; then
        log_error 'could not set configuration ownership or permissions.'
        return 1
    fi

    if [[ $existing == true ]]; then
        current_metadata=$(stat -c '%u:%g:%a:%d:%i:%s:%y:%z' -- "$destination") || {
            log_error 'could not recheck configuration before replacement.'
            return 1
        }
        if [[ -L $destination || $current_metadata != "$metadata" ]]; then
            log_error 'configuration changed during initialization; nothing was replaced.'
            return 1
        fi
        # The temporary file is on the same filesystem: rename is atomic.
        if ! mv -T -- "$temporary_file" "$destination"; then
            log_error 'could not replace configuration with the updated file.'
            return 1
        fi
        printf 'Added missing settings to %s. Existing settings were preserved.\n' "$destination"
    else
        # Never overwrite a path created after the initial existence check.
        if ! ln -T -- "$temporary_file" "$destination"; then
            log_error 'could not create configuration; an existing path will not be overwritten.'
            return 1
        fi
        printf 'Created %s. Edit it to set your server name and email credentials.\n' "$destination"
    fi
)
