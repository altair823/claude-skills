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

# --- gate pass: all required ok, CI absent → exit 0 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"Add widget","body":"Adds widget","draft":false,"changed_files":3,"base":{"ref":"main","sha":"def"},"head":{"ref":"feat/widget","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"pending","total_count":0,"statuses":[]}'

out="$("$BIN/gitea-pr-status" 42 2>"$TEST_TMP/err")"
rc=$?
assert_eq "$rc" "0" "exit 0 when gate passes"
assert_contains "$out" "title_ok=true" "title_ok in output"
assert_contains "$out" "body_ok=true" "body_ok in output"
assert_contains "$out" "changed_files=3" "changed_files in output"
assert_contains "$out" "draft=false" "draft in output"
assert_contains "$out" "base=main" "base ref in output"
assert_contains "$out" "head=feat/widget" "head ref in output"
assert_contains "$out" "head_sha=abc" "head_sha in output"
assert_contains "$out" "ci_state=none" "ci_state=none when statuses empty"
assert_contains "$out" "ci_count=0" "ci_count in output"
assert_contains "$out" "gate_passed=true" "gate_passed in output"
teardown

# --- gate fail: empty title → exit 1 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"","body":"x","draft":false,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"a"}}'
fixture GET /api/v1/repos/owner/repo/commits/a/status '{"state":"pending","total_count":0,"statuses":[]}'

if out="$("$BIN/gitea-pr-status" 42 2>"$TEST_TMP/err")"; then
    echo FAIL: expected non-zero on empty title >&2; exit 1
fi
assert_contains "$out" "title_ok=false" "title_ok=false reported"
assert_contains "$out" "gate_passed=false" "gate_passed=false reported"
teardown

# --- gate fail: empty body → exit 1 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"x","body":"","draft":false,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"a"}}'
fixture GET /api/v1/repos/owner/repo/commits/a/status '{"state":"pending","total_count":0,"statuses":[]}'

if out="$("$BIN/gitea-pr-status" 42 2>"$TEST_TMP/err")"; then
    echo FAIL: expected non-zero on empty body >&2; exit 1
fi
assert_contains "$out" "body_ok=false" "body_ok=false reported"
teardown

# --- gate fail: changed_files=0 → exit 1 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"x","body":"y","draft":false,"changed_files":0,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"a"}}'
fixture GET /api/v1/repos/owner/repo/commits/a/status '{"state":"pending","total_count":0,"statuses":[]}'

if out="$("$BIN/gitea-pr-status" 42 2>"$TEST_TMP/err")"; then
    echo FAIL: expected non-zero on changed_files=0 >&2; exit 1
fi
assert_contains "$out" "changed_files=0" "changed_files=0 reported"
assert_contains "$out" "gate_passed=false" "gate_passed=false reported"
teardown

# --- gate fail: draft=true → exit 1 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"x","body":"y","draft":true,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"a"}}'
fixture GET /api/v1/repos/owner/repo/commits/a/status '{"state":"pending","total_count":0,"statuses":[]}'

if out="$("$BIN/gitea-pr-status" 42 2>"$TEST_TMP/err")"; then
    echo FAIL: expected non-zero on draft >&2; exit 1
fi
assert_contains "$out" "draft=true" "draft=true reported"
assert_contains "$out" "gate_passed=false" "gate_passed=false reported"
teardown

# --- 404 PR → die ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/999 '{"message":"Not found"}'
if "$BIN/gitea-pr-status" 999 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on 404 >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "999" "error mentions PR number"
teardown

echo OK
