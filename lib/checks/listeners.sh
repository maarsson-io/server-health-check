# Inspect only configured TCP ports in the current network namespace.
# Do not inspect processes, connect to services, or change network settings.

listener_unknown() {
    printf '%s TCP listeners: Unknown\n' "$1"
    log_error "$2"
    return 1
}

check_service_listeners() {
    local service=$1 ports=$2 allowed=$3 remaining port filter='' separator=''
    local output status line state receive_queue send_queue endpoint peer extra address
    local found=false unexpected=false endpoints='' warnings=''
    remaining=$ports
    while :; do
        port=${remaining%%,*}
        filter+="$separator sport = :$port"
        separator=' or'
        [[ $remaining == *,* ]] || break
        remaining=${remaining#*,}
    done
    if output=$(LC_ALL=C timeout --kill-after=2s 10s ss \
        --tcp --listening --numeric --no-header "( $filter )" 2>/dev/null); then :; else
        status=$?
        listener_unknown "$service" "could not query $service TCP listeners (exit code $status)."
        return 1
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line ]] && continue
        IFS=$' \t' read -r state receive_queue send_queue endpoint peer extra <<< "$line"
        if [[ $state != LISTEN || ! $receive_queue =~ ^[0-9]+$ ||
            ! $send_queue =~ ^[0-9]+$ || -n $extra || $endpoint != *:* ]]; then
            listener_unknown "$service" "$service listener query returned an unsupported response."
            return 1
        fi
        case $peer in
            '0.0.0.0:*'|'[::]:*'|'*:*') ;;
            *) listener_unknown "$service" "$service listener query returned an unsupported peer address."; return 1 ;;
        esac
        port=${endpoint##*:}; address=${endpoint%:*}
        if [[ ! $port =~ ^[1-9][0-9]{0,4}$ || ,$ports, != *",$port,"* ]]; then
            listener_unknown "$service" "$service listener query returned an unexpected port."
            return 1
        fi
        if [[ $address == \[*\] ]]; then
            address=${address#\[}; address=${address%\]}
        fi
        # Numeric IPv4/IPv6 (including a possible IPv6 scope), or wildcard.
        # Only the exact configured loopback addresses may pass the allowlist.
        if [[ $address != '*' &&
            ! $address =~ ^[0-9]+(\.[0-9]+){3}$ &&
            ! ( $address == *:* && $address =~ ^[0-9A-Fa-f:.]+(%[A-Za-z0-9_.-]+)?$ ) ]]; then
            listener_unknown "$service" "$service listener query returned an unsupported local address."
            return 1
        fi
        found=true
        endpoints+="- $endpoint"$'\n'
        if [[ ,$allowed, != *",$address,"* ]]; then
            unexpected=true
            warnings+="- $endpoint"$'\n'
        fi
    done <<< "$output"
    if [[ $found == false ]]; then
        listener_unknown "$service" "no $service TCP listener was found on its configured ports."
        return 1
    fi
    if [[ $unexpected == true ]]; then
        printf '%s TCP listeners: Unexpected address\n%s' "$service" "$warnings"
        printf 'Review the service binding configuration.\n'
        return 3
    fi
    printf '%s TCP listeners: OK\n%s' "$service" "$endpoints"
}

check_listening_interfaces() {
    local result=0 status
    if [[ ${SHC_MYSQL_ENABLED:-false} != true && ${SHC_REDIS_ENABLED:-false} != true ]]; then
        printf 'Listening interfaces: Not checked (MySQL and Redis disabled)\n'
        return 0
    fi
    if ! command -v ss >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        listener_unknown 'Configured services' 'listener verification requires ss and timeout.'
        return 1
    fi
    if [[ ${SHC_MYSQL_ENABLED:-false} == true ]]; then
        if check_service_listeners MySQL "$SHC_MYSQL_LISTEN_PORTS" "$SHC_MYSQL_ALLOWED_LISTEN_ADDRESSES"; then :; else
            result=$?
        fi
    fi
    if [[ ${SHC_REDIS_ENABLED:-false} == true ]]; then
        if check_service_listeners Redis "$SHC_REDIS_PORT" "$SHC_REDIS_ALLOWED_LISTEN_ADDRESSES"; then :; else
            status=$?
            if (( status == 1 || result == 0 )); then result=$status; fi
        fi
    fi
    return "$result"
}
