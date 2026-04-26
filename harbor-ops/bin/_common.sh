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

    # Source the config. Robot account names / secrets may contain '$'
    # (e.g. robot$name) — those values must be single-quoted in the config,
    # otherwise bash treats $name as a parameter expansion and either errors
    # under `set -u` or silently produces the wrong credential. Trap that
    # failure to emit a clearer hint than the raw "unbound variable" message.
    if ! ( set -e; . "$cfg" ) >/dev/null 2>&1; then
        echo "failed to source $cfg" >&2
        echo "  Hint: values containing '\$' (e.g. robot account names like robot\$myrobot)" >&2
        echo "        must be single-quoted, e.g. prod_HARBOR_USER='robot\$myrobot'" >&2
        exit 2
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

# Internal HTTP request. $1=method, $2=path, $3=optional JSON body (empty for none).
# Emits body to stdout. Sets RESPONSE_HEADERS_FILE.
# Exits 2 on 401/403, 1 on other 4xx/5xx and network errors.
_harbor_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local url="${HARBOR_URL%/}${path}"
    local hdrs_file body_file code rc
    hdrs_file="$(mktemp)"
    body_file="$(mktemp)"

    log_debug "$method $url"

    local -a curl_args=(
        -sS
        -o "$body_file"
        -D "$hdrs_file"
        -w '%{http_code}'
        -X "$method"
        -H "Authorization: $(auth_header)"
        -H "Accept: application/json"
    )
    if [ -n "$body" ]; then
        curl_args+=( -H "Content-Type: application/json" --data-binary "$body" )
    fi
    curl_args+=( "$url" )

    set +e
    code="$(curl "${curl_args[@]}")"
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
        409)
            local snippet
            snippet="$(head -c 200 "$body_file" 2>/dev/null || true)"
            echo "conflict: $method $path (HTTP 409)" >&2
            [ -n "$snippet" ] && echo "  body: $snippet" >&2
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

harbor_get()    { _harbor_request GET    "$1"; }
harbor_post()   { _harbor_request POST   "$1" "${2:-}"; }
harbor_put()    { _harbor_request PUT    "$1" "${2:-}"; }
harbor_delete() { _harbor_request DELETE "$1"; }

# Interactive y/N confirm. Args: <prompt>. Honors HARBOR_YES=1 to skip.
# When stdin is not a tty and HARBOR_YES != 1, refuses with an error (exit 4).
confirm() {
    local prompt="$1"
    if [ "${HARBOR_YES:-0}" = "1" ]; then
        log_debug "confirm bypassed (--yes)"
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "refusing without --yes (stdin is not a tty): $prompt" >&2
        exit 4
    fi
    local ans
    printf '%s [y/N] ' "$prompt" >&2
    read -r ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) echo "aborted" >&2; exit 1 ;;
    esac
}

HARBOR_MAX_PAGES="${HARBOR_MAX_PAGES:-200}"
HARBOR_PAGE_SIZE="${HARBOR_PAGE_SIZE:-100}"

# Paginated GET. $1 = path (no query). $2 = optional extra-query string.
# Emits a single concatenated JSON array on stdout.
harbor_get_paginated() {
    local base_path="$1"
    local extra="${2:-}"
    local page=1
    local pages_dir
    pages_dir="$(mktemp -d)"

    while [ "$page" -le "$HARBOR_MAX_PAGES" ]; do
        local q="page=${page}&page_size=${HARBOR_PAGE_SIZE}"
        [ -n "$extra" ] && q="${extra}&${q}"
        # Redirect to file (no command substitution) so harbor_get's
        # exported RESPONSE_HEADERS_FILE survives for the rel="next" check.
        harbor_get "${base_path}?${q}" >"$pages_dir/page-$(printf '%04d' "$page").json"

        if [ -n "${RESPONSE_HEADERS_FILE:-}" ] && [ -r "$RESPONSE_HEADERS_FILE" ] && \
           grep -qiE '^Link:.*rel="next"' "$RESPONSE_HEADERS_FILE"; then
            page=$((page + 1))
            continue
        fi
        break
    done

    if [ "$page" -gt "$HARBOR_MAX_PAGES" ]; then
        echo "warning: pagination truncated at MAX_PAGES=$HARBOR_MAX_PAGES; results may be partial" >&2
    fi

    if ls "$pages_dir"/*.json >/dev/null 2>&1; then
        jq -s 'add // []' "$pages_dir"/*.json
    else
        printf '[]'
    fi
    rm -rf "$pages_dir"
}

# Convert a shell-style glob to an anchored ERE.
# Steps: escape regex metas, then substitute (* → .*, ? → .), then anchor.
glob_to_regex() {
    local g="$1"
    g="${g//\\/\\\\}"
    g="${g//./\\.}"
    g="${g//+/\\+}"
    g="${g//(/\\(}"
    g="${g//)/\\)}"
    g="${g//[/\\[}"
    g="${g//]/\\]}"
    g="${g//\{/\\\{}"
    g="${g//\}/\\\}}"
    g="${g//^/\\^}"
    g="${g//\$/\\\$}"
    g="${g//|/\\|}"
    g="${g//\*/.*}"
    g="${g//\?/.}"
    printf '^%s$' "$g"
}

# Walk up from cwd to git root (or $HOME), scan manifest files in lex order,
# match the active profile's host. On match, print "<project>/<repo>" and return 0.
# Exit 3 with a message on no match. HARBOR_NO_DETECT=1 forces no match.
detect_project() {
    if [ "${HARBOR_NO_DETECT:-0}" = "1" ]; then
        echo "project not detected (HARBOR_NO_DETECT=1)" >&2
        exit 3
    fi

    local host
    host="$(printf '%s' "$HARBOR_URL" | sed -E 's|^https?://([^/]+).*|\1|')"
    if [ -z "$host" ]; then
        echo "no host in HARBOR_URL: $HARBOR_URL" >&2
        exit 2
    fi

    local stop_dir
    if stop_dir="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        :
    else
        stop_dir="$HOME"
    fi

    local cur="$PWD"
    local host_re
    host_re="$(printf '%s' "$host" | sed 's/\./\\./g')"
    local re="${host_re}/([A-Za-z0-9._-]+)/([A-Za-z0-9._/-]+?)(:[A-Za-z0-9._-]+)?"

    while :; do
        local f
        for f in $(find "$cur" -maxdepth 1 -type f \( \
            -name 'Dockerfile' -o -name 'Dockerfile.*' \
            -o -name 'docker-compose.yml' -o -name 'docker-compose.yaml' \
            -o -name 'compose.yml' -o -name 'compose.yaml' \
            -o -name '*.yaml' -o -name '*.yml' \
        \) 2>/dev/null | LC_ALL=C sort); do
            case "$(basename "$f")" in
                docker-compose.yml|docker-compose.yaml|compose.yml|compose.yaml|Dockerfile|Dockerfile.*) ;;
                *.yaml|*.yml)
                    grep -q '^[[:space:]]*image:' "$f" || continue
                    ;;
            esac
            local match
            match="$(grep -E -m1 -o "$re" "$f" 2>/dev/null || true)"
            if [ -n "$match" ]; then
                local rest="${match#${host}/}"
                rest="${rest%%:*}"
                log_debug "detect: $f → $rest"
                printf '%s' "$rest"
                return 0
            fi
        done
        if [ "$cur" = "$stop_dir" ] || [ "$cur" = "/" ]; then
            break
        fi
        cur="$(dirname "$cur")"
    done

    echo "project not detected from manifests; pass <project> explicitly or use --no-detect" >&2
    exit 3
}

# Bytes → IEC string. Falls back to "<n>B" when numfmt is missing.
format_size() {
    local n="$1"
    if [ -z "$n" ] || [ "$n" = "null" ]; then
        printf -- '-'
        return 0
    fi
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B --format='%.1f' -- "$n"
    else
        printf '%sB' "$n"
    fi
}

# render_json: pipe stdin (a JSON array) → stdout (compact).
render_json() {
    jq -c .
}

# render_table: pipe stdin (JSON array) → stdout (aligned table).
# Args: "HEADER=<jq-expr>" pairs. Empty input prints header row + "(no results)" stderr.
render_table() {
    local input
    input="$(cat)"
    local headers=() exprs=()
    local pair name expr
    for pair in "$@"; do
        name="${pair%%=*}"
        expr="${pair#*=}"
        headers+=("$name")
        exprs+=("$expr")
    done

    local hdr_line
    hdr_line="$(IFS=$'\t'; printf '%s' "${headers[*]}")"

    local row_filter=""
    local i
    for i in "${!exprs[@]}"; do
        if [ "$i" -gt 0 ]; then row_filter+=' + "\t" + '; fi
        row_filter+="(${exprs[$i]} | tostring)"
    done

    local count
    count="$(printf '%s' "$input" | jq 'length')"
    if [ "$count" -eq 0 ]; then
        printf '%s\n' "$hdr_line"
        echo "(no results)" >&2
        return 0
    fi

    {
        printf '%s\n' "$hdr_line"
        printf '%s' "$input" | jq -r ".[] | $row_filter"
    } | column -t -s "$(printf '\t')"
}

# apply_filter: pipe JSON array through stdin, get filtered array on stdout.
# Args: <field-jq-expr> <glob>. Empty <glob> = passthrough.
apply_filter() {
    local field="$1" glob="$2"
    if [ -z "$glob" ]; then cat; return; fi
    local re
    re="$(glob_to_regex "$glob")"
    jq --arg re "$re" "map(select((${field}) | tostring | test(\$re)))"
}

# apply_limit: pipe JSON array, slice to first N. Empty N = passthrough.
apply_limit() {
    local n="$1"
    if [ -z "$n" ]; then cat; return; fi
    jq --argjson n "$n" '.[:$n]'
}
