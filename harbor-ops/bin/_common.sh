#!/usr/bin/env bash
# harbor-ops shared library. Sourced by bin/harbor-ls. Not executable on its own.
set -euo pipefail

# Load config and resolve the active profile.
# Args: optionally --profile <name>.
# Honors HARBOR_PROFILE env. Sets globals: HARBOR_URL, HARBOR_USER,
# HARBOR_SECRET, HARBOR_PROFILE_NAME.
# Exits 2 on any error with a message naming the missing piece.
load_profile() {
    local cfg="$HOME/.config/harbor-ops/config"
    if [ ! -r "$cfg" ]; then
        echo "config missing: $cfg" >&2
        exit 2
    fi

    local cli_profile=""
    if [ "${1:-}" = "--profile" ]; then
        cli_profile="${2:-}"
        if [ -z "$cli_profile" ]; then
            echo "--profile requires a value" >&2
            exit 4
        fi
    fi

    # shellcheck disable=SC1090
    . "$cfg"

    local profile=""
    if [ -n "$cli_profile" ]; then
        profile="$cli_profile"
    elif [ -n "${HARBOR_PROFILE:-}" ]; then
        profile="$HARBOR_PROFILE"
    elif [ -n "${HARBOR_DEFAULT_PROFILE:-}" ]; then
        profile="$HARBOR_DEFAULT_PROFILE"
    else
        # Auto-pick if exactly one *_HARBOR_URL exists.
        local names=()
        local v
        while IFS= read -r v; do names+=("$v"); done < <(
            compgen -A variable | sed -n 's/_HARBOR_URL$//p'
        )
        if [ "${#names[@]}" -eq 1 ]; then
            profile="${names[0]}"
        else
            echo "no profile selected: pass --profile, set HARBOR_PROFILE, or set HARBOR_DEFAULT_PROFILE" >&2
            exit 2
        fi
    fi

    local url_var="${profile}_HARBOR_URL"
    local user_var="${profile}_HARBOR_USER"
    local secret_var="${profile}_HARBOR_SECRET"
    local secret_file_var="${profile}_HARBOR_SECRET_FILE"

    HARBOR_URL="${!url_var:-}"
    HARBOR_USER="${!user_var:-}"
    HARBOR_PROFILE_NAME="$profile"

    if [ -z "$HARBOR_URL" ]; then
        echo "missing ${url_var} in config" >&2; exit 2
    fi
    if [ -z "$HARBOR_USER" ]; then
        echo "missing ${user_var} in config" >&2; exit 2
    fi

    if [ -n "${!secret_var:-}" ]; then
        HARBOR_SECRET="${!secret_var}"
    elif [ -n "${!secret_file_var:-}" ]; then
        local sf="${!secret_file_var}"
        case "$sf" in "~/"*) sf="$HOME/${sf#\~/}" ;; esac
        if [ ! -r "$sf" ]; then
            echo "secret file unreadable: $sf" >&2; exit 2
        fi
        local uname_s
        uname_s="$(uname -s 2>/dev/null || echo unknown)"
        case "$uname_s" in
            MINGW*|MSYS*|CYGWIN*) ;;
            *)
                local mode
                mode="$(stat -c '%a' "$sf" 2>/dev/null || stat -f '%Lp' "$sf" 2>/dev/null || echo "")"
                case "$mode" in
                    ""|600|400) ;;
                    *) echo "warning: $sf has mode $mode (expected 600 or stricter)" >&2 ;;
                esac
                ;;
        esac
        HARBOR_SECRET="$(cat "$sf")"
    else
        echo "missing ${secret_var} or ${secret_file_var} in config" >&2; exit 2
    fi

    export HARBOR_URL HARBOR_USER HARBOR_SECRET HARBOR_PROFILE_NAME
}

# Build the Basic auth header value for the active profile.
auth_header() {
    local raw="$HARBOR_USER:$HARBOR_SECRET"
    if printf '' | base64 -w0 >/dev/null 2>&1; then
        printf 'Basic %s' "$(printf '%s' "$raw" | base64 -w0)"
    else
        printf 'Basic %s' "$(printf '%s' "$raw" | base64 | tr -d '\n')"
    fi
}

log_debug() {
    if [ "${HARBOR_DEBUG:-0}" = "1" ]; then
        printf '[harbor-ops] %s\n' "$*" >&2
    fi
}

# Single GET. $1 = path (with optional ?query). Emits body to stdout.
# Sets RESPONSE_HEADERS_FILE = path to a tmpfile with response headers.
# Exits 2 on 401/403, 1 on other 4xx/5xx, 1 on network error.
harbor_get() {
    local path="$1"
    local url="${HARBOR_URL%/}${path}"
    local hdrs_file body_file code rc
    hdrs_file="$(mktemp)"
    body_file="$(mktemp)"

    log_debug "GET $url"
    set +e
    code="$(curl -sS -o "$body_file" -D "$hdrs_file" -w '%{http_code}' \
        -H "Authorization: $(auth_header)" \
        -H "Accept: application/json" \
        "$url")"
    rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        rm -f "$hdrs_file" "$body_file"
        echo "network error reaching $url (curl exit $rc)" >&2
        exit 1
    fi

    case "$code" in
        2*)
            cat "$body_file"
            export RESPONSE_HEADERS_FILE="$hdrs_file"
            rm -f "$body_file"
            return 0
            ;;
        401|403)
            echo "auth failed for profile ${HARBOR_PROFILE_NAME} at ${HARBOR_URL} (HTTP $code); check HARBOR_USER / HARBOR_SECRET" >&2
            rm -f "$hdrs_file" "$body_file"
            exit 2
            ;;
        404)
            echo "not found: $path (HTTP 404)" >&2
            rm -f "$hdrs_file" "$body_file"
            exit 1
            ;;
        *)
            local snippet
            snippet="$(head -c 200 "$body_file" 2>/dev/null || true)"
            echo "API error: HTTP $code at $url" >&2
            [ -n "$snippet" ] && echo "  body: $snippet" >&2
            rm -f "$hdrs_file" "$body_file"
            exit 1
            ;;
    esac
}
