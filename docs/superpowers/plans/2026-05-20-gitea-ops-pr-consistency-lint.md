# gitea-ops PR 일관성 lint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> 본 plan 의 step checkbox 는 write-once artifact — 진행 추적은 git log 와 task list 로 대체. 머지 후 retroactive check 안 함.

**Goal:** PR 제목·브랜치·본문 골격을 정규식·헤더 검증으로 자동화하고 `Assisted-by: Claude Code` trailer 부착을 통일해 신규 PR의 일관성 흔들림을 구조적으로 차단한다.

**Architecture:** 신규 `bin/_lint.sh` 가 stateless 검증 3 종을 제공. trailer 헬퍼는 `bin/_common.sh` 에 추가. `gitea-pr` 가 PR 생성 *전* lint + trailer 부착, `gitea-pr-status` 가 PR 생성 *후* 동일 lint 를 entry-gate 에 통합. SKILL.md `## 작성 규칙` 절을 단일 진실 출처로 확장. Forward-only — 기존 머지된 PR 은 손대지 않는다.

**Tech Stack:** POSIX shell (`set -eu`), `awk`, `grep -E`, `jq`. 기존 `tea` CLI 의존성 그대로. 테스트는 기존 `tests/lib.sh` + 직접 호출 패턴 (`bash tests/test_*.sh`).

**Spec:** [docs/superpowers/specs/2026-05-20-gitea-ops-pr-consistency-lint-design.md](../specs/2026-05-20-gitea-ops-pr-consistency-lint-design.md)

---

## File Structure

| 경로 | 책임 | 변경 종류 |
|------|------|-----------|
| `gitea-ops/bin/_lint.sh` | 검증 3 종 + 통합 진단 (pure 모듈) | Create |
| `gitea-ops/bin/_common.sh` | `append_trailer` 헬퍼 추가 | Modify |
| `gitea-ops/bin/gitea-pr` | lint + trailer 통합, `--no-lint`/`--no-trailer` flag | Modify |
| `gitea-ops/bin/gitea-pr-status` | entry-gate 에 lint 3 항목 통합 | Modify |
| `gitea-ops/tests/test_lint.sh` | `_lint.sh` 단위 테스트 | Create |
| `gitea-ops/tests/test_trailer.sh` | `append_trailer` 단위 테스트 | Create |
| `gitea-ops/tests/test_gitea_pr.sh` | `gitea-pr` lint 통합 회귀 | Create |
| `gitea-ops/tests/test_gitea_pr_status.sh` | lint 출력 키 + gate 분기 확장 | Modify |
| `gitea-ops/SKILL.md` | 작성 규칙 절 확장 + 시그니처 갱신 + Entry-gate 절 갱신 | Modify |

기존 7 테스트 파일은 회귀 잠금으로 유지. 단, `test_gitea_pr_status.sh` 의 fixture 중 새 lint 정규식을 통과하지 않는 것들은 Task 5 에서 함께 갱신.

---

## Task 1: `_lint.sh` 모듈 + 단위 테스트

**Files:**
- Create: `gitea-ops/bin/_lint.sh`
- Create: `gitea-ops/tests/test_lint.sh`

이 task 끝까지는 `_lint.sh` 를 부르는 곳이 없다 — pure 모듈만 추가. 회귀 0.

- [ ] **Step 1: Write failing test `tests/test_lint.sh`**

```sh
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
```

- [ ] **Step 2: Run test, verify it fails**

```
bash gitea-ops/tests/test_lint.sh
```

Expected: FAIL (no such file `_lint.sh`, sourcing dies).

- [ ] **Step 3: Implement `bin/_lint.sh`**

```sh
#!/bin/sh
# PR 일관성 lint. Stateless·side-effect 없는 pure 모듈.
# 호출자: gitea-pr (생성 전), gitea-pr-status (entry-gate).
# 의존성 없음 (jq, tea 등 source 안 함).

# 정규식 상수. extended POSIX regex (`grep -E`) 호환.
_LINT_TITLE_RE='^(feat|fix|docs|refactor|chore|test)(\([a-z0-9-]+\))?: .+'
_LINT_BRANCH_RE='^(feat|fix|docs|refactor|chore|test)/[a-z0-9]+(-[a-z0-9]+)*$'

lint_pr_title() {
    title="$1"
    if printf '%s' "$title" | grep -qE "$_LINT_TITLE_RE"; then
        return 0
    fi
    printf 'lint failed: title does not match %s\n' "$_LINT_TITLE_RE"
    return 2
}

lint_branch_name() {
    branch="$1"
    if printf '%s' "$branch" | grep -qE "$_LINT_BRANCH_RE"; then
        return 0
    fi
    printf 'lint failed: branch does not match %s\n' "$_LINT_BRANCH_RE"
    return 2
}

# `## 요약` / `## 검증` 헤더 + `## 요약` 절 본문이 whitespace·newline 제거 후 1자 이상.
lint_pr_body() {
    body="$1"
    result="$(printf '%s' "$body" | awk '
        /^## 요약$/ { has_summary=1; in_summary=1; next }
        /^## 검증$/ { has_validate=1; in_summary=0; next }
        /^## / { in_summary=0 }
        in_summary {
            line=$0
            gsub(/[ \t]/, "", line)
            if (length(line) > 0) summary_content=1
        }
        END {
            if (!has_summary)       print "missing_summary"
            else if (!has_validate) print "missing_validate"
            else if (!summary_content) print "empty_summary"
            else print "ok"
        }
    ')"
    case "$result" in
        ok) return 0 ;;
        missing_summary)  printf 'lint failed: body missing required header %s\n' '## 요약'; return 2 ;;
        missing_validate) printf 'lint failed: body missing required header %s\n' '## 검증'; return 2 ;;
        empty_summary)    printf 'lint failed: %s section is empty (whitespace-only)\n' '## 요약'; return 2 ;;
    esac
}

lint_pr_all() {
    title="$1"; branch="$2"; body="$3"
    rc=0
    lint_pr_title "$title"     || rc=2
    lint_branch_name "$branch" || rc=2
    lint_pr_body "$body"       || rc=2
    return $rc
}
```

- [ ] **Step 4: Run test, verify it passes**

```
bash gitea-ops/tests/test_lint.sh
```

Expected: `OK` on stdout, exit 0.

- [ ] **Step 5: Commit**

```
git add gitea-ops/bin/_lint.sh gitea-ops/tests/test_lint.sh
git commit -m "feat(gitea-ops): _lint.sh 모듈 + 단위 테스트 추가

PR 제목/브랜치/본문 검증 3종 + 통합 진단 함수. Stateless·의존성 0.
호출자는 아직 없음 (다음 task에서 gitea-pr/gitea-pr-status 통합)."
```

---

## Task 2: `append_trailer` 헬퍼 + 단위 테스트

**Files:**
- Modify: `gitea-ops/bin/_common.sh` (helper 추가)
- Create: `gitea-ops/tests/test_trailer.sh`

- [ ] **Step 1: Write failing test `tests/test_trailer.sh`**

```sh
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
```

- [ ] **Step 2: Run test, verify it fails**

```
bash gitea-ops/tests/test_trailer.sh
```

Expected: FAIL — `append_trailer: command not found` (helper 부재).

- [ ] **Step 3: Add helper to `bin/_common.sh`**

Append the following function at the end of `bin/_common.sh`, after the existing helpers and before the trailing EOF (if any). 위치는 `die()` 정의 이후, 파일 끝:

```sh
# PR body 끝에 `Assisted-by: Claude Code` trailer 를 idempotent 하게 부착.
# 본문에 이미 동일 trailer 가 한 줄로 존재하면 그대로 반환.
append_trailer() {
    _body="$1"
    _trailer='Assisted-by: Claude Code'
    if printf '%s\n' "$_body" | grep -qFx "$_trailer"; then
        printf '%s' "$_body"
        return 0
    fi
    # body 끝 trailing whitespace·newline 제거 후, 빈 줄 1개 + trailer.
    _trimmed="$(printf '%s' "$_body" | awk '
        { lines[NR] = $0 }
        END {
            n = NR
            while (n > 0 && lines[n] ~ /^[ \t]*$/) n--
            for (i = 1; i <= n; i++) printf "%s%s", lines[i], (i < n ? "\n" : "")
        }
    ')"
    printf '%s\n\n%s' "$_trimmed" "$_trailer"
}
```

- [ ] **Step 4: Run test, verify it passes**

```
bash gitea-ops/tests/test_trailer.sh
```

Expected: `OK`.

- [ ] **Step 5: Verify other tests still pass (회귀 잠금)**

```
for f in gitea-ops/tests/test_*.sh; do bash "$f" >/dev/null && echo "OK: $f" || { echo "FAIL: $f"; exit 1; }; done
```

Expected: 모든 파일 `OK:`. `_common.sh` 에 함수 추가만 했으므로 기존 호출자 영향 없음.

- [ ] **Step 6: Commit**

```
git add gitea-ops/bin/_common.sh gitea-ops/tests/test_trailer.sh
git commit -m "feat(gitea-ops): append_trailer 헬퍼 + 단위 테스트

PR body 에 'Assisted-by: Claude Code' trailer 를 idempotent 부착.
RFC 822 스타일 (앞 빈 줄 1개). 호출자는 다음 task에서 통합."
```

---

## Task 3: `gitea-pr` 통합 + 회귀 테스트

**Files:**
- Modify: `gitea-ops/bin/gitea-pr` (lint + trailer 통합, flag 2개 추가)
- Create: `gitea-ops/tests/test_gitea_pr.sh`

- [ ] **Step 1: Write failing test `tests/test_gitea_pr.sh`**

```sh
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
posts="$(grep -c '^POST' "$CALL_LOG" 2>/dev/null || echo 0)"
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
cd - >/dev/null
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
```

- [ ] **Step 2: Run test, verify it fails**

```
bash gitea-ops/tests/test_gitea_pr.sh
```

Expected: FAIL — `--no-lint` 등 flag 없거나, lint 호출이 없어 잘못된 제목으로 POST가 일어남.

- [ ] **Step 3: Integrate lint + trailer into `bin/gitea-pr`**

전체 파일을 다음 내용으로 교체:

```sh
#!/bin/sh
# Gitea에 pull request를 생성한다.
#
# Usage:
#   gitea-pr --title "..." --body "..." --head BRANCH [--base main]
#            [--draft] [--assignee USER]... [--label LABEL]...
#            [--no-lint] [--no-trailer]
#            [-r owner/repo] [-u URL]
#
# PR 생성 전 _lint.sh 의 제목/브랜치/본문 lint 가 실패하면 push·생성을
# 모두 거부 (--no-lint 로 우회 — 사람이 직접 강제 작성할 때).
# body 끝에 `Assisted-by: Claude Code` trailer 자동 부착 (--no-trailer 로 끔).

set -eu
. "$(dirname "$0")/_common.sh"
. "$(dirname "$0")/_lint.sh"

TITLE=""
BODY=""
HEAD=""
BASE="main"
DRAFT="false"
ASSIGNEES_JSON="[]"
LABELS_JSON="[]"
NO_LINT=0
NO_TRAILER=0

append_json_array() { echo "$1" | jq --arg v "$2" '. + [$v]' ; }

while [ $# -gt 0 ]; do
    case "$1" in
        --title) TITLE="$2"; shift 2 ;;
        --body)  BODY="$2"; shift 2 ;;
        --head)  HEAD="$2"; shift 2 ;;
        --base)  BASE="$2"; shift 2 ;;
        --draft) DRAFT="true"; shift ;;
        --assignee)
            ASSIGNEES_JSON="$(append_json_array "$ASSIGNEES_JSON" "$2")"; shift 2 ;;
        --label)
            LABELS_JSON="$(append_json_array "$LABELS_JSON" "$2")"; shift 2 ;;
        --no-lint)    NO_LINT=1; NO_TRAILER=1; shift ;;
        --no-trailer) NO_TRAILER=1; shift ;;
        -r|--repo) GITEA_REPO="$2"; export GITEA_REPO; shift 2 ;;
        -u|--url)  GITEA_URL="$2"; export GITEA_URL; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) die "알 수 없는 인자: $1" ;;
    esac
done

[ -n "$TITLE" ] || die "--title 인자 필요"
[ -n "$HEAD" ]  || die "--head 인자 필요"

# Trailer 자동 부착 (lint 전에 — 부착된 본문이 lint 대상).
if [ "$NO_TRAILER" = "0" ]; then
    BODY="$(append_trailer "$BODY")"
fi

# Lint (PR 생성 전, push 전).
if [ "$NO_LINT" = "0" ]; then
    if ! lint_out="$(lint_pr_all "$TITLE" "$HEAD" "$BODY" 2>&1)"; then
        printf '%s\n' "$lint_out" >&2
        die "lint 실패 — PR 생성 거부. --no-lint 로 우회 가능 (sledgehammer)."
    fi
fi

require_author_login

# Push head branch if local-only — tea pulls/api won't do this for us.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git show-ref --verify --quiet "refs/heads/$HEAD"; then
        if ! git ls-remote --heads origin "$HEAD" | grep -q "$HEAD"; then
            printf '[gitea-pr] branch push: %s\n' "$HEAD" >&2
            git push -u origin "$HEAD"
        fi
    fi
fi

body_json="$(jq -n \
    --arg title "$TITLE" \
    --arg body "$BODY" \
    --arg head "$HEAD" \
    --arg base "$BASE" \
    --argjson draft "$DRAFT" \
    --argjson assignees "$ASSIGNEES_JSON" \
    --argjson labels "$LABELS_JSON" \
    '{title:$title, body:$body, head:$head, base:$base, draft:$draft, assignees:$assignees, labels:$labels}')"

resp="$(printf '%s' "$body_json" | tea_api_json POST "/repos/{owner}/{repo}/pulls")"

num="$(printf '%s' "$resp" | jq -r '.number // empty')"
url="$(printf '%s' "$resp" | jq -r '.html_url // empty')"
if [ -z "$num" ]; then
    printf '[gitea-pr] PR 작성 실패:\n%s\n' "$resp" >&2
    exit 1
fi
printf '[gitea-pr] #%s 작성 완료: %s\n' "$num" "$url" >&2
printf '%s\n' "$url"
```

설계 결정 (load-bearing):
- `--no-lint` 이 `--no-trailer` 도 함께 끄는 sledgehammer (spec: "검증 3종 + trailer 자동 부착 모두 끔").
- trailer 부착이 lint 보다 먼저 — 부착된 본문이 lint 대상. trailer 가 body 끝에 추가되어 본문 구조 검증에 영향을 주진 않지만 (헤더 검증만 함), 일관된 입력이 lint 로 들어가는 게 안전.

- [ ] **Step 4: Run test, verify it passes**

```
bash gitea-ops/tests/test_gitea_pr.sh
```

Expected: `OK`.

- [ ] **Step 5: Verify other tests still pass (회귀 잠금)**

```
for f in gitea-ops/tests/test_*.sh; do bash "$f" >/dev/null && echo "OK: $f" || { echo "FAIL: $f"; exit 1; }; done
```

Expected: 모든 파일 `OK:`. `gitea-pr-status` 통합은 다음 task — 이 단계까지는 기존 fixture 모두 통과해야 함.

- [ ] **Step 6: Commit**

```
git add gitea-ops/bin/gitea-pr gitea-ops/tests/test_gitea_pr.sh
git commit -m "feat(gitea-ops): gitea-pr 가 lint + trailer 자동 통합

PR 생성 전 _lint.sh 호출, 실패 시 push/POST 모두 거부.
body 끝에 Assisted-by: Claude Code trailer 자동 부착.
--no-lint (sledgehammer) / --no-trailer 우회 flag 추가."
```

---

## Task 4: SKILL.md 갱신

**Files:**
- Modify: `gitea-ops/SKILL.md`

코드 변경 없음. 문서가 코드와 동기화되도록 한 번에 묶어 갱신. 다음 task (`gitea-pr-status` 통합) 가 entry-gate 절을 추가 변경하지만, SKILL.md 갱신을 그 사이에 끼워 넣어 review-friendly 단위로 분리한다.

- [ ] **Step 1: SKILL.md `## 작성 규칙` 절 확장**

기존 `## 작성 규칙` 절을 다음으로 교체 (기존 bullet은 유지하면서 4개 항목 추가/강화):

기존 `**commit 메시지 / PR title**` bullet 을 다음으로 교체:

```
- **PR title / commit 메시지**: Conventional Commits. PR title 정규식 강제 (entry-gate / `gitea-pr` lint):
  ```
  ^(feat|fix|docs|refactor|chore|test)(\([a-z0-9-]+\))?: .+
  ```
  scope 는 lowercase + 숫자 + 하이픈 (보통 스킬 이름). scope 생략 (`feat: ...`) 은 **cross-cutting 변경에 한해** 허용 — 단일 스킬만 영향이면 scope 명시 필수. 영문 prefix + 한국어 본문 OK. commit 메시지는 lint 안 함 (가이드라인만) — 회차 반영 커밋은 `chore(scope): PR #N 회차 K 리뷰 반영` 형식 권고.
```

추가 bullet (`commit 메시지 / PR title` 이후):

```
- **브랜치 이름**: `<type>/<topic-kebab>` 패턴 강제 (entry-gate / `gitea-pr` lint). 정규식:
  ```
  ^(feat|fix|docs|refactor|chore|test)/[a-z0-9]+(-[a-z0-9]+)*$
  ```
  scope 는 topic 안에 kebab 으로 들어감 (`feat/homelab-ops-exec-and-curated-verbs`). scope 생략 시 `docs/cross-cutting-readme` 같이 type+topic 만. PR title 의 scope 유무와 브랜치의 scope-in-topic 일치 여부는 lint 가 검증 안 함 — 사용자 책임.

- **PR 본문 골격**: 필수 헤더 `## 요약` + `## 검증` (정확히 이 문자열). `## 요약` 헤더 뒤에는 비어있지 않은 본문이 1자 이상 (whitespace·개행 제거 후). 권장 헤더 4종:
  - `설계: docs/superpowers/specs/...` / `계획: docs/superpowers/plans/...` 줄 — `## 요약` 절 직후
  - `## 시험 항목 (Test Plan)` — feature PR 체크박스
  - `## 비범위` 또는 `## 변경 없음` — 회귀 위험 PR
  - `## 카테고리` (자유 명명) — 변경량 많을 때 분할

  표준 골격 (PR #30 스타일):
  ```markdown
  ## 요약
  <수준·동기·핵심 설계 1–2 문단>

  설계: docs/superpowers/specs/...
  계획: docs/superpowers/plans/...

  ## <카테고리 A>
  - ...

  ## 검증
  - 전체 테스트 녹색
  - ...

  ## 시험 항목 (Test Plan)
  - [ ] ...
  ```

- **Trailer**: PR body 마지막 빈 줄 다음에 `Assisted-by: Claude Code` 한 줄 (RFC 822 git trailer 스타일). `gitea-pr` 가 자동 부착·idempotent. `--no-trailer` 로 끌 수 있음 (사람이 직접 PR 만들 때). 옛 `🤖 Generated with [Claude Code](...)` 푸터는 신규 PR 에서 금지 — lint 가 *제거*하진 않으나 (작성자가 직접 본문에 남기면 통과) 가이드라인으로 비권장.
```

기존 다른 bullet (caveman 미적용, PR review 적극성, 리뷰·코멘트 영속성, 리뷰 의견 반영 default) 은 그대로 유지.

- [ ] **Step 2: `### gitea-pr` script 시그니처 갱신**

기존 시그니처:

```
gitea-pr --title "..." --body "..." --head BRANCH [--base main]
         [--draft] [--assignee USER]... [--label LABEL]...
         [-r owner/repo] [-u URL]
```

다음으로 교체:

```
gitea-pr --title "..." --body "..." --head BRANCH [--base main]
         [--draft] [--assignee USER]... [--label LABEL]...
         [--no-lint] [--no-trailer]
         [-r owner/repo] [-u URL]
```

기존 설명 단락 끝에 다음 한 줄 추가:

```
PR 생성 전 `_lint.sh` 의 제목/브랜치/본문 lint 가 실패하면 push·생성을 모두 거부. `--no-lint` 로 우회 가능 (sledgehammer — `--no-trailer` 도 함께 적용). `Assisted-by: Claude Code` trailer 가 body 끝에 자동 부착되며 `--no-trailer` 로 끄거나 이미 본문에 있으면 중복 부착 안 함 (idempotent).
```

- [ ] **Step 3: `## 에러 처리` 절에 lint 케이스 추가**

기존 `## 에러 처리` bullet 목록 끝에 다음 두 항목 추가:

```
- `lint failed: title does not match ^(feat|fix|...)...` → PR title 이 정규식 통과하지 않음. `feat(scope): ...` 형태로 수정. cross-cutting 이면 scope 생략 OK.
- `lint failed: branch does not match ^(feat|fix|...)/...` → 브랜치 이름이 정규식 통과하지 않음. `git branch -m new-name` 으로 재명명 후 다시 push.
- `lint failed: body missing required header '## 요약'` → PR body 가 표준 골격 미준수. `## 요약` / `## 검증` 헤더 추가, `## 요약` 절 본문 1자 이상.
```

- [ ] **Step 4: 옛 예시 교체**

`SKILL.md` 전체에서 옛 짧은 브랜치 예시 (`feat/widget` 등) 와 PR title 예시 (스코프 없는 `feat:`) 가 있다면 새 컨벤션 예시로 교체. 다음 명령으로 확인:

```
grep -nE 'feat/widget|feat: |gitea-pr --title "위젯' gitea-ops/SKILL.md
```

검색 결과를 새 컨벤션 예시 (`feat(gitea-ops): 위젯 추가` / `feat/gitea-ops-widget`) 로 교체.

- [ ] **Step 5: 기존 테스트 모두 통과 확인**

```
for f in gitea-ops/tests/test_*.sh; do bash "$f" >/dev/null && echo "OK: $f" || { echo "FAIL: $f"; exit 1; }; done
```

문서 변경만이라 기존 테스트는 영향 없음. 회귀 0 확인용.

- [ ] **Step 6: Commit**

```
git add gitea-ops/SKILL.md
git commit -m "docs(gitea-ops): 작성 규칙 절을 단일 진실 출처로 확장

PR title/브랜치 정규식, 본문 골격, trailer 정책을 한 곳에 명시.
gitea-pr 시그니처에 --no-lint/--no-trailer 추가, 에러 처리 절에
lint 실패 케이스 3종 추가, 옛 짧은 예시 신 컨벤션으로 교체."
```

---

## Task 5: `gitea-pr-status` entry-gate 통합 + 테스트 확장

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-status` (lint 3 항목 통합, 출력 키 + gate 계산)
- Modify: `gitea-ops/tests/test_gitea_pr_status.sh` (fixture 갱신 + lint 분기 케이스)
- Modify: `gitea-ops/SKILL.md` (Entry-gate 절 + gitea-pr-status 출력 키)

가장 마지막 단계. 본 PR 자체가 entry-gate 통과해야 머지 가능하므로, PR body 가 새 골격 준수한 *후* 켜야 함 — plan 의 모든 task 가 끝나는 시점.

- [ ] **Step 1: Update existing `tests/test_gitea_pr_status.sh` fixtures (회귀 잠금)**

기존 fixture title `"Add widget"` / branch `"feat/widget"` 등 새 정규식 통과 안 하는 값들을 새 컨벤션 통과 값으로 일괄 교체. 다음 패턴으로 수정:

기존 fixture 호출 (전부 또는 일부):

```sh
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"Add widget","body":"Adds widget",...,"head":{"ref":"feat/widget",...}}'
```

다음으로 교체:

```sh
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"feat(gitea-ops): 위젯 추가","body":"## 요약\n위젯 추가\n\n## 검증\n- 테스트 녹색","draft":false,"changed_files":3,"base":{"ref":"main","sha":"def"},"head":{"ref":"feat/gitea-ops-widget","sha":"abc"}}'
```

핵심: title 은 정규식 통과, head.ref 는 정규식 통과, body 에 `## 요약` 본문 1자 이상 + `## 검증` 헤더 포함. 모든 "gate pass" 시나리오 fixture 에 이 패턴 적용.

기존 `assert_contains "$out" "head=feat/widget"` 같은 단언도 새 branch 이름 (`feat/gitea-ops-widget`) 으로 동시 교체.

- [ ] **Step 2: Add new test cases at end of `tests/test_gitea_pr_status.sh`**

기존 파일 끝 (`echo OK` 직전, 또는 없으면 파일 끝) 에 다음 케이스 추가:

```sh
# --- lint_title fail: 잘못된 제목 → gate_passed=false, exit 1 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/50 \
    '{"number":50,"title":"no prefix here","body":"## 요약\n내용\n\n## 검증\n- ok","draft":false,"changed_files":2,"base":{"ref":"main","sha":"def"},"head":{"ref":"feat/gitea-ops-widget","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"success","total_count":1}'
rc=0
out="$("$BIN/gitea-pr-status" 50 2>"$TEST_TMP/err")" || rc=$?
assert_eq "$rc" "1" "exit 1 on lint_title fail"
assert_contains "$out" "lint_title=fail" "lint_title key=fail"
assert_contains "$out" "gate_passed=false" "gate fails"
teardown

# --- lint_branch fail: 잘못된 브랜치 → gate_passed=false ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/51 \
    '{"number":51,"title":"feat: ok","body":"## 요약\n내용\n\n## 검증\n- ok","draft":false,"changed_files":2,"base":{"ref":"main","sha":"def"},"head":{"ref":"Bad_Branch","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"success","total_count":1}'
rc=0
out="$("$BIN/gitea-pr-status" 51 2>"$TEST_TMP/err")" || rc=$?
assert_eq "$rc" "1" "exit 1 on lint_branch fail"
assert_contains "$out" "lint_branch=fail" "lint_branch key=fail"
teardown

# --- lint_body fail: ## 요약 누락 → gate_passed=false ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/52 \
    '{"number":52,"title":"feat: ok","body":"본문에 표준 헤더 없음","draft":false,"changed_files":2,"base":{"ref":"main","sha":"def"},"head":{"ref":"feat/x-y","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"success","total_count":1}'
rc=0
out="$("$BIN/gitea-pr-status" 52 2>"$TEST_TMP/err")" || rc=$?
assert_eq "$rc" "1" "exit 1 on lint_body fail"
assert_contains "$out" "lint_body=fail" "lint_body key=fail"
teardown

# --- --json 모드: lint_title/branch/body 모두 키 노출 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/53 \
    '{"number":53,"title":"feat(gitea-ops): ok","body":"## 요약\n내용\n\n## 검증\n- ok","draft":false,"changed_files":2,"base":{"ref":"main","sha":"def"},"head":{"ref":"feat/gitea-ops-x","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"success","total_count":1}'
out="$("$BIN/gitea-pr-status" 53 --json 2>"$TEST_TMP/err")"
echo "$out" | jq -e '.lint_title == "pass"' >/dev/null || { echo "FAIL: --json lint_title key"; exit 1; }
echo "$out" | jq -e '.lint_branch == "pass"' >/dev/null || { echo "FAIL: --json lint_branch key"; exit 1; }
echo "$out" | jq -e '.lint_body == "pass"' >/dev/null || { echo "FAIL: --json lint_body key"; exit 1; }
echo "$out" | jq -e '.gate_passed == true' >/dev/null || { echo "FAIL: --json gate_passed true"; exit 1; }
teardown

# --- CI failure 와 lint fail 동시: exit 2 (CI 우선) ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/54 \
    '{"number":54,"title":"BAD","body":"본문 없음","draft":false,"changed_files":2,"base":{"ref":"main","sha":"def"},"head":{"ref":"BAD","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"failure","total_count":1}'
rc=0
"$BIN/gitea-pr-status" 54 2>"$TEST_TMP/err" >/dev/null || rc=$?
assert_eq "$rc" "2" "exit 2 when CI failure even with lint fail"
teardown
```

- [ ] **Step 3: Run extended test, verify it fails (lint 미통합 + 기존 fixture 정합 깨짐)**

```
bash gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: FAIL — 새 lint 케이스에서 `lint_title=fail` 키가 출력에 없거나, 기존 fixture 의 lint 결과가 gate 계산에 안 들어가 `gate_passed=true` 가 옴.

- [ ] **Step 4: Integrate lint into `bin/gitea-pr-status`**

`bin/gitea-pr-status` 의 다음 위치에 변경:

1. `. "$(dirname "$0")/_common.sh"` 다음 줄에 `_lint.sh` source 추가:

```sh
. "$(dirname "$0")/_lint.sh"
```

2. `head_sha="..."` 줄 다음 (line ~65, 기존 `[ -n "$title" ] && title_ok=...` 직전) 에 lint 평가 블록 추가:

```sh
lint_title=pass
lint_branch=pass
lint_body=pass
lint_pr_title "$title"      >/dev/null 2>&1 || lint_title=fail
lint_branch_name "$head_ref" >/dev/null 2>&1 || lint_branch=fail
lint_pr_body "$body"        >/dev/null 2>&1 || lint_body=fail
```

3. 기존 `required_ok=...` 블록 다음의 `gate_passed=...` 계산을 다음으로 교체:

```sh
gate_passed=false
if [ "$required_ok" = "true" ] && \
   [ "$lint_title" = "pass" ] && \
   [ "$lint_branch" = "pass" ] && \
   [ "$lint_body" = "pass" ] && \
   { [ "$ci_state" = "none" ] || [ "$ci_state" = "success" ]; }; then
    gate_passed=true
fi
```

4. JSON 출력 (`jq -n ...`) 의 인자 + 객체에 lint 키 3개 추가:

```sh
jq -n \
   --argjson title_ok "$title_ok" \
   --argjson body_ok "$body_ok" \
   --argjson changed_files "$changed_files" \
   --argjson draft "$draft" \
   --arg base "$base_ref" \
   --arg head "$head_ref" \
   --arg head_sha "$head_sha" \
   --arg ci_state "$ci_state" \
   --argjson ci_count "$ci_count" \
   --arg lint_title "$lint_title" \
   --arg lint_branch "$lint_branch" \
   --arg lint_body "$lint_body" \
   --argjson gate_passed "$gate_passed" \
   '{title_ok:$title_ok, body_ok:$body_ok, changed_files:$changed_files, draft:$draft, base:$base, head:$head, head_sha:$head_sha, ci_state:$ci_state, ci_count:$ci_count, lint_title:$lint_title, lint_branch:$lint_branch, lint_body:$lint_body, gate_passed:$gate_passed}'
```

5. key=value 출력 블록의 `printf 'ci_count=%s\n' "$ci_count"` 다음에 lint 키 3 줄 추가:

```sh
printf 'lint_title=%s\n'  "$lint_title"
printf 'lint_branch=%s\n' "$lint_branch"
printf 'lint_body=%s\n'   "$lint_body"
```

(`printf 'gate_passed=%s\n' "$gate_passed"` 직전이 자연스러움.)

6. exit code 우선순위는 그대로 — 기존 logic 이 `ci_state=failure|error` 면 exit 2 가 먼저 분기되므로 lint 실패와 CI 실패 동시일 때 CI 가 우선 (Step 2 의 마지막 케이스 검증).

- [ ] **Step 5: Run test, verify it passes**

```
bash gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: `OK` 또는 모든 assert 통과 (마지막 `echo OK` 가 있으면 출력).

- [ ] **Step 6: Update SKILL.md `### Entry-gate` 절**

기존 `#### 필수 항목 (항상)` bullet 목록 끝에 다음 3 줄 추가:

```
- PR 제목이 정규식 `^(feat|fix|docs|refactor|chore|test)(\(...\))?: .+` 통과
- 브랜치 이름이 정규식 `^(feat|fix|...)/[a-z0-9]+(-[a-z0-9]+)*$` 통과
- PR body 에 `## 요약` 및 `## 검증` 헤더 존재, `## 요약` 절 본문이 whitespace 제거 후 1자 이상
```

`gitea-pr-status <PR#> --wait-ci` 한 번으로 점검된다는 문장 유지.

- [ ] **Step 7: Update SKILL.md `### gitea-pr-status` 출력 키 목록**

기존 출력 키 목록에 다음 3 키 추가 (지금 키 목록 줄: `... / ci_state ... / ci_count`):

```
... / `lint_title` / `lint_branch` / `lint_body` / `gate_passed`
```

`gate_passed=true` 조건 설명을 다음으로 교체:

```
`gate_passed=true` 는 모든 필수 항목 통과 + 모든 `lint_*` 항목이 `pass` + (CI 없음 OR `ci_state=success`) 일 때만.
```

- [ ] **Step 8: Run all tests (full regression)**

```
for f in gitea-ops/tests/test_*.sh; do bash "$f" >/dev/null && echo "OK: $f" || { echo "FAIL: $f"; exit 1; }; done
```

Expected: 모든 파일 `OK:`. 본 task 가 가장 표면 변경이 크니 여기서 회귀 잠금이 가장 중요.

- [ ] **Step 9: Self-validation: 본 PR 자체가 새 entry-gate 통과해야 머지 가능**

본 plan 으로 만들어질 PR 의 메타가 새 컨벤션을 따르는지 확인. 실제 PR 만들기 직전 dry-run:

```
echo "TITLE check: $(echo 'feat(gitea-ops): PR 일관성 lint + 작성 규칙 통합' | bash -c '. gitea-ops/bin/_lint.sh && lint_pr_title "$(cat)"' && echo PASS || echo FAIL)"
echo "BRANCH check: $(echo 'feat/gitea-ops-pr-consistency-lint' | bash -c '. gitea-ops/bin/_lint.sh && lint_branch_name "$(cat)"' && echo PASS || echo FAIL)"
```

Expected: `PASS PASS` (body 는 PR 만들 때 작성).

- [ ] **Step 10: Commit**

```
git add gitea-ops/bin/gitea-pr-status gitea-ops/tests/test_gitea_pr_status.sh gitea-ops/SKILL.md
git commit -m "feat(gitea-ops): entry-gate 에 lint 3 항목 통합

gitea-pr-status 가 _lint.sh 의 검증 3종을 호출, 결과를
lint_title/lint_branch/lint_body 출력 키로 노출.
gate_passed 계산에 lint 통과 추가. SKILL.md Entry-gate 절 +
출력 키 목록 동기 갱신."
```

---

## Self-Review (plan-writer)

**Spec coverage:** 6개 spec 절 모두 task 로 매핑됨.

- `_lint.sh` 모듈 → Task 1
- `append_trailer` 헬퍼 → Task 2
- `gitea-pr` 통합 + flag → Task 3
- SKILL.md `## 작성 규칙` / 시그니처 갱신 → Task 4
- `gitea-pr-status` entry-gate 통합 + 출력 키 → Task 5
- SKILL.md Entry-gate 절 + 출력 키 목록 → Task 5 Step 6–7
- Forward-only / 머지된 PR 미수정 → 모든 task 에서 기존 fixture 만 갱신, history 미터치
- Bootstrap 순서 (1→4) → Task 1, 2, 3, 4, 5 순서 그대로

**Placeholder scan:** "TBD", "implement later", "appropriate error handling" 같은 문구 없음. 모든 코드 블록이 실제 동작하는 코드.

**Type consistency:**
- `lint_pr_title` / `lint_branch_name` / `lint_pr_body` / `lint_pr_all` 네 함수명이 모든 task 에서 일치.
- `_LINT_TITLE_RE` / `_LINT_BRANCH_RE` 정규식 상수가 SKILL.md (Task 4) / `_lint.sh` (Task 1) 동일.
- 출력 키 `lint_title` / `lint_branch` / `lint_body` 가 test (Task 5 Step 2) / 구현 (Task 5 Step 4) / SKILL.md (Task 5 Step 7) 셋에서 일치.
- `--no-lint` / `--no-trailer` flag 명이 test (Task 3 Step 1) / 구현 (Task 3 Step 3) / SKILL.md (Task 4 Step 2) 일치.

**Test scope:** 신규 테스트 3개 (`test_lint.sh`, `test_trailer.sh`, `test_gitea_pr.sh`) + 기존 확장 1개 (`test_gitea_pr_status.sh`). 각 task 끝의 회귀 잠금 (전체 테스트 호출) 으로 누적 안전성 확보.

Assisted-by: Claude Code
