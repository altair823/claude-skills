#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help prints usage, exits 0 ---
setup
out="$("$BIN/gitea-pr-diff" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "PR#" "--help mentions PR# arg"
teardown

# --- missing PR# fails with clear error ---
setup
if "$BIN/gitea-pr-diff" 2>"$TEST_TMP/err"; then
    echo FAIL: expected exit non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
teardown

# --- unknown flag fails ---
setup
if "$BIN/gitea-pr-diff" 1 --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on unknown flag >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "unknown" "error mentions unknown"
teardown

# --- --raw and --json mutually exclusive ---
setup
if "$BIN/gitea-pr-diff" 1 --raw --json 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on conflicting flags >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "mutually exclusive" "error names conflict"
teardown

echo OK
