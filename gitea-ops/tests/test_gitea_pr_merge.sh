#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help prints usage and exits 0 ---
setup
out="$("$BIN/gitea-pr-merge" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "PR#" "--help mentions PR# arg"
teardown

# --- missing PR# fails with clear error ---
setup
if "$BIN/gitea-pr-merge" 2>"$TEST_TMP/err"; then
    echo FAIL: expected exit non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
teardown

# --- unknown flag fails ---
setup
if "$BIN/gitea-pr-merge" 1 --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on unknown flag >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "unknown" "error mentions unknown"
teardown

# --- happy path: PR mergeable → fetch + merge → success message ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"},"html_url":"https://gitea.test/owner/repo/pulls/42"}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''   # 200 empty body on success

# Skip git/worktree work for this test by passing --keep-branch and --keep-worktree.
out="$("$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree 2>&1)"
assert_contains "$out" "merged" "success message mentions merged"
assert_contains "$out" "feat/topic" "success message mentions branch"

# verify two API calls: GET pulls/42, then POST .../merge
assert_eq "$(call_count)" "2" "two API calls"
c1="$(nth_call 1)"; assert_contains "$c1" "GET" "1st is GET"
c2="$(nth_call 2)"; assert_contains "$c2" "POST" "2nd is POST"
assert_contains "$c2" "/pulls/42/merge" "2nd hits merge endpoint"
# body should be {"Do":"merge"}
body2="$(printf '%s' "$c2" | cut -f3)"
assert_contains "$body2" '"Do":"merge"' "merge body uses Do=merge"
teardown

# --- already merged: short-circuit, do not POST ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":true,"head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
out="$("$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree 2>&1)" || true
assert_contains "$out" "already merged" "warns already merged"
assert_eq "$(call_count)" "1" "no POST call when already merged"
teardown

# --- --method squash → body uses Do=squash ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
"$BIN/gitea-pr-merge" 42 --method squash --keep-branch --keep-worktree >/dev/null 2>&1
body2="$(nth_call 2 | cut -f3)"
assert_contains "$body2" '"Do":"squash"' "squash method propagates"
teardown

# --- merge endpoint returns error JSON → script dies with message ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"head":{"ref":"feat/topic"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge '{"message":"Pull request is not mergeable"}'
if "$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree 2>"$TEST_TMP/err"; then
    echo "FAIL: expected non-zero on merge error" >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "not mergeable" "error message propagated"
teardown

echo OK
