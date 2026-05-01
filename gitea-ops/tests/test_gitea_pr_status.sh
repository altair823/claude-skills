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

# --- CI success → gate_passed=true, exit 0 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"x","body":"y","draft":false,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"success","total_count":2,"statuses":[{"context":"build","state":"success"},{"context":"lint","state":"success"}]}'

out="$("$BIN/gitea-pr-status" 42)"
assert_contains "$out" "ci_state=success" "ci_state=success"
assert_contains "$out" "ci_count=2" "ci_count=2"
assert_contains "$out" "gate_passed=true" "gate_passed=true"
teardown

# --- CI failure → exit 2 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"x","body":"y","draft":false,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"failure","total_count":1,"statuses":[{"context":"build","state":"failure"}]}'

rc=0
out="$("$BIN/gitea-pr-status" 42 2>"$TEST_TMP/err")" || rc=$?
assert_eq "$rc" "2" "exit 2 on CI failure"
assert_contains "$out" "ci_state=failure" "ci_state=failure"
assert_contains "$out" "gate_passed=false" "gate_passed=false"
teardown

# --- CI error → exit 2 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"x","body":"y","draft":false,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"error","total_count":1,"statuses":[{"context":"build","state":"error"}]}'

rc=0
out="$("$BIN/gitea-pr-status" 42)" || rc=$?
assert_eq "$rc" "2" "exit 2 on CI error"
assert_contains "$out" "ci_state=error" "ci_state=error"
teardown

# --- CI pending without --wait-ci → exit 1 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"x","body":"y","draft":false,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"pending","total_count":1,"statuses":[{"context":"build","state":"pending"}]}'

rc=0
out="$("$BIN/gitea-pr-status" 42)" || rc=$?
assert_eq "$rc" "1" "exit 1 on CI pending without --wait-ci"
assert_contains "$out" "ci_state=pending" "ci_state=pending"
assert_contains "$out" "gate_passed=false" "gate_passed=false"
teardown

# --- --wait-ci: pending → success transition → exit 0 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"x","body":"y","draft":false,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"abc"}}'
# First call: pending. Second call: success.
fixture_seq GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"pending","total_count":1,"statuses":[{"context":"build","state":"pending"}]}' \
    '{"state":"success","total_count":1,"statuses":[{"context":"build","state":"success"}]}'

rc=0
out="$("$BIN/gitea-pr-status" 42 --wait-ci --ci-poll-interval 0 --ci-timeout 5)" || rc=$?
assert_eq "$rc" "0" "exit 0 after pending → success"
assert_contains "$out" "ci_state=success" "final ci_state=success"
teardown

# --- --wait-ci: pending stays → timeout → exit 3 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"x","body":"y","draft":false,"changed_files":1,"base":{"ref":"main","sha":"d"},"head":{"ref":"f","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"pending","total_count":1,"statuses":[{"context":"build","state":"pending"}]}'

rc=0
out="$("$BIN/gitea-pr-status" 42 --wait-ci --ci-poll-interval 1 --ci-timeout 2)" || rc=$?
assert_eq "$rc" "3" "exit 3 on --wait-ci timeout"
assert_contains "$out" "ci_state=pending" "still pending after timeout"
assert_contains "$out" "gate_passed=false" "gate_passed=false"
teardown

echo OK
