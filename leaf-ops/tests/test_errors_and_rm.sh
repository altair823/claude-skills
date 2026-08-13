#!/bin/sh
# HTTP 오류 매핑과 leaf-rm / leaf-ls 동작.
. "$(dirname "$0")/lib.sh"

# --- 업로드 오류 코드가 사람 말로 바뀐다 ---
setup; trap teardown EXIT
write_default_config
printf 'x' >"$TEST_TMP/r.html"
fixture_code PUT /site/index.html 401
out="$("$BIN/leaf-put" "$TEST_TMP/r.html" site 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "401 이면 실패해야 한다"
assert_contains "$out" "인증 실패" "401 을 인증 실패로 알려야 한다"
teardown; trap - EXIT

setup; trap teardown EXIT
write_default_config
printf 'x' >"$TEST_TMP/r.html"
fixture_code PUT /site/index.html 413
out="$("$BIN/leaf-put" "$TEST_TMP/r.html" site 2>&1)" && rc=0 || rc=$?
assert_contains "$out" "32MB" "413 은 크기 상한을 알려야 한다"
teardown; trap - EXIT

# --- 디렉토리 업로드 중간에 실패하면 멈춘다 ---
setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/s"
printf 'x' >"$TEST_TMP/s/a.html"; printf 'y' >"$TEST_TMP/s/b.html"
fixture_code PUT /doc/a.html 500
out="$("$BIN/leaf-put" "$TEST_TMP/s" doc 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "실패하면 종료해야 한다"
assert_eq "$(call_count)" 1 "실패 후 나머지를 계속 올리면 안 된다"
teardown; trap - EXIT

# --- leaf-ls: JSON 을 그대로 준다 ---
setup; trap teardown EXIT
write_default_config
fixture GET / '{"sites":[{"site":"a","owner":"claude","public":false,"keep":false,"expires_in_days":30}],"tokens":[{"name":"claude"}]}'
out="$("$BIN/leaf-ls" --json)"
assert_contains "$out" '"site":"a"' "JSON 을 그대로 내보내야 한다"
teardown; trap - EXIT

# --- leaf-ls: 401 을 사람 말로 ---
setup; trap teardown EXIT
write_default_config
fixture_code GET / 401
out="$("$BIN/leaf-ls" 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "401 이면 실패해야 한다"
assert_contains "$out" "인증 실패" "이유를 알려야 한다"
teardown; trap - EXIT

# --- leaf-rm: DELETE 를 보내고 응답을 그대로 전한다 ---
setup; trap teardown EXIT
write_default_config
fixture DELETE /site 'site 삭제됨
'
out="$("$BIN/leaf-rm" site --yes)"
assert_contains "$(nth_call 1)" "DELETE" "DELETE 여야 한다"
assert_contains "$(nth_call 1)" "https://leaf.test/site" "사이트 URL 이어야 한다"
assert_contains "$out" "삭제됨" "서버 응답을 전해야 한다"
teardown; trap - EXIT

# --- leaf-rm: 404 ---
setup; trap teardown EXIT
write_default_config
fixture_code DELETE /nosuch 404
out="$("$BIN/leaf-rm" nosuch --yes 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "404 면 실패해야 한다"
assert_contains "$out" "없는 사이트" "이유를 알려야 한다"
teardown; trap - EXIT

# --- leaf-rm: 잘못된 이름은 요청 전에 막는다 ---
setup; trap teardown EXIT
write_default_config
out="$("$BIN/leaf-rm" _token --yes 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "예약어는 거절해야 한다"
assert_eq "$(call_count)" 0 "요청을 보내면 안 된다"
teardown; trap - EXIT

echo "ok $(basename "$0")"
