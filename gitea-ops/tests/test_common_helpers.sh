#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
. "$BIN/_common.sh"

setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"merged":false,"head":{"ref":"feat/x"},"base":{"ref":"main"}}'

out="$(gitea_get "/repos/owner/repo/pulls/42")"
assert_contains "$out" '"head"' "gitea_get returns body"

# call must use GET with no body
call="$(nth_call 1)"
method="$(printf '%s' "$call" | cut -f1)"
assert_eq "$method" "GET" "method is GET"

teardown

# --- load_reviewer_token: env wins over file ---
setup
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/rev-token"
printf 'file-token\n' >"$GITEA_REVIEWER_TOKEN_FILE"
GITEA_REVIEWER_TOKEN="env-token" tok="$(load_reviewer_token)"
assert_eq "$tok" "env-token" "env wins over file"
unset GITEA_REVIEWER_TOKEN
teardown

# --- load_reviewer_token: falls back to file ---
setup
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/rev-token"
printf 'file-token\n' >"$GITEA_REVIEWER_TOKEN_FILE"
unset GITEA_REVIEWER_TOKEN || true
tok="$(load_reviewer_token)"
assert_contains "$tok" "file-token" "file fallback"
teardown

# --- load_reviewer_token: missing both → die ---
setup
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/does-not-exist"
unset GITEA_REVIEWER_TOKEN || true
if (load_reviewer_token) 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "reviewer token" "error mentions reviewer token"
teardown

echo OK
