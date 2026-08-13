#!/bin/sh
# 설정 해석과 비밀값 취급. 비밀값이 argv 로 새지 않는 것이 이 스킬의 핵심 성질이다.
. "$(dirname "$0")/lib.sh"

# --- 설정이 없으면 거절한다 ---
setup; trap teardown EXIT
out="$("$BIN/leaf-ls" 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "설정 없으면 실패해야 한다"
assert_contains "$out" "설정이 없습니다" "설정 부재를 알려야 한다"
teardown; trap - EXIT

# --- LEAF_AUTH 형식이 틀리면 거절한다 ---
setup; trap teardown EXIT
printf 'LEAF_URL=https://leaf.test\nLEAF_AUTH=콜론없음\n' >"$HOME/.config/leaf-ops/config"
out="$("$BIN/leaf-ls" 2>&1)" && rc=0 || rc=$?
assert_exit_code "$rc" 1 "형식 오류면 실패해야 한다"
assert_contains "$out" "이름:비밀값" "형식을 알려줘야 한다"
teardown; trap - EXIT

# --- 환경변수가 설정 파일보다 우선한다 ---
setup; trap teardown EXIT
write_default_config
fixture GET / '{"sites":[],"tokens":[]}'
LEAF_AUTH="codex:other" LEAF_URL="https://env.test" "$BIN/leaf-ls" --json >/dev/null
assert_contains "$(nth_call 1)" "https://env.test/" "환경변수의 URL 을 써야 한다"
teardown; trap - EXIT

# --- 비밀값이 argv 에 나타나지 않는다 ---
setup; trap teardown EXIT
write_default_config
fixture GET / '{"sites":[],"tokens":[]}'
"$BIN/leaf-ls" --json >/dev/null
argv="$(cat "$ARGV_LOG")"
assert_not_contains "$argv" "s3cr3t" "비밀값이 curl argv 에 실리면 안 된다"
assert_not_contains "$argv" "claude:s3cr3t" "자격 쌍이 argv 에 실리면 안 된다"
assert_eq "$(cut -f3 "$CALL_LOG")" "yes" "자격은 --netrc-file 로 넘어가야 한다"
teardown; trap - EXIT

# --- netrc 임시 파일은 종료 후 남지 않는다 ---
setup; trap teardown EXIT
write_default_config
fixture GET / '{"sites":[],"tokens":[]}'
before="$(ls /tmp | wc -l)"
"$BIN/leaf-ls" --json >/dev/null
after="$(ls /tmp | wc -l)"
assert_eq "$after" "$before" "임시 netrc 가 남으면 안 된다"
teardown; trap - EXIT

echo "ok $(basename "$0")"
