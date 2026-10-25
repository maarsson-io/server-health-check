# Mailgun delivery. Call only after load_config has succeeded.

send_mailgun_email() (
    set +x
    set +v

    local subject=$1 body=$2 escaped_key http_status curl_status reason

    if [[ ${SHC_WITHOUT_SENDING:-false} == true ]]; then
        printf 'Subject: %s\n\n%s\n' "$subject" "$body"
        return
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error 'curl is required for email delivery.'
        return 1
    fi

    umask 077

    # Escape curl's quoted config syntax. Pass credentials through stdin so
    # the key is absent from command-line arguments and named temporary files.
    escaped_key=${SHC_MAILGUN_API_KEY//\\/\\\\}
    escaped_key=${escaped_key//\"/\\\"}

    # Ignore .curlrc, keep certificate verification enabled, and do not follow
    # redirects. form-string prevents values from being interpreted as files.
    # Do not retry a POST automatically: a lost response can follow acceptance.
    http_status=$(curl --disable \
        --config - \
        --silent \
        --proto '=https' \
        --connect-timeout 10 \
        --max-time 30 \
        --retry 0 \
        --output /dev/null \
        --write-out '%{http_code}' \
        --form-string "from=$SHC_MAIL_FROM" \
        --form-string "to=$SHC_MAIL_TO" \
        --form-string "subject=$subject" \
        --form-string "text=$body" \
        --url "$SHC_MAILGUN_API_BASE_URL/v3/$SHC_MAILGUN_DOMAIN/messages" \
        2>/dev/null <<< "user = \"api:$escaped_key\"")
    curl_status=$?

    if (( curl_status != 0 )); then
        case $curl_status in
            5|6) reason='DNS resolution failed' ;;
            7) reason='connection failed' ;;
            28) reason='request timed out' ;;
            35|60) reason='TLS connection or certificate verification failed' ;;
            *) reason='request failed' ;;
        esac
        log_error "Mailgun $reason (curl exit code $curl_status); delivery status is unknown."
        return 1
    fi

    case $http_status in
        200)
            printf 'Mailgun accepted the email for delivery. Check the recipient inbox to confirm arrival.\n'
            ;;
        401|403)
            log_error "Mailgun denied the request (HTTP $http_status). Check the API key, domain, region, and sending permissions."
            return 1
            ;;
        [0-9][0-9][0-9])
            log_error "Mailgun returned HTTP $http_status; email acceptance was not confirmed."
            return 1
            ;;
        *)
            log_error 'no valid Mailgun HTTP status was received; delivery status is unknown.'
            return 1
            ;;
    esac
)

send_test_email() {
    local timestamp subject body
    timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC') || return 1
    subject="[$SHC_SERVER_NAME] Server Health: TEST EMAIL"
    body=$(printf 'Server: %s\nDate: %s\n\nServer Health Check test email.\nPurpose: verify email delivery.\nHealth checks: not run.\n' \
        "$SHC_SERVER_NAME" "$timestamp") || return 1
    send_mailgun_email "$subject" "$body"
}
