#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help ---
setup
out="$("$BIN/gitea-mirror-unlink" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "mirror-name" "--help mentions mirror-name"
teardown

# --- missing mirror-name → die ---
setup
if "$BIN/gitea-mirror-unlink" 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "mirror-name 필수" "error mentions mirror-name requirement"
teardown

# --- unknown flag → die ---
setup
if "$BIN/gitea-mirror-unlink" --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "알 수 없는 flag" "error mentions unknown flag"
teardown

# --- unlink calls DELETE to push_mirrors/<name> ---
setup
install_curl_stub
fixture DELETE /api/v1/repos/owner/repo/push_mirrors/github-mirror ''
"$BIN/gitea-mirror-unlink" github-mirror 2>&1 >/dev/null
call="$(nth_call 1)"
method="$(printf '%s' "$call" | cut -f1)"
url="$(printf '%s'    "$call" | cut -f2)"
assert_eq "$method" "DELETE" "DELETE method"
assert_contains "$url" "/push_mirrors/github-mirror" "unlink endpoint"
teardown

echo OK
