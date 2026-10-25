# Configuration is parsed as data. Never source it or evaluate its contents.

config_error() {
    printf 'Error: %s\n' "$1" >&2
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

load_config() {
    # Do not let shell tracing expose credentials, including during validation.
    set +x
    set +v

    unset SHC_SERVER_NAME SHC_MAILGUN_API_BASE_URL SHC_MAILGUN_DOMAIN
    unset SHC_MAILGUN_API_KEY SHC_MAIL_FROM SHC_MAIL_TO

    local config_path=$1 metadata content status line key value
    local line_number=0 seen='|'
    local parsed_SERVER_NAME='' parsed_MAILGUN_API_BASE_URL='' parsed_MAILGUN_DOMAIN=''
    local parsed_MAILGUN_API_KEY='' parsed_MAIL_FROM='' parsed_MAIL_TO=''
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
            SERVER_NAME|MAILGUN_API_BASE_URL|MAILGUN_DOMAIN|MAILGUN_API_KEY|MAIL_FROM|MAIL_TO) ;;
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

    # Publish values only after the whole file passes. They are not exported.
    SHC_SERVER_NAME=$parsed_SERVER_NAME
    SHC_MAILGUN_API_BASE_URL=$parsed_MAILGUN_API_BASE_URL
    SHC_MAILGUN_DOMAIN=$parsed_MAILGUN_DOMAIN
    SHC_MAILGUN_API_KEY=$parsed_MAILGUN_API_KEY
    SHC_MAIL_FROM=$parsed_MAIL_FROM
    SHC_MAIL_TO=$parsed_MAIL_TO
}
