# Read-only Redis queries. Never inherit an authentication secret from the shell.
redis_query() (
    set +x
    set +v
    unset REDISCLI_AUTH
    LC_ALL=C timeout --kill-after=2s 10s redis-cli -2 --raw -e \
        -h "$SHC_REDIS_HOST" -p "$SHC_REDIS_PORT" "$@" 2>/dev/null
)

redis_persistence_unknown() {
    printf 'Redis persistence: Unknown\n'
    log_error "$1"
    return 1
}

check_redis_persistence() {
    local save_config persistence status line key value seen='|' header=false
    local rdb_enabled=false rdb_status='' aof_enabled='' aof_write='' aof_rewrite='' loading=''
    local result=0

    if [[ ${SHC_REDIS_ENABLED:-false} != true ]]; then
        printf 'Redis persistence: Not checked (REDIS_ENABLED=false)\n'
        return 0
    fi
    if ! command -v redis-cli >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        redis_persistence_unknown 'Redis persistence verification requires redis-cli and timeout.'
        return 1
    fi

    if save_config=$(redis_query CONFIG GET save && printf '.'); then :; else
        status=$?
        redis_persistence_unknown "could not query Redis RDB configuration (exit code $status)."
        return 1
    fi
    # Preserve the empty value's newline with a sentinel, so a truncated reply
    # cannot be mistaken for intentionally disabled RDB scheduling.
    save_config=${save_config%.}
    if [[ $save_config == save$'\n\n' ]]; then
        rdb_enabled=false
    elif [[ $save_config == save$'\n'*$'\n' ]]; then
        value=${save_config#*$'\n'}
        value=${value%$'\n'}
        if [[ ! $value =~ ^[0-9]+[[:blank:]][0-9]+([[:blank:]][0-9]+[[:blank:]][0-9]+)*$ ]]; then
            redis_persistence_unknown 'Redis returned an unsupported RDB save schedule.'
            return 1
        fi
        rdb_enabled=true
    else
        redis_persistence_unknown 'Redis returned an unsupported RDB configuration response.'
        return 1
    fi

    if persistence=$(redis_query INFO persistence); then :; else
        status=$?
        redis_persistence_unknown "could not query Redis persistence status (exit code $status)."
        return 1
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        case $line in
            '# Persistence') header=true; continue ;;
            '') continue ;;
        esac
        if [[ ! $line =~ ^[A-Za-z0-9_]+: ]]; then
            redis_persistence_unknown 'Redis returned an unsupported persistence response.'
            return 1
        fi
        key=${line%%:*}; value=${line#*:}
        case $key in
            loading|aof_enabled|rdb_last_bgsave_status|aof_last_write_status|aof_last_bgrewrite_status)
                if [[ $seen == *"|$key|"* ]]; then
                    redis_persistence_unknown 'Redis returned duplicate persistence fields.'
                    return 1
                fi
                seen+="$key|"
                case $key in
                    loading|aof_enabled)
                        if [[ $value != 0 && $value != 1 ]]; then
                            redis_persistence_unknown 'Redis returned an unsupported persistence flag.'
                            return 1
                        fi
                        printf -v "$key" '%s' "$value"
                        ;;
                    *)
                        if [[ $value != ok && $value != err ]]; then
                            redis_persistence_unknown 'Redis returned an unsupported persistence status.'
                            return 1
                        fi
                        case $key in
                            rdb_last_bgsave_status) rdb_status=$value ;;
                            aof_last_write_status) aof_write=$value ;;
                            aof_last_bgrewrite_status) aof_rewrite=$value ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done <<< "$persistence"
    if [[ $header != true || -z $loading || -z $aof_enabled ||
        ( $rdb_enabled == true && -z $rdb_status ) ||
        ( $aof_enabled == 1 && ( -z $aof_write || -z $aof_rewrite ) ) ]]; then
        redis_persistence_unknown 'Redis persistence response is incomplete.'
        return 1
    fi
    if [[ $loading == 1 ]]; then
        redis_persistence_unknown 'Redis is still loading its dataset; persistence status is not verified.'
        return 1
    fi

    if [[ $rdb_enabled == false ]]; then
        printf 'Redis RDB snapshots: Disabled (no automatic save schedule)\n'
    elif [[ $rdb_status == err ]]; then
        printf 'Redis RDB snapshots: Last background save failed\n'
        result=3
    else
        printf 'Redis RDB snapshots: OK (last background save status)\n'
    fi
    if [[ $aof_enabled == 0 ]]; then
        printf 'Redis AOF: Disabled\n'
    else
        if [[ $aof_write == err ]]; then
            printf 'Redis AOF writes: Failed\n'
            result=3
        else
            printf 'Redis AOF writes: OK\n'
        fi
        if [[ $aof_rewrite == err ]]; then
            printf 'Redis AOF rewrite: Last rewrite failed\n'
            result=3
        else
            printf 'Redis AOF rewrite: OK (last rewrite status)\n'
        fi
    fi
    if (( result == 3 )); then
        printf 'Check the Redis journal and available disk space.\n'
    elif [[ $rdb_enabled == false && $aof_enabled == 0 ]]; then
        printf 'Redis persistence: Not applicable (RDB and AOF disabled)\n'
    fi
    return "$result"
}
