#!/bin/sh
# leaf-put: URL 조립, 헤더, 디렉토리 순회, 입력 검증.
. "$(dirname "$0")/lib.sh"

# --- 파일 하나: 경로를 생략하면 index.html 로 올라가고 디렉토리 URL 을 찍는다 ---
setup; trap teardown EXIT
write_default_config
printf 'x' >"$TEST_TMP/r.html"
out="$("$BIN/leaf-put" "$TEST_TMP/r.html" my-site)"
assert_eq "$(call_count)" 1 "요청은 한 번"
assert_contains "$(nth_call 1)" "https://leaf.test/my-site/index.html" "index.html 로 올려야 한다"
assert_eq "$out" "https://leaf.test/my-site/" "디렉토리 URL 을 찍어야 한다"
teardown; trap - EXIT

# --- 파일 하나: 경로를 주면 그 경로 URL 을 찍는다 ---
setup; trap teardown EXIT
write_default_config
printf 'x' >"$TEST_TMP/c.svg"
out="$("$BIN/leaf-put" "$TEST_TMP/c.svg" my-site/chart.svg)"
assert_contains "$(nth_call 1)" "https://leaf.test/my-site/chart.svg" "준 경로로 올려야 한다"
assert_eq "$out" "https://leaf.test/my-site/chart.svg" "파일 URL 을 찍어야 한다"
teardown; trap - EXIT

# --- 옵션이 헤더로 나간다 ---
setup; trap teardown EXIT
write_default_config
printf 'x' >"$TEST_TMP/r.html"
"$BIN/leaf-put" "$TEST_TMP/r.html" my-site --public --keep >/dev/null
line="$(nth_call 1)"
assert_contains "$line" "X-Leaf-Public: true" "--public 이 헤더로 나가야 한다"
assert_contains "$line" "X-Leaf-Keep: true" "--keep 이 헤더로 나가야 한다"
teardown; trap - EXIT

# --- 옵션이 없으면 헤더도 없다 (서버가 기존 설정을 유지하도록) ---
setup; trap teardown EXIT
write_default_config
printf 'x' >"$TEST_TMP/r.html"
"$BIN/leaf-put" "$TEST_TMP/r.html" my-site >/dev/null
assert_not_contains "$(nth_call 1)" "X-Leaf-" "옵션 없으면 헤더를 보내면 안 된다"
teardown; trap - EXIT

# --- 디렉토리: 상대 경로를 유지하고, 헤더는 첫 파일에만 붙인다 ---
setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/site/assets"
printf 'x' >"$TEST_TMP/site/index.html"
printf 'y' >"$TEST_TMP/site/assets/s.css"
out="$("$BIN/leaf-put" "$TEST_TMP/site" doc --public 2>/dev/null)"
assert_eq "$(call_count)" 2 "파일 수만큼 요청"
urls="$(call_urls)"
assert_contains "$urls" "https://leaf.test/doc/index.html" "루트 파일"
assert_contains "$urls" "https://leaf.test/doc/assets/s.css" "하위 디렉토리 상대 경로 유지"
assert_eq "$out" "https://leaf.test/doc/" "디렉토리 URL 을 찍어야 한다"
assert_contains "$(nth_call 1)" "X-Leaf-Public" "첫 파일에는 헤더가 붙는다"
assert_not_contains "$(nth_call 2)" "X-Leaf-Public" "사이트 단위 설정이라 두 번째부터는 안 붙인다"
teardown; trap - EXIT

# --- 디렉토리 안 하위 경로로 올리기 ---
setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/s"; printf 'x' >"$TEST_TMP/s/a.html"
"$BIN/leaf-put" "$TEST_TMP/s" doc/sub >/dev/null 2>&1
assert_contains "$(nth_call 1)" "https://leaf.test/doc/sub/a.html" "하위 경로 아래로 올려야 한다"
teardown; trap - EXIT

# --- 입력 검증: 서버에 가기 전에 막는다 ---
setup; trap teardown EXIT
write_default_config
printf 'x' >"$TEST_TMP/r.html"
for bad in Upper _token 'a!b'; do
    out="$("$BIN/leaf-put" "$TEST_TMP/r.html" "$bad" 2>&1)" && rc=0 || rc=$?
    assert_exit_code "$rc" 1 "잘못된 사이트 이름 '$bad' 은 거절해야 한다"
    assert_contains "$out" "사이트 이름" "무엇이 틀렸는지 알려야 한다"
done
assert_eq "$(call_count)" 0 "검증 실패면 요청을 보내면 안 된다"
teardown; trap - EXIT

# --- 경로에 못 쓰는 문자 ---
setup; trap teardown EXIT
write_default_config
printf 'x' >"$TEST_TMP/r.html"
out="$("$BIN/leaf-put" "$TEST_TMP/r.html" 'site/한글.html' 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "비ASCII 경로는 거절해야 한다"
assert_eq "$(call_count)" 0 "요청을 보내면 안 된다"
teardown; trap - EXIT

# --- 없는 파일 ---
setup; trap teardown EXIT
write_default_config
out="$("$BIN/leaf-put" /없는파일 site 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "없는 파일은 거절해야 한다"
assert_contains "$out" "없는 경로" "이유를 알려야 한다"
teardown; trap - EXIT

echo "ok $(basename "$0")"
