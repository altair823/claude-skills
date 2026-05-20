#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

LINT="$REPO_ROOT/bin/_lint.sh"

# --- lint_pr_title: 통과 케이스 ---
setup
. "$LINT"
lint_pr_title 'feat(homelab-ops): 위젯 추가' || { echo "FAIL: feat(scope)"; exit 1; }
lint_pr_title 'fix: cross-cutting readme' || { echo "FAIL: fix no-scope"; exit 1; }
lint_pr_title 'docs(harbor-ops): 가이드 갱신' || { echo "FAIL: docs(scope)"; exit 1; }
teardown

# --- lint_pr_title: 실패 케이스 ---
setup
. "$LINT"
out="$(lint_pr_title '' 2>&1)" && { echo "FAIL: empty title accepted"; exit 1; } || :
assert_contains "$out" "lint failed: title" "empty title produces lint failure msg"
lint_pr_title 'feat(HomeLab): X' 2>/dev/null && { echo "FAIL: uppercase scope accepted"; exit 1; } || :
lint_pr_title 'build(x): X' 2>/dev/null && { echo "FAIL: disallowed type accepted"; exit 1; } || :
lint_pr_title 'feat X' 2>/dev/null && { echo "FAIL: missing colon accepted"; exit 1; } || :
lint_pr_title 'feat(x):X' 2>/dev/null && { echo "FAIL: missing space after colon accepted"; exit 1; } || :
lint_pr_title 'feat: ' 2>/dev/null && { echo "FAIL: empty subject accepted"; exit 1; } || :
teardown

# --- lint_branch_name: 통과 케이스 ---
setup
. "$LINT"
lint_branch_name 'feat/homelab-ops-exec-and-curated-verbs' || { echo "FAIL: scope-in-topic"; exit 1; }
lint_branch_name 'fix/gitea-ops-pdm-auth-scheme' || { echo "FAIL: fix"; exit 1; }
lint_branch_name 'docs/cross-cutting-readme' || { echo "FAIL: no-scope"; exit 1; }
teardown

# --- lint_branch_name: 실패 케이스 ---
setup
. "$LINT"
lint_branch_name 'feat-widget' 2>/dev/null && { echo "FAIL: missing slash accepted"; exit 1; } || :
lint_branch_name 'feat/Widget' 2>/dev/null && { echo "FAIL: uppercase accepted"; exit 1; } || :
lint_branch_name 'feat/widget-' 2>/dev/null && { echo "FAIL: trailing hyphen accepted"; exit 1; } || :
lint_branch_name 'refs/pull/30/head' 2>/dev/null && { echo "FAIL: auto-ref accepted"; exit 1; } || :
lint_branch_name '' 2>/dev/null && { echo "FAIL: empty accepted"; exit 1; } || :
teardown

# --- lint_pr_body: 통과 케이스 ---
setup
. "$LINT"
body_ok='## 요약
내용 있음

## 검증
- 테스트 녹색'
lint_pr_body "$body_ok" || { echo "FAIL: minimal body"; exit 1; }

body_with_cat='## 요약
내용 있음

## 카테고리 A
- bullet

## 검증
- ok'
lint_pr_body "$body_with_cat" || { echo "FAIL: body with category"; exit 1; }
teardown

# --- lint_pr_body: 실패 케이스 ---
setup
. "$LINT"
out="$(lint_pr_body '' 2>&1)" && { echo "FAIL: empty body accepted"; exit 1; } || :
assert_contains "$out" "## 요약" "empty body mentions missing summary header"

no_summary='## 검증
- ok'
lint_pr_body "$no_summary" 2>/dev/null && { echo "FAIL: missing summary accepted"; exit 1; } || :

no_validate='## 요약
내용'
lint_pr_body "$no_validate" 2>/dev/null && { echo "FAIL: missing validate accepted"; exit 1; } || :

empty_summary='## 요약


## 검증
- ok'
out="$(lint_pr_body "$empty_summary" 2>&1)" && { echo "FAIL: empty summary section accepted"; exit 1; } || :
assert_contains "$out" "empty" "empty summary mentions emptiness"

whitespace_only_summary='## 요약
   
	
## 검증
- ok'
lint_pr_body "$whitespace_only_summary" 2>/dev/null && { echo "FAIL: whitespace-only summary accepted"; exit 1; } || :
teardown

# --- lint_pr_all: 세 항목 모두 통과 → exit 0, 무출력 ---
setup
. "$LINT"
good_body='## 요약
내용

## 검증
- ok'
out="$(lint_pr_all 'feat(x): y' 'feat/x-y' "$good_body" 2>&1)"
assert_eq "$out" "" "lint_pr_all all-pass produces no output"
lint_pr_all 'feat(x): y' 'feat/x-y' "$good_body" || { echo "FAIL: all-pass exit"; exit 1; }
teardown

# --- lint_pr_all: 한 항목만 실패 → 정확히 한 줄 출력, exit 2 ---
setup
. "$LINT"
good_body='## 요약
내용

## 검증
- ok'
out="$(lint_pr_all 'BAD' 'feat/x-y' "$good_body" 2>&1)" && { echo "FAIL: expected non-zero"; exit 1; } || :
lines="$(printf '%s\n' "$out" | grep -c 'lint failed:' || :)"
assert_eq "$lines" "1" "one failure produces one line"
teardown

# --- lint_pr_all: 세 항목 모두 실패 → 세 줄, exit 2 ---
setup
. "$LINT"
out="$(lint_pr_all 'BAD' 'BAD' '' 2>&1)" && { echo "FAIL: expected non-zero"; exit 1; } || :
lines="$(printf '%s\n' "$out" | grep -c 'lint failed:' || :)"
assert_eq "$lines" "3" "three failures produce three lines"
teardown

echo OK
