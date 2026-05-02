#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help ---
setup
out="$("$BIN/gitea-mirror-init" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "--gh-repo" "--help mentions --gh-repo"
assert_contains "$out" "--public" "--help mentions --public"
teardown

# --- missing visibility (--public / --private) → die ---
setup
if "$BIN/gitea-mirror-init" 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "--public 또는 --private" "error mentions visibility flag requirement"
teardown

# --- unknown arg → die ---
setup
if "$BIN/gitea-mirror-init" --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "알 수 없는 인자" "error mentions unknown arg"
teardown

echo OK
