#!/bin/sh
# Shared test helpers for leaf-ops.
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
        *) printf 'FAIL: %s\n  expected substring: %s\n  in: %s\n' "$3" "$2" "$1" >&2; exit 1 ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) printf 'FAIL: %s\n  unexpected substring: %s\n  in: %s\n' "$3" "$2" "$1" >&2; exit 1 ;;
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
    export ARGV_LOG="$TEST_TMP/argv.log"
    export HOME="$TEST_TMP/home"
    mkdir -p "$STUB_DIR" "$FIXTURE_DIR" "$HOME/.config/leaf-ops"
    : >"$CALL_LOG"; : >"$ARGV_LOG"

    unset LEAF_AUTH LEAF_URL LEAF_CONFIG

    export PATH="$STUB_DIR:$PATH"
    install_curl_stub
}

teardown() { rm -rf "$TEST_TMP"; }

write_default_config() {
    cat >"$HOME/.config/leaf-ops/config" <<CFG
LEAF_URL=https://leaf.test
LEAF_AUTH=claude:s3cr3t
CFG
    chmod 600 "$HOME/.config/leaf-ops/config"
}

# curl stub. Fixtures keyed by METHOD + path:
#   $FIXTURE_DIR/<METHOD>_<path>.body   응답 본문 (기본 빈 문자열)
#   $FIXTURE_DIR/<METHOD>_<path>.code   HTTP 코드 (기본 200)
# 로그 두 개를 남긴다:
#   CALL_LOG  METHOD \t URL \t NETRC파일있음 \t 헤더들
#   ARGV_LOG  argv 전체 — 비밀값이 argv 로 새는지 보려고
install_curl_stub() {
    cat >"$STUB_DIR/curl" <<'CURL_EOF'
#!/bin/sh
log="${CALL_LOG:?}"; alog="${ARGV_LOG:?}"; fix="${FIXTURE_DIR:?}"

printf '%s\n' "$*" >>"$alog"

method="GET"; url=""; write_fmt=""; output_to=""; upload=""; netrc=""; hdrs=""
prev=""
for a in "$@"; do
    case "$prev" in
        -X) method="$a" ;;
        -w) write_fmt="$a" ;;
        -o) output_to="$a" ;;
        -T) upload="$a"; method="PUT" ;;
        --netrc-file) netrc="$a" ;;
        -H) hdrs="$hdrs;$a" ;;
    esac
    case "$a" in https://*|http://*) url="$a" ;; esac
    prev="$a"
done

has_netrc=no
[ -n "$netrc" ] && [ -r "$netrc" ] && has_netrc=yes
printf '%s\t%s\t%s\t%s\n' "$method" "$url" "$has_netrc" "${hdrs#;}" >>"$log"

path_q="$(printf '%s' "$url" | sed -e 's|^https\?://[^/]*||')"
key="$(printf '%s_%s' "$method" "$path_q" | tr '/?&=' '____')"
code="200"; [ -r "$fix/$key.code" ] && code="$(cat "$fix/$key.code")"

emit_body() { [ -r "$fix/$key.body" ] && cat "$fix/$key.body"; }
if [ -n "$output_to" ]; then emit_body >"$output_to"; else emit_body; fi

case "$write_fmt" in
    "") ;;
    *) printf '%s' "$write_fmt" | sed -e "s|%{http_code}|$code|g" -e 's|\\n|\n|g' ;;
esac
exit 0
CURL_EOF
    chmod +x "$STUB_DIR/curl"
}

fixture() {
    key="$(printf '%s_%s' "$1" "$2" | tr '/?&=' '____')"
    printf '%s' "$3" >"$FIXTURE_DIR/$key.body"
}

fixture_code() {
    key="$(printf '%s_%s' "$1" "$2" | tr '/?&=' '____')"
    printf '%s' "$3" >"$FIXTURE_DIR/$key.code"
}

nth_call() { sed -n "${1}p" "$CALL_LOG"; }
call_count() { wc -l <"$CALL_LOG" | tr -d ' '; }
call_urls() { cut -f2 "$CALL_LOG"; }
