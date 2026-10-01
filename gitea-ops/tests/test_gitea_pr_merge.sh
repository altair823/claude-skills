#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

OPEN_PR='{"number":42,"state":"open","merged":false,"draft":false,"mergeable":true,"head":{"ref":"feat/topic","sha":"abc123"},"html_url":"https://gitea.test/owner/repo/pulls/42"}'
MERGED_PR='{"number":42,"state":"closed","merged":true,"head":{"ref":"feat/topic","sha":"abc123"},"html_url":"https://gitea.test/owner/repo/pulls/42"}'

# tea 로그인이 하나도 없는 stub. 로그인 확인까지 가면 "tea login" 오류가 난다.
no_login_stub() {
    cat >"$STUB_DIR/tea" <<'EOF'
#!/bin/sh
case "${1:-}" in
    logins) printf 'NAME,URL,SSH HOST,USER,DEFAULT\n'; exit 0 ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$STUB_DIR/tea"
    unset GITEA_TOKEN || true
    export GITEA_TOKEN_FILE="$TEST_TMP/no-such-file"
}

no_merge_post() {
    if grep -q "/pulls/42/merge" "$CALL_LOG"; then
        echo "FAIL: $1" >&2; exit 1
    fi
}

# --- --help ---
setup
out="$("$BIN/gitea-pr-merge" --help 2>&1)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "--style" "--help mentions --style"
assert_contains "$out" "--delete-branch" "--help mentions --delete-branch"
teardown

# --- PR# 없음 ---
setup
if "$BIN/gitea-pr-merge" 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "PR# 인자" "error mentions PR#"
teardown

# --- 잘못된 --style은 로그인 확인보다 먼저 거부 ---
setup
no_login_stub
if "$BIN/gitea-pr-merge" 42 --style octopus 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "--style 값 오류" "invalid style rejected before login"
teardown

# --- 정상: squash + --delete-branch, 머지 후 재조회, URL 출력 ---
setup
install_curl_stub
fixture_seq GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR" "$MERGED_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"","total_count":0}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '[]'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
out="$("$BIN/gitea-pr-merge" 42 --style squash --delete-branch 2>"$TEST_TMP/err")"
assert_eq "$out" "https://gitea.test/owner/repo/pulls/42" "PR URL on stdout"
assert_file_contains "$TEST_TMP/err" "머지 완료" "success message"
assert_eq "$(call_count)" "7" "GET pr, GET status, GET workflows x2, GET reviews, POST merge, GET pr"
body="$(nth_call 6 | cut -f3)"
assert_contains "$(nth_call 6)" "POST" "6th call is POST"
assert_contains "$body" '"Do":"squash"' "style propagated"
assert_contains "$body" '"head_commit_id":"abc123"' "head sha pinned"
assert_contains "$body" '"delete_branch_after_merge":true' "delete branch flag"
teardown

# --- 기본값: merge, 브랜치 유지, CI success 통과 ---
setup
install_curl_stub
fixture_seq GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR" "$MERGED_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"success","total_count":2}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '[]'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
"$BIN/gitea-pr-merge" 42 >/dev/null 2>&1
body="$(nth_call 4 | cut -f3)"
assert_contains "$body" '"Do":"merge"' "default style merge"
assert_contains "$body" '"delete_branch_after_merge":false' "branch kept by default"
teardown

# --- 이미 머지됨: URL 출력, 0 종료, POST 없음 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 "$MERGED_PR"
out="$("$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err")"
assert_eq "$out" "https://gitea.test/owner/repo/pulls/42" "URL on already merged"
assert_file_contains "$TEST_TMP/err" "이미 머지됨" "already merged notice"
assert_eq "$(call_count)" "1" "only one GET"
teardown

# --- mergeable=false: 이유 출력, POST 없음 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"state":"open","merged":false,"mergeable":false,"head":{"sha":"abc123"},"html_url":"u42"}'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "mergeable=false" "reason mentions mergeable"
no_merge_post "merge POST called although not mergeable"
teardown

# --- 닫힌 PR ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"state":"closed","merged":false,"mergeable":true,"head":{"sha":"abc123"}}'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "state=closed" "closed PR refused"
no_merge_post "merge POST called on closed PR"
teardown

# --- draft PR ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"state":"open","merged":false,"draft":true,"mergeable":true,"head":{"sha":"abc123"}}'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "draft" "draft PR refused"
no_merge_post "merge POST called on draft PR"
teardown

# --- CI failure ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"failure","total_count":1}'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "failure" "CI failure reported"
no_merge_post "merge POST called with failing CI"
teardown

# --- CI pending: 기다리지 않고 안내 후 종료 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"pending","total_count":1}'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "--wait-ci" "pending suggests gitea-pr-status --wait-ci"
no_merge_post "merge POST called with pending CI"
assert_eq "$(call_count)" "2" "no polling"
teardown

# --- 머지 API 오류 메시지 전달, 재시도 없음 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"","total_count":0}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '[]'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge '{"message":"Please try again later"}'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "Please try again later" "API message propagated"
assert_eq "$(grep -c '/pulls/42/merge' "$CALL_LOG")" "1" "merge POST exactly once"
teardown

# --- 성공 응답 뒤에도 merged=false면 실패 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"","total_count":0}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '[]'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "머지되지 않음" "unconfirmed merge reported"
teardown

# --- 워크플로가 있는데 CI 상태가 0건: push 직후로 보고 머지하지 않는다 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"","total_count":0}'
fixture GET /api/v1/repos/owner/repo/contents/.gitea/workflows '[{"name":"ci.yml","type":"file"}]'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "--ignore-missing-ci" "workflows without status: suggest retry or flag"
no_merge_post "merge POST called before CI registered"
teardown

# --- --ignore-missing-ci: PR에서 돌지 않는 워크플로면 그대로 머지한다 ---
setup
install_curl_stub
fixture_seq GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR" "$MERGED_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"","total_count":0}'
fixture GET /api/v1/repos/owner/repo/contents/.gitea/workflows '[{"name":"release.yml","type":"file"}]'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '[]'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
out="$("$BIN/gitea-pr-merge" 42 --ignore-missing-ci 2>"$TEST_TMP/err")"
assert_eq "$out" "https://gitea.test/owner/repo/pulls/42" "merged with --ignore-missing-ci"
teardown

# --- 리뷰 목록 조회 실패: 확인할 수 없으므로 머지하지 않는다 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"success","total_count":1}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '{"message":"internal error"}'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "리뷰 목록을 조회하지 못함" "review fetch failure blocks merge"
no_merge_post "merge POST called although reviews could not be read"
teardown

# --- 리뷰어의 마지막 리뷰가 변경 요청이면 머지하지 않는다 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"success","total_count":1}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews \
    '[{"user":{"login":"rev"},"state":"APPROVED","submitted_at":"2026-10-01T01:00:00Z"},{"user":{"login":"rev"},"state":"REQUEST_CHANGES","submitted_at":"2026-10-01T02:00:00Z"}]'
if "$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "REQUEST_CHANGES" "outstanding change request blocks merge"
assert_file_contains "$TEST_TMP/err" "rev" "names the reviewer"
no_merge_post "merge POST called with outstanding change request"
teardown

# --- 변경 요청 뒤 같은 리뷰어가 승인했으면 머지한다 ---
setup
install_curl_stub
fixture_seq GET /api/v1/repos/owner/repo/pulls/42 "$OPEN_PR" "$MERGED_PR"
fixture GET /api/v1/repos/owner/repo/commits/abc123/status '{"state":"success","total_count":1}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews \
    '[{"user":{"login":"rev"},"state":"REQUEST_CHANGES","submitted_at":"2026-10-01T01:00:00Z"},{"user":{"login":"rev"},"state":"COMMENT","submitted_at":"2026-10-01T03:00:00Z"},{"user":{"login":"rev"},"state":"APPROVED","submitted_at":"2026-10-01T02:00:00Z"}]'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
out="$("$BIN/gitea-pr-merge" 42 2>"$TEST_TMP/err")"
assert_eq "$out" "https://gitea.test/owner/repo/pulls/42" "merged after later approval"
teardown

echo OK
