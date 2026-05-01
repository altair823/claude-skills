#!/bin/sh
# Shared helpers for gitea-ops scripts. Sourced, not executed.
# Requires: tea (>= 0.14), jq, git.

# FORBIDDEN ENDPOINTS — review/comment 영속성 보장.
# 본 skill의 어떤 스크립트도 다음 endpoint 를 호출해선 안 된다:
#   PATCH  /repos/{owner}/{repo}/pulls/{index}/reviews/{id}
#   DELETE /repos/{owner}/{repo}/pulls/{index}/reviews/{id}
#   PATCH  /repos/{owner}/{repo}/pulls/{index}/comments/{id}
#   DELETE /repos/{owner}/{repo}/pulls/{index}/comments/{id}
#   PATCH  /repos/{owner}/{repo}/issues/comments/{id}
#   DELETE /repos/{owner}/{repo}/issues/comments/{id}
# 이유: 한 번 등록된 review/inline comment/issue comment 는 PR timeline 의
# 회차 기록으로 영구 보존되어야 한다. 새 스크립트 추가 시에도 이 endpoint
# 호출 금지 (`tea api -X PATCH/DELETE` 도 동일).

set -eu

GITEA_TOKEN_FILE="${GITEA_TOKEN_FILE:-$HOME/.config/gitea-ops/token}"
GITEA_REVIEWER_TOKEN_FILE="${GITEA_REVIEWER_TOKEN_FILE:-$HOME/.config/gitea-ops/reviewer-token}"
GITEA_LOGIN_AUTHOR="${GITEA_LOGIN_AUTHOR:-gitea-ops-author}"
GITEA_LOGIN_REVIEWER="${GITEA_LOGIN_REVIEWER:-gitea-ops-reviewer}"

die() { printf 'gitea-ops: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "필수 명령 없음: $c"
    done
}

# Derive Gitea base URL from current git origin (or GITEA_URL env override).
# Used only when registering a new tea login — tea itself handles host
# resolution for subsequent calls via the stored login.
detect_gitea_host() {
    if [ -n "${GITEA_URL:-}" ]; then printf '%s' "$GITEA_URL"; return 0; fi
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        origin="$(git remote get-url origin 2>/dev/null || true)"
        case "$origin" in
            https://*) base="${origin#https://}"; printf 'https://%s' "${base%%/*}"; return 0 ;;
            http://*)  base="${origin#http://}";  printf 'http://%s'  "${base%%/*}"; return 0 ;;
            git@*)     base="${origin#git@}";     printf 'https://%s' "${base%%:*}"; return 0 ;;
            ssh://*)   base="${origin#ssh://}"; base="${base#*@}"; printf 'https://%s' "${base%%/*}"; return 0 ;;
        esac
    fi
    return 1
}

# Returns 0 if the named tea login already exists, 1 otherwise.
tea_login_exists() {
    name="$1"
    # csv: header row + one row per login. Field 1 is NAME.
    tea logins ls --output csv 2>/dev/null \
        | awk -F, 'NR>1 && $1=="'"$name"'" { found=1 } END { exit found?0:1 }'
}

# Register a tea login if missing. Token resolved from env var, falling back
# to file. Idempotent — pre-existing logins are left untouched.
# Args: $1 login name, $2 env var name (e.g. GITEA_TOKEN), $3 fallback file path
ensure_tea_login() {
    name="$1"; env_var="$2"; file="$3"
    tea_login_exists "$name" && return 0
    eval "tok=\${$env_var:-}"
    if [ -z "${tok:-}" ] && [ -r "$file" ] && [ -s "$file" ]; then
        tok="$(cat "$file")"
    fi
    [ -n "${tok:-}" ] || die "tea login '$name' 미등록 + token 없음 ($env_var env 또는 $file 파일 필요)"
    host="$(detect_gitea_host)" \
        || die "Gitea host 자동 감지 실패 — GITEA_URL env 또는 git remote 필요"
    tea logins add --name "$name" --url "$host" --token "$tok" --no-version-check >/dev/null 2>&1 \
        || die "tea login 등록 실패: $name"
}

# Setup helpers: ensure deps + correct login is registered before any tea call.
require_author_login() {
    require_cmd tea jq git
    ensure_tea_login "$GITEA_LOGIN_AUTHOR" GITEA_TOKEN "$GITEA_TOKEN_FILE"
}

require_reviewer_login() {
    require_cmd tea jq git
    ensure_tea_login "$GITEA_LOGIN_REVIEWER" GITEA_REVIEWER_TOKEN "$GITEA_REVIEWER_TOKEN_FILE"
}

# tea api wrapper — REST call via stored login. JSON-safe (Go net/http sends
# raw bytes; no curl --data CR/LF stripping pitfall).
# Honors GITEA_REPO override; otherwise tea infers owner/repo from cwd.
# TEA_LOGIN env switches the login (default: author). Endpoint may use
# {owner}/{repo} placeholders — tea substitutes from --repo or cwd.
# Args: METHOD, /path, [extra tea api args...]
tea_api() {
    method="$1"; path="$2"; shift 2
    if [ -n "${GITEA_REPO:-}" ]; then
        tea api -X "$method" --login "${TEA_LOGIN:-$GITEA_LOGIN_AUTHOR}" --repo "$GITEA_REPO" "$@" "$path"
    else
        tea api -X "$method" --login "${TEA_LOGIN:-$GITEA_LOGIN_AUTHOR}" "$@" "$path"
    fi
}

# tea_api with JSON body from stdin.
tea_api_json() {
    method="$1"; path="$2"
    if [ -n "${GITEA_REPO:-}" ]; then
        tea api -X "$method" --login "${TEA_LOGIN:-$GITEA_LOGIN_AUTHOR}" --repo "$GITEA_REPO" -d "@-" "$path"
    else
        tea api -X "$method" --login "${TEA_LOGIN:-$GITEA_LOGIN_AUTHOR}" -d "@-" "$path"
    fi
}
