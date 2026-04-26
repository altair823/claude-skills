#!/bin/sh
# Shared test helpers for harbor-ops.
set -eu

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BIN="$REPO_ROOT/bin"

# --- assertions ---

assert_eq() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *)
            printf 'FAIL: %s\n  expected substring: %s\n  in: %s\n' "$3" "$2" "$1" >&2
            exit 1 ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*)
            printf 'FAIL: %s\n  unexpected substring: %s\n  in: %s\n' "$3" "$2" "$1" >&2
            exit 1 ;;
        *) ;;
    esac
}

assert_exit_code() {
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s\n  expected exit: %s\n  actual:        %s\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

# --- per-test sandbox ---

setup() {
    TEST_TMP="$(mktemp -d)"
    export TEST_TMP
    export STUB_DIR="$TEST_TMP/stubs"
    export FIXTURE_DIR="$TEST_TMP/fixtures"
    export CALL_LOG="$TEST_TMP/calls.log"
    export HOME="$TEST_TMP/home"
    mkdir -p "$STUB_DIR" "$FIXTURE_DIR" "$HOME/.config/harbor-ops"
    : >"$CALL_LOG"

    # Isolate from ambient env that the dispatcher would honor.
    unset HARBOR_PROFILE HARBOR_DEFAULT_PROFILE HARBOR_DEBUG HARBOR_NO_DETECT
    unset HARBOR_URL HARBOR_USER HARBOR_SECRET HARBOR_PROFILE_NAME

    export PATH="$STUB_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Write a single-profile config under sandboxed $HOME.
write_default_config() {
    cat >"$HOME/.config/harbor-ops/config" <<CFG
HARBOR_DEFAULT_PROFILE=prod
prod_HARBOR_URL=https://harbor.test
prod_HARBOR_USER=alice
prod_HARBOR_SECRET=secret-1
CFG
    chmod 600 "$HOME/.config/harbor-ops/config"
}

# Install a curl stub. Fixtures live at:
#   $FIXTURE_DIR/<METHOD>_<encoded-path-with-query>.body  (response body, default empty)
#   $FIXTURE_DIR/<METHOD>_<encoded-path-with-query>.code  (HTTP code, default 200)
#   $FIXTURE_DIR/<METHOD>_<encoded-path-with-query>.hdrs  (response header lines, default empty)
# Path encoding replaces '/' '?' '&' '=' with '_'.
install_curl_stub() {
    cat >"$STUB_DIR/curl" <<'CURL_EOF'
#!/bin/sh
log="${CALL_LOG:?CALL_LOG unset}"
fix="${FIXTURE_DIR:?FIXTURE_DIR unset}"

method="GET"
url=""
write_fmt=""
dump_headers_to=""
auth_header=""
prev=""
for a in "$@"; do
    case "$prev" in
        -X) method="$a" ;;
        -w) write_fmt="$a" ;;
        -D) dump_headers_to="$a" ;;
        -H)
            case "$a" in
                Authorization:*) auth_header="$a" ;;
            esac
            ;;
    esac
    case "$a" in
        https://*|http://*) url="$a" ;;
    esac
    prev="$a"
done

# Log: METHOD\tURL\tAUTH-HEADER
printf '%s\t%s\t%s\n' "$method" "$url" "$auth_header" >>"$log"

# Fixture key: METHOD + path + query (as-is, with chars normalized)
path_q="$(printf '%s' "$url" | sed -e 's|^https\?://[^/]*||')"
key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"

body_file="$fix/$key.body"
code_file="$fix/$key.code"
hdrs_file="$fix/$key.hdrs"

code="200"
[ -r "$code_file" ] && code="$(cat "$code_file")"

# Write headers if -D requested
if [ -n "$dump_headers_to" ]; then
    printf 'HTTP/1.1 %s\r\n' "$code" >"$dump_headers_to"
    if [ -r "$hdrs_file" ]; then
        cat "$hdrs_file" >>"$dump_headers_to"
    fi
    printf '\r\n' >>"$dump_headers_to"
fi

# Body
if [ -r "$body_file" ]; then
    cat "$body_file"
fi

# -w '%{http_code}' → append code to stdout after body
if [ "$write_fmt" = "%{http_code}" ]; then
    printf '%s' "$code"
fi

exit 0
CURL_EOF
    chmod +x "$STUB_DIR/curl"
}

fixture() {
    method="$1"; path_q="$2"; body="$3"
    key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"
    printf '%s' "$body" >"$FIXTURE_DIR/$key.body"
}

fixture_code() {
    method="$1"; path_q="$2"; code="$3"
    key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"
    printf '%s' "$code" >"$FIXTURE_DIR/$key.code"
}

fixture_hdrs() {
    method="$1"; path_q="$2"; hdrs="$3"
    key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"
    printf '%s' "$hdrs" >"$FIXTURE_DIR/$key.hdrs"
}

nth_call() { sed -n "${1}p" "$CALL_LOG"; }
call_count() { wc -l <"$CALL_LOG" | tr -d ' '; }
