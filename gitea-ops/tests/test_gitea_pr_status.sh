#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help prints usage ---
setup
out="$("$BIN/gitea-pr-status" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "PR#" "--help mentions PR# arg"
teardown

# --- missing PR# fails ---
setup
if "$BIN/gitea-pr-status" 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "PR# 인자" "error mentions PR#"
teardown

# --- unknown flag fails ---
setup
if "$BIN/gitea-pr-status" 1 --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on unknown flag >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "알 수 없는 flag" "error mentions unknown flag"
teardown

echo OK
