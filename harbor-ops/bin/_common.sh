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
