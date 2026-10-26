# Inspect failed system-wide services without changing their state.

parse_failed_services() {
    awk '
        NF == 0 { next }
        {
            # --plain --no-legend --full yields UNIT LOAD ACTIVE SUB DESCRIPTION.
            # Preserve systemd escaped names, but never include descriptions in
            # the report: they are unnecessary and may contain private details.
            if (NF < 4 || $1 !~ /^([A-Za-z0-9:_.@-]|\\x[0-9A-Fa-f][0-9A-Fa-f])+\.service$/ ||
                $3 != "failed" || $4 != "failed" || seen[$1]++) {
                bad=1
                next
            }
            units[++count]=$1
        }
        END {
            if (bad) exit 1
            printf "Failed systemd services: %d\n", count
            for (i=1; i<=count; i++) print "- " units[i]
            if (count > 0) {
                print "Review the failed service journals."
                exit 3
            }
        }
    '
}

check_failed_services() {
    local services report status

    if ! command -v systemctl >/dev/null 2>&1 ||
        ! command -v timeout >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
        printf 'Failed systemd services: Unknown\n'
        log_error 'failed-service verification requires systemctl, timeout, and awk.'
        return 1
    fi

    if services=$(LC_ALL=C SYSTEMD_COLORS=0 timeout --kill-after=2s 15s \
        systemctl --system list-units --type=service --state=failed --all \
        --plain --no-legend --no-pager --full 2>/dev/null); then
        :
    else
        status=$?
        printf 'Failed systemd services: Unknown\n'
        log_error "could not query failed systemd services (exit code $status)."
        return 1
    fi

    if report=$(printf '%s\n' "$services" | LC_ALL=C parse_failed_services); then
        status=0
    else
        status=$?
    fi
    case $status in
        0|3)
            printf '%s\n' "$report"
            return "$status"
            ;;
        *)
            printf 'Failed systemd services: Unknown\n'
            log_error 'failed-service query returned an unsupported or inconsistent result.'
            return 1
            ;;
    esac
}

# Match each configured name against Names, which also includes unit aliases.
parse_critical_services() {
    SHC_CRITICAL_REQUESTED="$1" SHC_CRITICAL_MISSING_PHP="$2" LC_ALL=C awk '
        function finish(   i,matched,signature,level) {
            if (!fields) return
            if (fields != 5 || !id || !names || !load || !active || !substate) { bad=1; return }
            matched=0
            if (!index(" " names " "," " id " ")) { bad=1; return }
            level=1
            if (load == "loaded") {
                if (active == "active" && substate == "running") level=0
                else if (active == "inactive" || active == "failed" ||
                         (active == "active" && substate == "exited")) level=3
            } else if (load ~ /^(not-found|masked|error|bad-setting)$/) level=3
            signature=id "|" load "|" active "|" substate
            for (i=1; i<=count; i++) {
                if (!index(" " names " "," " units[i] " ")) continue
                matched=1
                # Aliases may cause systemctl to repeat the same unit block.
                if (seen[i] && seen[i] != signature) bad=1
                seen[i]=signature; levels[i]=level
                states[i]=load "/" active "/" substate
            }
            if (!matched) bad=1
        }
        function reset() {
            fields=0; id=""; names=""; load=""; active=""; substate=""
            delete keys
        }
        BEGIN {
            count=split(ENVIRON["SHC_CRITICAL_REQUESTED"],units,",")
            missing_php=ENVIRON["SHC_CRITICAL_MISSING_PHP"]+0
            reset()
        }
        /^$/ { finish(); reset(); next }
        {
            at=index($0,"="); key=substr($0,1,at-1); value=substr($0,at+1)
            if (!at || keys[key]++) { bad=1; next }
            fields++
            if (key == "Id") id=value
            else if (key == "Names") names=value
            else if (key == "LoadState") load=value
            else if (key == "ActiveState") active=value
            else if (key == "SubState") substate=value
            else { bad=1; next }
            if (key ~ /^(LoadState|ActiveState|SubState)$/ && value !~ /^[a-z-]+$/) bad=1
        }
        END {
            finish()
            for (i=1; i<=count; i++) if (!seen[i]) bad=1
            if (bad) exit 1
            actionable=missing_php; unknown=0; running=0
            for (i=1; i<=count; i++) {
                if (levels[i] == 0) running++
                else if (levels[i] == 3) actionable++
                else unknown++
            }
            if (unknown) print "Critical systemd services: Unknown"
            else if (actionable) print "Critical systemd services: Action required"
            else printf "Critical systemd services: OK (%d running)\n", running
            for (i=1; i<=count; i++) if (levels[i] != 0)
                printf "- %s: %s\n", units[i], states[i]
            if (missing_php) print "- php*-fpm.service: No installed PHP-FPM service found"
            if (unknown) exit 1
            if (actionable) {
                print "Review the configured services and their journals."
                exit 3
            }
        }
    '
}

check_critical_services() {
    local configured=${SHC_CRITICAL_SERVICES:-none} remaining unit output report status
    local effective='' seen='|' php_units='' missing_php=0 line state preset extra
    local -a units=()
    if [[ $configured == none ]]; then
        printf 'Critical systemd services: Not configured\n'
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1 ||
        ! command -v timeout >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
        printf 'Critical systemd services: Unknown\n'
        log_error 'critical-service verification requires systemctl, timeout, and awk.'
        return 1
    fi
    if [[ ,$configured, == *',php*-fpm.service,'* ]]; then
        # Unlike show with a glob, list-unit-files also finds installed services
        # which are inactive and not currently loaded into systemd memory.
        if output=$(LC_ALL=C SYSTEMD_COLORS=0 timeout --kill-after=2s 15s \
            systemctl --system list-unit-files --type=service --no-legend \
            --no-pager --full 2>/dev/null); then :; else
            status=$?
            printf 'Critical systemd services: Unknown\n'
            log_error "could not list installed PHP-FPM services (exit code $status)."
            return 1
        fi
        while IFS= read -r line || [[ -n $line ]]; do
            [[ -z $line ]] && continue
            IFS=$' \t' read -r unit state preset extra <<< "$line"
            if [[ ! $unit =~ ^([A-Za-z0-9:_.@-]|\\x[0-9A-Fa-f][0-9A-Fa-f])+\.service$ ||
                ! $state =~ ^[a-z-]+$ || ( -n $preset && ! $preset =~ ^[a-z-]+$ ) || -n $extra ]]; then
                printf 'Critical systemd services: Unknown\n'
                log_error 'PHP-FPM service discovery returned an unsupported response.'
                return 1
            fi
            [[ $unit =~ ^php[A-Za-z0-9_.@:-]*-fpm\.service$ ]] || continue
            if [[ ,$php_units, == *",$unit,"* ]]; then
                printf 'Critical systemd services: Unknown\n'
                log_error 'PHP-FPM service discovery returned duplicate units.'
                return 1
            fi
            php_units+="${php_units:+,}$unit"
        done <<< "$output"
        [[ -n $php_units ]] || missing_php=1
    fi
    remaining=$configured
    while :; do
        unit=${remaining%%,*}
        if [[ $unit == 'php*-fpm.service' ]]; then
            remaining="${php_units}${remaining#"$unit"}"
            if [[ $remaining == ,* ]]; then remaining=${remaining#,}; fi
            [[ -n $remaining ]] || break
            continue
        fi
        if [[ $seen != *"|$unit|"* ]]; then
            units+=("$unit"); effective+="${effective:+,}$unit"; seen+="$unit|"
        fi
        [[ $remaining == *,* ]] || break
        remaining=${remaining#*,}
    done
    if [[ -z $effective ]]; then
        printf 'Critical systemd services: Action required\n'
        printf '%s\n' '- php*-fpm.service: No installed PHP-FPM service found'
        return 3
    fi
    if output=$(LC_ALL=C SYSTEMD_COLORS=0 timeout --kill-after=2s 15s \
        systemctl --system show --all --property=Id,Names,LoadState,ActiveState,SubState \
        -- "${units[@]}" 2>/dev/null); then :; else
        status=$?
        printf 'Critical systemd services: Unknown\n'
        log_error "could not query critical systemd services (exit code $status)."
        return 1
    fi
    if report=$(printf '%s\n' "$output" | parse_critical_services "$effective" "$missing_php"); then status=0; else status=$?; fi
    case $status in
        0|3) printf '%s\n' "$report"; return "$status" ;;
        *)
            if [[ -n $report ]]; then printf '%s\n' "$report"; else printf 'Critical systemd services: Unknown\n'; fi
            log_error 'one or more critical-service states could not be verified.'
            return 1
            ;;
    esac
}
