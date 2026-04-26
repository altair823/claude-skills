#!/bin/sh
# Shared helpers for paperboy-ops scripts. Sourced, not executed.
# Requires: curl, jq.

set -eu

PAPERBOY_CONFIG="${PAPERBOY_CONFIG:-$HOME/.config/paperboy-ops/config}"

die() { printf 'paperboy-ops: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
    done
}

# Load config file if present. Values must be shell-safe (single-quoted recommended).
# Required: PAPERBOY_URL, PAPERBOY_USERNAME, PAPERBOY_PASSWORD.
# Optional: PAPERBOY_OPENAPI_PATH (default /openapi.json),
#           PAPERBOY_SWAGGER_PATH (default /swagger-ui/),
#           PAPERBOY_METRICS_USERNAME, PAPERBOY_METRICS_PASSWORD,
#           PAPERBOY_CACERT (path to CA cert for self-signed HTTPS).
load_config() {
    if [ -r "$PAPERBOY_CONFIG" ]; then
        # shellcheck disable=SC1090
        . "$PAPERBOY_CONFIG"
    fi
    [ -n "${PAPERBOY_URL:-}" ] || die "no PAPERBOY_URL (set env or write $PAPERBOY_CONFIG)"
    [ -n "${PAPERBOY_USERNAME:-}" ] || die "no PAPERBOY_USERNAME"
    [ -n "${PAPERBOY_PASSWORD:-}" ] || die "no PAPERBOY_PASSWORD"
    PAPERBOY_OPENAPI_PATH="${PAPERBOY_OPENAPI_PATH:-/openapi.json}"
    PAPERBOY_SWAGGER_PATH="${PAPERBOY_SWAGGER_PATH:-/swagger-ui/}"
    # Trim trailing slash from URL for predictable joining.
    PAPERBOY_URL="${PAPERBOY_URL%/}"
    export PAPERBOY_URL PAPERBOY_USERNAME PAPERBOY_PASSWORD \
           PAPERBOY_OPENAPI_PATH PAPERBOY_SWAGGER_PATH
}

# curl flags for HTTPS — honour custom CA if provided.
curl_tls_flags() {
    if [ -n "${PAPERBOY_CACERT:-}" ]; then
        printf -- '--cacert\n%s\n' "$PAPERBOY_CACERT"
    elif [ -n "${PAPERBOY_INSECURE:-}" ]; then
        printf -- '-k\n'
    fi
}

# Pick credentials. Defaults to the main printer account; pass `metrics` to use
# the Prometheus account (PAPERBOY_METRICS_USERNAME / _PASSWORD).
auth_for() {
    role="${1:-main}"
    case "$role" in
        main)
            printf '%s:%s' "$PAPERBOY_USERNAME" "$PAPERBOY_PASSWORD"
            ;;
        metrics)
            [ -n "${PAPERBOY_METRICS_USERNAME:-}" ] || die "no PAPERBOY_METRICS_USERNAME for --auth metrics"
            [ -n "${PAPERBOY_METRICS_PASSWORD:-}" ] || die "no PAPERBOY_METRICS_PASSWORD for --auth metrics"
            printf '%s:%s' "$PAPERBOY_METRICS_USERNAME" "$PAPERBOY_METRICS_PASSWORD"
            ;;
        *) die "unknown auth role: $role (use 'main' or 'metrics')" ;;
    esac
}

# Generate a ULID-ish unique string for Idempotency-Key when caller wants one.
gen_idem_key() {
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    rnd="$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '%s' "$$$RANDOM")"
    printf 'cli-%s-%s' "$ts" "$rnd"
}
