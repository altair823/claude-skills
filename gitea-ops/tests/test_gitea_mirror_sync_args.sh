#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help ---
setup
out="$("$BIN/gitea-mirror-sync" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
teardown

# --- unknown arg → die ---
setup
if "$BIN/gitea-mirror-sync" --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "알 수 없는 인자" "error mentions unknown arg"
teardown

# --- sync triggers POST to push_mirrors-sync ---
setup
install_curl_stub
fixture POST /api/v1/repos/owner/repo/push_mirrors-sync ''
"$BIN/gitea-mirror-sync" 2>&1 >/dev/null
call="$(nth_call 1)"
method="$(printf '%s' "$call" | cut -f1)"
url="$(printf '%s'    "$call" | cut -f2)"
assert_eq "$method" "POST" "POST method"
assert_contains "$url" "/push_mirrors-sync" "sync endpoint"
teardown

echo OK
