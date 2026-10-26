# Configuration is parsed as data. Never source it or evaluate its contents.

config_error() {
    log_error "$1"
}

config_valid_domain() {
    local domain=$1 label
    local label_pattern='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$'
    local LC_ALL=C

    [[ -n $domain && ${#domain} -le 253 && $domain != .* && $domain != *. ]] || return 1
    while :; do
        label=${domain%%.*}
        [[ ${#label} -le 63 && $label =~ $label_pattern ]] || return 1
        [[ $domain == *.* ]] || break
        domain=${domain#*.}
    done
}

config_valid_email() {
    local address=$1
    # Basic address validation; display names and recipient lists are not supported.
    [[ $address == *@* && $address != *[[:space:]]* && $address != *[\<\>\,\;\"]* ]] || return 1
    local mailbox=${address%@*}
    [[ -n $mailbox && ${#mailbox} -le 64 && $mailbox != *@* ]] || return 1
    config_valid_domain "${address##*@}"
}

# Listener allowlists currently support the two explicit loopback addresses.
config_valid_listener_addresses() {
    case $1 in
        127.0.0.1|::1|127.0.0.1,::1|::1,127.0.0.1) return 0 ;;
        *) return 1 ;;
    esac
}

config_valid_ports() {
    local ports=$1 port seen='|'
    [[ $ports =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    while :; do
        port=${ports%%,*}
        [[ $port =~ ^[1-9][0-9]{0,4}$ ]] || return 1
        (( port <= 65535 )) || return 1
        [[ $seen != *"|$port|"* ]] || return 1
        seen+="$port|"
        [[ $ports == *,* ]] || break
        ports=${ports#*,}
    done
}

config_valid_critical_services() {
    local remaining=$1 unit seen='|'
    [[ $remaining == none ]] && return 0
    [[ -n $remaining && $remaining != *, ]] || return 1
    while :; do
        unit=${remaining%%,*}
        if [[ $unit != 'php*-fpm.service' ]]; then
            [[ ${#unit} -le 255 && $unit =~ ^([A-Za-z0-9:_.@-]|\\x[0-9A-Fa-f][0-9A-Fa-f])+\.service$ &&
                $unit != *@.service ]] || return 1
        fi
        [[ $seen != *"|$unit|"* ]] || return 1
        seen+="$unit|"
        [[ $remaining == *,* ]] || break
        remaining=${remaining#*,}
    done
}

load_config() {
    # Do not let shell tracing expose credentials, including during validation.
    set +x
    set +v

    unset SHC_SERVER_NAME SHC_MAILGUN_API_BASE_URL SHC_MAILGUN_DOMAIN
    unset SHC_MAILGUN_API_KEY SHC_MAIL_FROM SHC_MAIL_TO
    unset SHC_CRITICAL_SERVICES
    unset SHC_REDIS_ENABLED SHC_REDIS_HOST SHC_REDIS_PORT
    unset SHC_MYSQL_ENABLED SHC_MYSQL_LISTEN_PORTS
    unset SHC_MYSQL_ALLOWED_LISTEN_ADDRESSES SHC_REDIS_ALLOWED_LISTEN_ADDRESSES

    local config_path=$1 metadata content status line key value
    local line_number=0 seen='|'
    local parsed_SERVER_NAME='' parsed_MAILGUN_API_BASE_URL='' parsed_MAILGUN_DOMAIN=''
    local parsed_MAILGUN_API_KEY='' parsed_MAIL_FROM='' parsed_MAIL_TO=''
    local parsed_CRITICAL_SERVICES=none
    local parsed_REDIS_ENABLED=false parsed_REDIS_HOST=127.0.0.1 parsed_REDIS_PORT=6379
    local parsed_MYSQL_ENABLED=false parsed_MYSQL_LISTEN_PORTS=3306,33060
    local parsed_MYSQL_ALLOWED_LISTEN_ADDRESSES=127.0.0.1
    local parsed_REDIS_ALLOWED_LISTEN_ADDRESSES=127.0.0.1,::1
    local LC_ALL=C

    if [[ -L $config_path || ! -f $config_path ]]; then
        config_error 'configuration must be an existing regular file, not a symbolic link.'
        return 1
    fi
    metadata=$(stat -c '%u:%g:%a' -- "$config_path") || {
        config_error 'could not inspect configuration ownership and permissions.'
        return 1
    }
    if [[ $metadata != 0:0:600 ]]; then
        config_error 'configuration must be owned by root:root with mode 0600.'
        return 1
    fi

    # Reject NUL bytes and other control characters before Bash can discard them.
    LC_ALL=C grep -aq '[[:cntrl:]]' -- "$config_path"
    status=$?
    case $status in
        0) config_error 'configuration contains control characters; use plain text with LF line endings.'; return 1 ;;
        1) ;;
        *) config_error 'could not inspect configuration.'; return 1 ;;
    esac
    content=$(cat -- "$config_path") || {
        config_error 'could not read configuration.'
        return 1
    }

    while IFS= read -r line; do
        line_number=$((line_number + 1))
        [[ -z $line || $line == \#* ]] && continue
        if [[ $line != *=* ]]; then
            config_error "invalid configuration syntax on line $line_number."
            return 1
        fi
        key=${line%%=*}
        value=${line#*=}
        case $key in
            SERVER_NAME|MAILGUN_API_BASE_URL|MAILGUN_DOMAIN|MAILGUN_API_KEY|MAIL_FROM|MAIL_TO|\
            REDIS_ENABLED|REDIS_HOST|REDIS_PORT|MYSQL_ENABLED|MYSQL_LISTEN_PORTS|\
            MYSQL_ALLOWED_LISTEN_ADDRESSES|REDIS_ALLOWED_LISTEN_ADDRESSES|CRITICAL_SERVICES) ;;
            *) config_error "unknown configuration key on line $line_number."; return 1 ;;
        esac
        if [[ $seen == *"|$key|"* ]]; then
            config_error "duplicate configuration key $key on line $line_number."
            return 1
        fi
        if [[ -z $value || $value == [[:space:]]* || $value == *[[:space:]] ]]; then
            config_error "configuration value $key must be nonempty without surrounding whitespace."
            return 1
        fi
        seen+="$key|"
        # The variable name comes exclusively from the fixed allowlist above.
        printf -v "parsed_$key" '%s' "$value"
    done <<< "$content"

    for key in SERVER_NAME MAILGUN_API_BASE_URL MAILGUN_DOMAIN MAILGUN_API_KEY MAIL_FROM MAIL_TO; do
        if [[ $seen != *"|$key|"* ]]; then
            config_error "missing configuration key $key."
            return 1
        fi
    done

    case $parsed_MAILGUN_API_BASE_URL in
        https://api.mailgun.net|https://api.eu.mailgun.net) ;;
        *) config_error 'MAILGUN_API_BASE_URL must be an official Mailgun US or EU base URL without a trailing slash.'; return 1 ;;
    esac
    if ! config_valid_domain "$parsed_MAILGUN_DOMAIN"; then
        config_error 'invalid MAILGUN_DOMAIN.'
        return 1
    fi
    if [[ $parsed_MAILGUN_API_KEY == replace-with-your-mailgun-api-key || $parsed_MAILGUN_API_KEY == *[[:space:]]* ]]; then
        config_error 'MAILGUN_API_KEY must be replaced with a key without whitespace.'
        return 1
    fi
    for key in MAIL_FROM MAIL_TO; do
        if [[ $key == MAIL_FROM ]]; then
            value=$parsed_MAIL_FROM
        else
            value=$parsed_MAIL_TO
        fi
        if ! config_valid_email "$value"; then
            config_error "invalid $key; use a single email address without a display name."
            return 1
        fi
    done

    case $parsed_REDIS_ENABLED in
        true|false) ;;
        *) config_error 'REDIS_ENABLED must be true or false.'; return 1 ;;
    esac
    case $parsed_REDIS_HOST in
        127.0.0.1|::1) ;;
        *) config_error 'REDIS_HOST must be 127.0.0.1 or ::1.'; return 1 ;;
    esac
    # Validate syntax before arithmetic: no expressions, leading zeros, or
    # overly long numbers may reach Bash arithmetic evaluation.
    if [[ ! $parsed_REDIS_PORT =~ ^[1-9][0-9]{0,4}$ ]] || (( parsed_REDIS_PORT > 65535 )); then
        config_error 'REDIS_PORT must be an integer from 1 to 65535 without leading zeros.'
        return 1
    fi

    case $parsed_MYSQL_ENABLED in
        true|false) ;;
        *) config_error 'MYSQL_ENABLED must be true or false.'; return 1 ;;
    esac
    if ! config_valid_ports "$parsed_MYSQL_LISTEN_PORTS"; then
        config_error 'MYSQL_LISTEN_PORTS must contain unique ports from 1 to 65535, separated by commas without spaces or leading zeros.'
        return 1
    fi
    if ! config_valid_listener_addresses "$parsed_MYSQL_ALLOWED_LISTEN_ADDRESSES" ||
        ! config_valid_listener_addresses "$parsed_REDIS_ALLOWED_LISTEN_ADDRESSES"; then
        config_error 'allowed listener addresses must be 127.0.0.1, ::1, or both separated by a comma without spaces or duplicates.'
        return 1
    fi

    if ! config_valid_critical_services "$parsed_CRITICAL_SERVICES"; then
        config_error 'CRITICAL_SERVICES must be none or unique .service names separated by commas without spaces; only php*-fpm.service supports a wildcard.'
        return 1
    fi

    # Publish values only after the whole file passes. They are not exported.
    SHC_CRITICAL_SERVICES=$parsed_CRITICAL_SERVICES
    SHC_SERVER_NAME=$parsed_SERVER_NAME
    SHC_MAILGUN_API_BASE_URL=$parsed_MAILGUN_API_BASE_URL
    SHC_MAILGUN_DOMAIN=$parsed_MAILGUN_DOMAIN
    SHC_MAILGUN_API_KEY=$parsed_MAILGUN_API_KEY
    SHC_MAIL_FROM=$parsed_MAIL_FROM
    SHC_MAIL_TO=$parsed_MAIL_TO
    SHC_REDIS_ENABLED=$parsed_REDIS_ENABLED
    SHC_REDIS_HOST=$parsed_REDIS_HOST
    SHC_REDIS_PORT=$parsed_REDIS_PORT
    SHC_MYSQL_ENABLED=$parsed_MYSQL_ENABLED
    SHC_MYSQL_LISTEN_PORTS=$parsed_MYSQL_LISTEN_PORTS
    SHC_MYSQL_ALLOWED_LISTEN_ADDRESSES=$parsed_MYSQL_ALLOWED_LISTEN_ADDRESSES
    SHC_REDIS_ALLOWED_LISTEN_ADDRESSES=$parsed_REDIS_ALLOWED_LISTEN_ADDRESSES
}
