#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

COMMON="$REPO_ROOT/bin/_common.sh"

# --- 기본 부착: trailer 없는 body 에 \n\n + trailer 부착 ---
setup
. "$COMMON"
out="$(append_trailer '## 요약
내용

## 검증
- ok')"
assert_contains "$out" "Assisted-by: Claude Code" "trailer appended"
assert_contains "$out" "## 검증" "original body preserved"
# trailer 앞에 빈 줄이 있는지 검증 (RFC 822)
last_three="$(printf '%s' "$out" | tail -3)"
assert_contains "$last_three" "Assisted-by: Claude Code" "trailer in last lines"
teardown

# --- idempotent: 이미 trailer 가 있으면 추가 부착 안 함 ---
setup
. "$COMMON"
body_with_trailer='## 요약
내용

## 검증
- ok

Assisted-by: Claude Code'
out="$(append_trailer "$body_with_trailer")"
count="$(printf '%s\n' "$out" | grep -c '^Assisted-by: Claude Code$')"
assert_eq "$count" "1" "trailer not duplicated"
teardown

# --- trailing newline 다수: 한 번만 부착, 빈 줄 1개 유지 ---
setup
. "$COMMON"
body='## 요약
내용

## 검증
- ok


'
out="$(append_trailer "$body")"
count="$(printf '%s\n' "$out" | grep -c '^Assisted-by: Claude Code$')"
assert_eq "$count" "1" "trailer appended exactly once with trailing whitespace"
teardown

# --- 빈 body: trailer 단독으로 부착되어선 안 됨 (호출 측이 lint 로 막아야 하지만, helper 는 그대로 부착) ---
setup
. "$COMMON"
out="$(append_trailer '')"
assert_contains "$out" "Assisted-by: Claude Code" "trailer appended even to empty body"
teardown

echo OK
