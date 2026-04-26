#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help ---
setup
out="$("$BIN/gitea-pr-review" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "--event" "--help mentions --event"
teardown

# --- missing PR# ---
setup
if "$BIN/gitea-pr-review" --event APPROVE --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
teardown

# --- missing --event ---
setup
if "$BIN/gitea-pr-review" 42 --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "event" "error mentions event"
teardown

# --- invalid --event ---
setup
if "$BIN/gitea-pr-review" 42 --event NOPE --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "invalid --event" "error mentions invalid event"
teardown

# --- missing --body and no inline ---
setup
if "$BIN/gitea-pr-review" 42 --event APPROVE 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "body" "error mentions body"
teardown

# --- both --body - and --inline - read stdin → die ---
setup
if echo x | "$BIN/gitea-pr-review" 42 --event APPROVE --body - --inline - 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "stdin" "error mentions stdin conflict"
teardown

# --- reviewer-token missing → die ---
setup
install_curl_stub
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/no-such-file"
unset GITEA_REVIEWER_TOKEN || true
if "$BIN/gitea-pr-review" 42 --event APPROVE --body ok 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "reviewer token" "error mentions reviewer token"
teardown

echo OK
