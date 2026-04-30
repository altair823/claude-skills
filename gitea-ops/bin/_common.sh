#!/bin/sh
# Shared helpers for gitea-ops scripts. Sourced, not executed.
# Requires: curl, jq, git.

set -eu

GITEA_CONFIG="${GITEA_CONFIG:-$HOME/.config/gitea-ops/config}"
GITEA_TOKEN_FILE="${GITEA_TOKEN_FILE:-$HOME/.config/gitea-ops/token}"

die() { printf 'gitea-ops: %s\n' "$*" >&2; exit 1; }

load_token() {
    if [ -n "${GITEA_TOKEN:-}" ]; then
        printf '%s' "$GITEA_TOKEN"; return 0
    fi
    if [ -r "$GITEA_TOKEN_FILE" ]; then
        cat "$GITEA_TOKEN_FILE"; return 0
    fi
    die "token 필요 (GITEA_TOKEN env 또는 $GITEA_TOKEN_FILE 파일)"
}

GITEA_REVIEWER_TOKEN_FILE="${GITEA_REVIEWER_TOKEN_FILE:-$HOME/.config/gitea-ops/reviewer-token}"

load_reviewer_token() {
    if [ -n "${GITEA_REVIEWER_TOKEN:-}" ]; then
        printf '%s' "$GITEA_REVIEWER_TOKEN"; return 0
    fi
    # -s rejects empty placeholder files (Setup recommends `touch reviewer-token`).
    if [ -r "$GITEA_REVIEWER_TOKEN_FILE" ] && [ -s "$GITEA_REVIEWER_TOKEN_FILE" ]; then
        cat "$GITEA_REVIEWER_TOKEN_FILE"; return 0
    fi
    die "reviewer token 필요 (GITEA_REVIEWER_TOKEN env 또는 $GITEA_REVIEWER_TOKEN_FILE 파일)"
}

# Parse remote URL into "<scheme>://<host>" and "owner/repo".
# Accepts https://host/owner/repo(.git) and ssh git@host:owner/repo(.git).
parse_remote() {
    url="$1"
    case "$url" in
        https://*)
            base="${url#https://}"
            host="${base%%/*}"
            path="${base#*/}"
            path="${path%.git}"
            path="${path%/}"
            printf 'https://%s\t%s\n' "$host" "$path"
            ;;
        http://*)
            base="${url#http://}"
            host="${base%%/*}"
            path="${base#*/}"
            path="${path%.git}"
            path="${path%/}"
            printf 'http://%s\t%s\n' "$host" "$path"
            ;;
        git@*)
            base="${url#git@}"
            host="${base%%:*}"
            path="${base#*:}"
            path="${path%.git}"
            printf 'https://%s\t%s\n' "$host" "$path"
            ;;
        ssh://*)
            base="${url#ssh://}"
            base="${base#*@}"
            host="${base%%/*}"
            path="${base#*/}"
            path="${path%.git}"
            printf 'https://%s\t%s\n' "$host" "$path"
            ;;
        *) die "remote URL 파싱 실패: $url" ;;
    esac
}

# Populate GITEA_URL and GITEA_REPO with precedence:
#   1. CLI flags (caller sets via --url / --repo → already exported)
#   2. Env GITEA_URL / GITEA_REPO
#   3. Config file
#   4. git remote origin
resolve_remote() {
    if [ -z "${GITEA_URL:-}" ] || [ -z "${GITEA_REPO:-}" ]; then
        if [ -r "$GITEA_CONFIG" ]; then
            # shellcheck disable=SC1090
            . "$GITEA_CONFIG"
        fi
    fi
    if [ -z "${GITEA_URL:-}" ] || [ -z "${GITEA_REPO:-}" ]; then
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            origin="$(git remote get-url origin 2>/dev/null || true)"
            if [ -n "$origin" ]; then
                parsed="$(parse_remote "$origin")"
                auto_url="$(printf '%s' "$parsed" | cut -f1)"
                auto_repo="$(printf '%s' "$parsed" | cut -f2)"
                : "${GITEA_URL:=$auto_url}"
                : "${GITEA_REPO:=$auto_repo}"
            fi
        fi
    fi
    [ -n "${GITEA_URL:-}" ] || die "GITEA_URL 미설정 (--url / GITEA_URL env / config 파일 중 하나 필요)"
    [ -n "${GITEA_REPO:-}" ] || die "GITEA_REPO 미설정 (--repo / GITEA_REPO env / config 파일 중 하나 필요)"
    export GITEA_URL GITEA_REPO
}

api() {
    method="$1"; path="$2"; shift 2
    token="$(load_token)"
    url="$GITEA_URL/api/v1$path"
    curl -sS -X "$method" \
         -H "Authorization: token $token" \
         -H "Content-Type: application/json" \
         "$@" "$url"
}

# api with body from stdin
api_json() {
    method="$1"; path="$2"
    token="$(load_token)"
    url="$GITEA_URL/api/v1$path"
    # --data-binary preserves bytes verbatim. Plain --data strips CR/LF and can
    # subtly corrupt multi-byte UTF-8 in the wrong locale; use binary always for JSON.
    curl -sS -X "$method" \
         -H "Authorization: token $token" \
         -H "Content-Type: application/json" \
         --data-binary @- \
         "$url"
}

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "필수 명령 없음: $c"
    done
}

# Shell-escape a value for JSON string use via jq
jq_str() { printf '%s' "$1" | jq -Rs . ; }

# GET helper — same auth/url, always GET, no body.
gitea_get() {
    path="$1"
    token="$(load_token)"
    url="$GITEA_URL/api/v1$path"
    curl -sS -X GET \
         -H "Authorization: token $token" \
         -H "Accept: application/json" \
         "$url"
}
