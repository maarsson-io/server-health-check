# Update this checkout only, then invoke the updated entry point for config sync.
self_update() (
    set +x
    set +v
    local project_directory top_level changes marker marker_path status

    if ! command -v git >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1 ||
        ! command -v flock >/dev/null 2>&1; then
        log_error 'self-update requires git, timeout, and flock.'
        return 1
    fi
    if ! cd -- "$1" 2>/dev/null; then
        log_error 'could not access the project directory.'
        return 1
    fi
    project_directory=$(pwd -P) || return 1
    if ! top_level=$(git rev-parse --show-toplevel 2>/dev/null) ||
        [[ $top_level != "$project_directory" ]]; then
        log_error 'self-update requires the project to be the root of a Git working tree.'
        return 1
    fi

    # Serialize self-update invocations; no persistent lock file is needed.
    if ! { exec 8< "$project_directory"; } || ! flock --exclusive --wait 10 8; then
        log_error 'could not lock the project directory for self-update.'
        return 1
    fi
    if ! git symbolic-ref --quiet HEAD >/dev/null 2>&1; then
        log_error 'self-update requires a checked-out branch, not a detached HEAD.'
        return 1
    fi
    if ! git rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1; then
        log_error 'the current branch must have an existing upstream branch configured.'
        return 1
    fi
    for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer BISECT_LOG; do
        marker_path=$(git rev-parse --git-path "$marker" 2>/dev/null) || {
            log_error 'could not inspect the Git operation state.'
            return 1
        }
        if [[ -e $marker_path ]]; then
            log_error 'finish the in-progress Git operation before self-update.'
            return 1
        fi
    done
    if ! changes=$(git status --porcelain=v1 --untracked-files=normal --ignore-submodules=none 2>/dev/null); then
        log_error 'could not inspect the Git working tree.'
        return 1
    fi
    if [[ -n $changes ]]; then
        log_error 'self-update requires a clean working tree, including untracked files.'
        return 1
    fi

    printf 'Updating the current branch from its configured upstream...\n'
    # Explicit options override pull/rebase/autostash preferences. Suppress raw
    # output because a remote URL or credential-helper error may contain secrets.
    if GIT_TERMINAL_PROMPT=0 timeout --kill-after=5s 120s git pull \
        --ff-only --no-rebase --no-autostash --no-edit --recurse-submodules=no \
        >/dev/null 2>&1; then :; else
        status=$?
        log_error "Git fast-forward update failed (exit code $status); config initialization was not run."
        return 1
    fi

    printf 'Git update completed. Synchronizing configuration with the updated version...\n'
    # Do not source an old copy of init.sh or reuse the currently running CLI.
    if ! "$project_directory/bin/server-health-check" init-config; then
        log_error 'the project was updated, but init-config failed; fix the configuration and rerun init-config.'
        return 1
    fi
    printf 'Self-update completed.\n'
)
