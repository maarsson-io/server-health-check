# Compare commits using the live upstream advertisement; never fetch or pull.
git_version_unknown() {
    printf 'Project Git version: Unknown\n'
    log_error "$1"
    return 1
}

check_git_up_to_date() (
    set +x
    set +v
    local top_level branch local_head upstream remote remote_ref extra
    local response remote_head advertised_ref status current_branch current_head current_upstream

    if ! command -v git >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
        git_version_unknown 'Git version verification requires git and timeout.'
        return 1
    fi
    if [[ -z ${SHC_PROJECT_DIRECTORY:-} ]] || ! cd -- "$SHC_PROJECT_DIRECTORY" 2>/dev/null; then
        git_version_unknown 'could not access the project directory for Git verification.'
        return 1
    fi
    if ! top_level=$(git rev-parse --show-toplevel 2>/dev/null) || [[ $top_level != "$(pwd -P)" ]]; then
        git_version_unknown 'Git version verification requires the project root to be a Git working tree.'
        return 1
    fi
    if ! branch=$(git symbolic-ref --quiet HEAD 2>/dev/null) ||
        ! local_head=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null); then
        git_version_unknown 'Git version verification requires a checked-out branch with a commit.'
        return 1
    fi
    # Use the configured remote and remote branch, not a possibly stale local
    # remote-tracking commit. These can have arbitrary names, including in forks.
    if ! upstream=$(git for-each-ref --format='%(upstream:remotename)%09%(upstream:remoteref)' -- "$branch" 2>/dev/null); then
        git_version_unknown 'could not inspect the current branch upstream configuration.'
        return 1
    fi
    IFS=$'\t' read -r remote remote_ref extra <<< "$upstream"
    if [[ -z $remote || $remote_ref != refs/heads/* || -n $extra || $upstream == *$'\n'* ]] ||
        ! git check-ref-format "$remote_ref" >/dev/null 2>&1; then
        git_version_unknown 'the current branch must have an upstream branch configured.'
        return 1
    fi
    if response=$(GIT_TERMINAL_PROMPT=0 timeout --kill-after=5s 30s \
        git ls-remote --exit-code --refs -- "$remote" "$remote_ref" 2>/dev/null); then :; else
        status=$?
        git_version_unknown "could not query the upstream Git branch (exit code $status)."
        return 1
    fi
    IFS=$'\t' read -r remote_head advertised_ref extra <<< "$response"
    if [[ ! $remote_head =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
        $advertised_ref != "$remote_ref" || -n $extra || $response == *$'\n'* ]]; then
        git_version_unknown 'upstream Git query returned an unsupported response.'
        return 1
    fi
    if ! current_branch=$(git symbolic-ref --quiet HEAD 2>/dev/null) ||
        ! current_head=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) ||
        ! current_upstream=$(git for-each-ref --format='%(upstream:remotename)%09%(upstream:remoteref)' -- "$branch" 2>/dev/null) ||
        [[ $current_branch != "$branch" || $current_head != "$local_head" || $current_upstream != "$upstream" ]]; then
        git_version_unknown 'the checkout or its upstream changed during Git verification.'
        return 1
    fi
    if [[ $local_head == "$remote_head" ]]; then
        printf 'Project Git version: Up to date (same commit as upstream)\n'
        return 0
    fi
    printf 'Project Git version: Local and upstream commits differ\n'
    printf 'Review the checkout and its upstream before updating.\n'
    return 3
)
