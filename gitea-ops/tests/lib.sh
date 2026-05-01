#!/bin/sh
# Shared test helpers for gitea-ops shell tests.
# Each test sources this, calls `setup`, runs the script under test, then asserts.

set -eu

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
BIN="$REPO_ROOT/bin"

# --- assertions ---

assert_eq() {
    # $1=actual $2=expected $3=msg
    if [ "$1" != "$2" ]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1" >&2
        exit 1
    fi
}

assert_contains() {
    # $1=haystack $2=needle $3=msg
    case "$1" in
        *"$2"*) ;;
        *)
            printf 'FAIL: %s\n  expected substring: %s\n  in: %s\n' "$3" "$2" "$1" >&2
            exit 1 ;;
    esac
}

assert_file_contains() {
    # $1=path $2=needle $3=msg
    [ -r "$1" ] || { printf 'FAIL: %s\n  no such file: %s\n' "$3" "$1" >&2; exit 1; }
    if ! grep -q -F -- "$2" "$1"; then
        printf 'FAIL: %s\n  not found in %s: %s\n' "$3" "$1" "$2" >&2
        printf 'file content:\n' >&2; cat "$1" >&2
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
    mkdir -p "$STUB_DIR" "$FIXTURE_DIR"
    : >"$CALL_LOG"

    # Use a token file inside sandbox so real ~/.config/gitea-ops/token is untouched.
    export GITEA_TOKEN_FILE="$TEST_TMP/token"
    printf 'fake-token\n' >"$GITEA_TOKEN_FILE"

    # Reviewer token sandbox so real ~/.config/gitea-ops/reviewer-token is untouched.
    export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/reviewer-token"
    printf 'fake-reviewer-token\n' >"$GITEA_REVIEWER_TOKEN_FILE"

    # Default repo coords; tests may override.
    export GITEA_URL="https://gitea.test"
    export GITEA_REPO="owner/repo"

    # Place stubs ahead of real binaries on PATH.
    export PATH="$STUB_DIR:$PATH"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Install a curl stub that responds based on URL+method match against fixture files.
# Fixtures: $FIXTURE_DIR/<METHOD>_<urlencoded-path>.body  → response body
#           $FIXTURE_DIR/<METHOD>_<urlencoded-path>.code  → HTTP status (default 200; only used by callers checking exit)
install_curl_stub() {
    cat >"$STUB_DIR/curl" <<'CURL_EOF'
#!/bin/sh
# Stub: log invocation, then echo fixture body matching last URL arg.
log="${CALL_LOG:?CALL_LOG unset}"
fix="${FIXTURE_DIR:?FIXTURE_DIR unset}"

method="GET"
url=""
data=""
read_stdin=0
prev=""
for a in "$@"; do
    case "$prev" in
        -X) method="$a" ;;
        --data)
            if [ "$a" = "@-" ]; then
                read_stdin=1
            else
                data="$a"
            fi
            ;;
        --data-binary)
            if [ "$a" = "@-" ]; then
                read_stdin=1
            else
                data="$a"
            fi
            ;;
        -F) ;;
        -H) ;;
    esac
    case "$a" in
        https://*|http://*) url="$a" ;;
    esac
    prev="$a"
done

# Stdin body for `--data @-`
if [ "$read_stdin" = "1" ]; then
    data="$(cat)"
fi

# Escape newlines/tabs in body so each call stays on one log line.
data="$(printf '%s' "$data" | awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {printf "%s", $0}' | sed 's/\t/\\t/g')"

# Log: METHOD\turl\tbody
printf '%s\t%s\t%s\n' "$method" "$url" "$data" >>"$log"

# Look up fixture by method + url path.
path="$(printf '%s' "$url" | sed -e 's|^https\?://[^/]*||' -e 's|?.*$||')"
key="$(printf '%s_%s' "$method" "$path" | tr '/?&=' '____')"
body_file="$fix/$key.body"
# Sequenced fixtures: $fix/<key>.seq.<N>.body in order. Counter file <key>.seq.idx
# tracks next index. Falls back to <key>.body if no sequenced fixtures exist.
seq_idx_file="$fix/$key.seq.idx"
if [ -r "$fix/$key.seq.1.body" ]; then
    idx=1
    if [ -r "$seq_idx_file" ]; then
        idx="$(cat "$seq_idx_file")"
    fi
    chosen="$fix/$key.seq.$idx.body"
    if [ ! -r "$chosen" ]; then
        # past the last; reuse last available
        prev=$((idx - 1))
        chosen="$fix/$key.seq.$prev.body"
    else
        next=$((idx + 1))
        printf '%s' "$next" >"$seq_idx_file"
    fi
    cat "$chosen"
elif [ -r "$body_file" ]; then
    cat "$body_file"
else
    :
fi
CURL_EOF
    chmod +x "$STUB_DIR/curl"
}

# Write a fixture body for a (method, path) pair.
fixture() {
    method="$1"; path="$2"; body="$3"
    key="$(printf '%s_%s' "$method" "$path" | tr '/?&=' '____')"
    printf '%s' "$body" >"$FIXTURE_DIR/$key.body"
}

# Read N-th call from log: "METHOD\tURL\tBODY"
nth_call() {
    sed -n "${1}p" "$CALL_LOG"
}

call_count() {
    wc -l <"$CALL_LOG" | tr -d ' '
}

# Sequenced fixture: each subsequent call to (method,path) returns the next body.
# Usage: fixture_seq METHOD /path body1 body2 body3 ...
fixture_seq() {
    method="$1"; path="$2"; shift 2
    key="$(printf '%s_%s' "$method" "$path" | tr '/?&=' '____')"
    n=1
    for body in "$@"; do
        printf '%s' "$body" >"$FIXTURE_DIR/$key.seq.$n.body"
        n=$((n + 1))
    done
}
