#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- 통과 케이스: 정상 제목·브랜치·body → PR 생성 호출 1회 ---
setup
install_curl_stub
# git rev-parse / show-ref / ls-remote 우회: 임시 git repo 안에서 호출
git -C "$TEST_TMP" init -q
cd "$TEST_TMP"
fixture POST /api/v1/repos/owner/repo/pulls \
    '{"number":99,"html_url":"https://gitea.test/owner/repo/pulls/99"}'
out="$("$BIN/gitea-pr" \
    --title 'feat(gitea-ops): 테스트 PR' \
    --head 'feat/gitea-ops-test' \
    --body '## 요약
테스트 PR 본문

## 검증
- ok' \
    --no-trailer 2>"$TEST_TMP/err")"
assert_contains "$out" "https://gitea.test/owner/repo/pulls/99" "PR URL on stdout"
# POST /pulls 정확히 1회 호출
posts="$(grep -c '^POST' "$CALL_LOG" || :)"
assert_eq "$posts" "1" "POST /pulls called once"
cd - >/dev/null
teardown

# --- 실패 케이스: 잘못된 제목 → push/POST 안 함, 비-0 종료 ---
setup
install_curl_stub
git -C "$TEST_TMP" init -q
cd "$TEST_TMP"
rc=0
"$BIN/gitea-pr" \
    --title 'no prefix here' \
    --head 'feat/gitea-ops-test' \
    --body '## 요약
ok

## 검증
- ok' \
    --no-trailer 2>"$TEST_TMP/err" >/dev/null || rc=$?
[ "$rc" != "0" ] || { echo "FAIL: expected non-zero on bad title"; exit 1; }
assert_file_contains "$TEST_TMP/err" "lint failed: title" "lint error emitted"
posts="$(grep '^POST' "$CALL_LOG" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$posts" "0" "POST not called on lint fail"
cd - >/dev/null
teardown

# --- 실패 케이스: 잘못된 브랜치 ---
setup
install_curl_stub
git -C "$TEST_TMP" init -q
cd "$TEST_TMP"
rc=0
"$BIN/gitea-pr" \
    --title 'feat: ok' \
    --head 'Bad_Branch' \
    --body '## 요약
ok

## 검증
- ok' \
    --no-trailer 2>"$TEST_TMP/err" >/dev/null || rc=$?
[ "$rc" != "0" ] || { echo "FAIL: expected non-zero on bad branch"; exit 1; }
assert_file_contains "$TEST_TMP/err" "lint failed: branch" "lint error mentions branch"
cd - >/dev/null
teardown

# --- 실패 케이스: 본문 ## 요약 누락 ---
setup
install_curl_stub
git -C "$TEST_TMP" init -q
cd "$TEST_TMP"
rc=0
"$BIN/gitea-pr" \
    --title 'feat: ok' \
    --head 'feat/x-y' \
    --body '본문만 있고 헤더 없음' \
    --no-trailer 2>"$TEST_TMP/err" >/dev/null || rc=$?
[ "$rc" != "0" ] || { echo "FAIL: expected non-zero on bad body"; exit 1; }
assert_file_contains "$TEST_TMP/err" "## 요약" "lint error mentions missing summary header"
cd - >/dev/null
teardown

# --- --no-lint 우회: 잘못된 제목·브랜치 강행, POST 호출 ---
setup
install_curl_stub
git -C "$TEST_TMP" init -q
cd "$TEST_TMP"
fixture POST /api/v1/repos/owner/repo/pulls \
    '{"number":100,"html_url":"https://gitea.test/owner/repo/pulls/100"}'
out="$("$BIN/gitea-pr" \
    --title 'no prefix' \
    --head 'Bad' \
    --body 'no headers' \
    --no-lint 2>"$TEST_TMP/err")"
assert_contains "$out" "/pulls/100" "PR created despite lint fail under --no-lint"
posts="$(grep -c '^POST' "$CALL_LOG" || :)"
assert_eq "$posts" "1" "POST called under --no-lint"
trailer_in_post="$(grep '^POST' "$CALL_LOG" | grep -c 'Assisted-by: Claude Code' || :)"
assert_eq "$trailer_in_post" "0" "sledgehammer --no-lint also suppresses trailer"
cd - >/dev/null
teardown

# --- --help 출력에 신규 flag 가 노출되는지 (헤더 line range drift 잠금) ---
setup
out="$("$BIN/gitea-pr" --help 2>&1)"
assert_contains "$out" "--no-lint" "--help shows --no-lint flag"
assert_contains "$out" "--no-trailer" "--help shows --no-trailer flag"
teardown

# --- trailer 자동 부착: --no-trailer 미사용 시 body 에 trailer 들어감 ---
setup
install_curl_stub
git -C "$TEST_TMP" init -q
cd "$TEST_TMP"
fixture POST /api/v1/repos/owner/repo/pulls \
    '{"number":101,"html_url":"https://gitea.test/owner/repo/pulls/101"}'
"$BIN/gitea-pr" \
    --title 'feat: ok' \
    --head 'feat/x-y' \
    --body '## 요약
ok

## 검증
- ok' >/dev/null 2>"$TEST_TMP/err"
# CALL_LOG 의 body 필드에 trailer 가 포함돼 있는지 검증
post_line="$(grep '^POST' "$CALL_LOG")"
assert_contains "$post_line" "Assisted-by: Claude Code" "trailer present in POST body"
cd - >/dev/null
teardown

echo OK
