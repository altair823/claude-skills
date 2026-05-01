# gitea-ops 리뷰 루프 강화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 리뷰 루프 모드 진입 전 PR shape + CI 상태를 검증하는 entry-gate 와 신규 헬퍼 `gitea-pr-status`, 그리고 review/comment 영속성 보장을 추가한다.

**Architecture:** 기존 thin CLI wrapper 패턴을 그대로 따른다. `gitea-pr-status` 신규 스크립트가 entry-gate 점검 데이터를 한 번에 출력하고, 호출자(Claude) 가 exit code 와 출력을 보고 다음 행동을 결정한다. 영속성 보장은 `_common.sh` 의 sentinel 주석과 `SKILL.md` 의 작성 규칙 양쪽에서 명문화한다.

**Tech Stack:** POSIX `sh`, `curl`, `jq`, `git`. 테스트는 기존 `tests/lib.sh` 의 fixture/stub 패턴 사용.

**Spec:** `docs/superpowers/specs/2026-05-01-gitea-ops-review-loop-hardening-design.md`

---

## File Structure

- **Modify** `gitea-ops/bin/_common.sh` — 상단에 forbidden endpoints sentinel 주석 추가.
- **Create** `gitea-ops/bin/gitea-pr-status` — 신규 헬퍼 스크립트 (entry-gate 점검).
- **Create** `gitea-ops/tests/test_gitea_pr_status.sh` — 신규 테스트 스위트.
- **Modify** `gitea-ops/tests/lib.sh` — call-counter 기반 sequenced fixture 헬퍼 추가 (CI pending → success 전환 테스트용). 기존 헬퍼는 변경 없음.
- **Modify** `gitea-ops/SKILL.md` — Entry-gate subsection, `gitea-pr-status` 스크립트 문서, 작성 규칙에 영속성 항목 추가.

---

## Task 1: `_common.sh` forbidden endpoints sentinel

**Files:**
- Modify: `gitea-ops/bin/_common.sh:1-10`

- [ ] **Step 1: Add sentinel comment block at top of `_common.sh`**

`gitea-ops/bin/_common.sh` 의 첫 두 줄 (shebang + 한 줄 설명) 뒤, `set -eu` 앞에 다음 주석 블록을 삽입한다.

```sh
#!/bin/sh
# Shared helpers for gitea-ops scripts. Sourced, not executed.
# Requires: curl, jq, git.

# FORBIDDEN ENDPOINTS — review/comment 영속성 보장.
# 본 skill의 어떤 스크립트도 다음 endpoint 를 호출해선 안 된다:
#   PATCH  /repos/{owner}/{repo}/pulls/{index}/reviews/{id}
#   DELETE /repos/{owner}/{repo}/pulls/{index}/reviews/{id}
#   PATCH  /repos/{owner}/{repo}/pulls/{index}/comments/{id}
#   DELETE /repos/{owner}/{repo}/pulls/{index}/comments/{id}
#   PATCH  /repos/{owner}/{repo}/issues/comments/{id}
#   DELETE /repos/{owner}/{repo}/issues/comments/{id}
# 이유: 한 번 등록된 review/inline comment/issue comment 는 PR timeline 의
# 회차 기록으로 영구 보존되어야 한다. 새 스크립트 추가 시에도 이 endpoint
# 호출 금지.

set -eu
```

- [ ] **Step 2: Verify existing tests still pass**

```sh
cd /home/altair823/claude-skills/gitea-ops
for t in tests/test_*.sh; do sh "$t" || { echo "FAIL: $t"; exit 1; }; done
echo "all tests pass"
```

Expected: `all tests pass`.

- [ ] **Step 3: Commit**

```sh
cd /home/altair823/claude-skills
git add gitea-ops/bin/_common.sh
git commit -m "$(cat <<'EOF'
docs(gitea-ops): _common.sh에 forbidden endpoints sentinel 추가

review/inline comment/issue comment에 대한 PATCH/DELETE 호출을 향후 스크립트
추가에도 차단하기 위해 _common.sh 상단에 명시적 금지 endpoint 목록을 주석으로
기록한다.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `tests/lib.sh` — sequenced fixture helper

**Why:** `gitea-pr-status --wait-ci` 동작 검증에는 동일 endpoint 가 호출 횟수에 따라 다른 응답을 내놓는 시나리오 (pending → success) 가 필요하다. 기존 `fixture()` 는 단일 응답만 등록 가능하므로 sequenced 변형을 추가한다.

**Files:**
- Modify: `gitea-ops/tests/lib.sh:71-141`

- [ ] **Step 1: Write failing test using new helper**

`gitea-ops/tests/test_lib_seq.sh` 를 새로 만들고 다음 내용을 작성한다.

```sh
#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

setup
install_curl_stub
fixture_seq GET /api/v1/ping 'first' 'second' 'third'

out1="$(curl -sS -X GET https://gitea.test/api/v1/ping)"
assert_eq "$out1" "first" "1st call returns first body"
out2="$(curl -sS -X GET https://gitea.test/api/v1/ping)"
assert_eq "$out2" "second" "2nd call returns second body"
out3="$(curl -sS -X GET https://gitea.test/api/v1/ping)"
assert_eq "$out3" "third" "3rd call returns third body"
out4="$(curl -sS -X GET https://gitea.test/api/v1/ping)"
assert_eq "$out4" "third" "subsequent calls keep last body"
teardown
echo OK
```

- [ ] **Step 2: Run test, expect failure**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_lib_seq.sh
```

Expected: error containing `fixture_seq: not found` (또는 `command not found`) — 헬퍼가 없으므로 실패.

- [ ] **Step 3: Add `fixture_seq` and update curl stub**

`gitea-ops/tests/lib.sh` 의 `install_curl_stub()` 함수 내 `body_file="$fix/$key.body"` 다음에 sequenced 처리 분기를 추가하고, 파일 맨 끝 `call_count()` 함수 다음에 `fixture_seq` 헬퍼를 추가한다.

`install_curl_stub()` 안의 fixture lookup 부분을 다음으로 교체한다:

```sh
# Sequenced fixtures: $fix/<key>.seq.<N>.body in order. Counter file <key>.seq.idx
# tracks next index. Falls back to <key>.body if no sequenced fixtures exist.
seq_idx_file="$fix/$key.seq.idx"
if [ -r "$fix/$key.seq.1.body" ]; then
    idx=1
    if [ -r "$seq_idx_file" ]; then
        idx="$(cat "$seq_idx_file")"
    fi
    chosen="$fix/$key.seq.$idx.body"
    if [ ! -r "$chosen" ]; then
        # past the last; reuse last available
        prev=$((idx - 1))
        chosen="$fix/$key.seq.$prev.body"
    else
        next=$((idx + 1))
        printf '%s' "$next" >"$seq_idx_file"
    fi
    cat "$chosen"
elif [ -r "$body_file" ]; then
    cat "$body_file"
else
    :
fi
```

(원래의 `if [ -r "$body_file" ]; then ... fi` 블록을 위 분기 전체로 대체.)

파일 맨 끝에 다음 헬퍼를 추가한다:

```sh
# Sequenced fixture: each subsequent call to (method,path) returns the next body.
# Usage: fixture_seq METHOD /path body1 body2 body3 ...
fixture_seq() {
    method="$1"; path="$2"; shift 2
    key="$(printf '%s_%s' "$method" "$path" | tr '/?&=' '____')"
    n=1
    for body in "$@"; do
        printf '%s' "$body" >"$FIXTURE_DIR/$key.seq.$n.body"
        n=$((n + 1))
    done
}
```

- [ ] **Step 4: Re-run test, expect pass**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_lib_seq.sh
```

Expected: `OK`.

- [ ] **Step 5: Re-run all existing tests to verify no regression**

```sh
cd /home/altair823/claude-skills/gitea-ops
for t in tests/test_*.sh; do sh "$t" || { echo "FAIL: $t"; exit 1; }; done
echo "all tests pass"
```

Expected: `all tests pass`.

- [ ] **Step 6: Commit**

```sh
cd /home/altair823/claude-skills
git add gitea-ops/tests/lib.sh gitea-ops/tests/test_lib_seq.sh
git commit -m "$(cat <<'EOF'
test(gitea-ops): lib.sh에 sequenced fixture 헬퍼 추가

동일 endpoint 가 호출 횟수에 따라 다른 응답을 내놓는 시나리오 (예: CI status
pending → success 전환) 를 커버하기 위해 fixture_seq 헬퍼와 curl stub 의 순차
응답 처리를 추가한다. 기존 fixture() 는 영향 없음.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `gitea-pr-status` — script scaffold + arg parsing

**Files:**
- Create: `gitea-ops/bin/gitea-pr-status`
- Create: `gitea-ops/tests/test_gitea_pr_status.sh`

- [ ] **Step 1: Write failing tests for arg parsing and help**

`gitea-ops/tests/test_gitea_pr_status.sh` 를 새로 만들고 다음 내용을 작성한다.

```sh
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

echo OK
```

- [ ] **Step 2: Run test, expect failure**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: error containing `No such file` 또는 실행 불가 — 스크립트가 없으므로 실패.

- [ ] **Step 3: Create script scaffold**

`gitea-ops/bin/gitea-pr-status` 를 다음 내용으로 작성한다.

```sh
#!/bin/sh
# PR entry-gate 점검: title/body/changed_files/draft/base/head 메타와 CI 상태를
# 한 번에 출력한다. 리뷰 루프 모드 진입 전 검증용.
#
# Usage:
#   gitea-pr-status <PR#> [--json] [--wait-ci]
#                         [--ci-timeout SECONDS] [--ci-poll-interval SECONDS]
#                         [-r owner/repo] [-u URL]
#
# Exit codes:
#   0  gate_passed=true
#   1  필수 항목 실패 또는 CI pending(--wait-ci 미사용)
#   2  CI failure / error
#   3  --wait-ci timeout 도달 (사용자 위임 신호; 자동 실패 아님)

set -eu
. "$(dirname "$0")/_common.sh"
require_cmd curl jq

PR=""
JSON=0
WAIT_CI=0
CI_TIMEOUT=1200
CI_INTERVAL=30

while [ $# -gt 0 ]; do
    case "$1" in
        --json)              JSON=1; shift ;;
        --wait-ci)           WAIT_CI=1; shift ;;
        --ci-timeout)        CI_TIMEOUT="$2"; shift 2 ;;
        --ci-poll-interval)  CI_INTERVAL="$2"; shift 2 ;;
        -r|--repo)           GITEA_REPO="$2"; shift 2 ;;
        -u|--url)            GITEA_URL="$2"; shift 2 ;;
        -h|--help)           sed -n '2,16p' "$0"; exit 0 ;;
        -*)                  die "알 수 없는 flag: $1" ;;
        *)
            [ -z "$PR" ] || die "예기치 않은 인자: $1"
            PR="$1"; shift ;;
    esac
done

[ -n "$PR" ] || die "PR# 인자 필요"
resolve_remote

die "not implemented yet"
```

```sh
chmod +x /home/altair823/claude-skills/gitea-ops/bin/gitea-pr-status
```

- [ ] **Step 4: Re-run test, expect pass**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: `OK`.

- [ ] **Step 5: Commit**

```sh
cd /home/altair823/claude-skills
git add gitea-ops/bin/gitea-pr-status gitea-ops/tests/test_gitea_pr_status.sh
git commit -m "$(cat <<'EOF'
feat(gitea-ops): gitea-pr-status 스크립트 scaffold

리뷰 루프 entry-gate 점검에 필요한 PR 메타 + CI 상태를 한 번에 출력하는
gitea-pr-status 의 인자 파싱과 help 처리만 우선 구현한다. 본 처리는 후속
커밋에서 TDD 로 채운다.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: PR meta fetch + text/JSON 출력 (CI 무관)

CI 호출은 다음 task 에서 추가한다. 본 task 는 PR object 만 가지고 필수 항목을 평가한다 — CI 가 없는 경우의 동작.

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-status`
- Modify: `gitea-ops/tests/test_gitea_pr_status.sh`

- [ ] **Step 1: Add failing tests for text output (gate pass case, CI 없음)**

`gitea-ops/tests/test_gitea_pr_status.sh` 의 `echo OK` 직전에 다음 블록을 추가한다.

```sh
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
```

- [ ] **Step 2: Run tests, expect new ones to fail**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: 첫 새 테스트에서 `not implemented yet` die 로 실패.

- [ ] **Step 3: Implement PR meta fetch + text output + gate evaluation**

`gitea-ops/bin/gitea-pr-status` 의 마지막 줄 `die "not implemented yet"` 을 다음으로 교체한다.

```sh
pr_path="/repos/$GITEA_REPO/pulls/$PR"
pr_json="$(gitea_get "$pr_path")"
err_msg="$(printf '%s' "$pr_json" | jq -r '.message // empty' 2>/dev/null || true)"
[ -z "$err_msg" ] || die "PR #$PR: $err_msg"

title="$(printf '%s' "$pr_json" | jq -r '.title // ""')"
body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
draft="$(printf '%s' "$pr_json" | jq -r '.draft // false')"
base_ref="$(printf '%s' "$pr_json" | jq -r '.base.ref // ""')"
head_ref="$(printf '%s' "$pr_json" | jq -r '.head.ref // ""')"
head_sha="$(printf '%s' "$pr_json" | jq -r '.head.sha // ""')"
changed_files="$(printf '%s' "$pr_json" | jq -r '.changed_files // 0')"

[ -n "$title" ] && title_ok=true || title_ok=false
[ -n "$body" ]  && body_ok=true  || body_ok=false

# CI placeholder — fully wired in Task 5.
ci_state="none"
ci_count=0

# Gate evaluation.
required_ok=false
if [ "$title_ok" = "true" ] && [ "$body_ok" = "true" ] && \
   [ "$changed_files" -gt 0 ] && [ "$draft" = "false" ] && \
   [ -n "$base_ref" ] && [ -n "$head_ref" ]; then
    required_ok=true
fi
gate_passed=false
if [ "$required_ok" = "true" ] && \
   { [ "$ci_state" = "none" ] || [ "$ci_state" = "success" ]; }; then
    gate_passed=true
fi

# Output.
if [ "$JSON" = "1" ]; then
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
       --argjson gate_passed "$gate_passed" \
       '{title_ok:$title_ok, body_ok:$body_ok, changed_files:$changed_files, draft:$draft, base:$base, head:$head, head_sha:$head_sha, ci_state:$ci_state, ci_count:$ci_count, gate_passed:$gate_passed}'
else
    printf 'title_ok=%s\n'      "$title_ok"
    printf 'body_ok=%s\n'       "$body_ok"
    printf 'changed_files=%s\n' "$changed_files"
    printf 'draft=%s\n'         "$draft"
    printf 'base=%s\n'          "$base_ref"
    printf 'head=%s\n'          "$head_ref"
    printf 'head_sha=%s\n'      "$head_sha"
    printf 'ci_state=%s\n'      "$ci_state"
    printf 'ci_count=%s\n'      "$ci_count"
    printf 'gate_passed=%s\n'   "$gate_passed"
fi

# Exit code.
if [ "$gate_passed" = "true" ]; then exit 0; fi
case "$ci_state" in
    failure|error) exit 2 ;;
    pending)       [ "$WAIT_CI" = "1" ] && exit 3 || exit 1 ;;
esac
exit 1
```

- [ ] **Step 4: Re-run tests, expect pass**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: `OK`. 단 `set -eu` 환경에서 `out=$(...)` 호출이 실패하면 `rc` 가 캡처되기 전에 스크립트가 종료될 수 있다. 첫 케이스의 `rc=$?` 캡처는 `set -e` 가 명령 substitution 의 비-0 exit 를 어떻게 다루는지에 따라 영향받음 — 테스트 스크립트의 `set -eu` 가 문제되면 첫 케이스를 다음 형태로 바꾼다:

```sh
out="$("$BIN/gitea-pr-status" 42)" || rc=$?
rc="${rc:-0}"
```

(이 변형이 필요하면 같은 step 안에서 적용하고 다시 돌린다.)

- [ ] **Step 5: Commit**

```sh
cd /home/altair823/claude-skills
git add gitea-ops/bin/gitea-pr-status gitea-ops/tests/test_gitea_pr_status.sh
git commit -m "$(cat <<'EOF'
feat(gitea-ops): gitea-pr-status에 PR 메타 fetch + 필수 항목 평가 추가

PR object 의 title/body/draft/changed_files/base/head 를 조회해 entry-gate
필수 항목 통과 여부를 텍스트 또는 JSON 으로 출력한다. CI 처리는 후속 커밋에서
추가하므로 현재는 ci_state=none 으로 고정.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: CI status fetch (success / failure / none / pending without --wait-ci)

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-status`
- Modify: `gitea-ops/tests/test_gitea_pr_status.sh`

- [ ] **Step 1: Add failing tests for CI states**

`gitea-ops/tests/test_gitea_pr_status.sh` 의 `echo OK` 직전에 다음 블록을 추가한다.

```sh
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
```

- [ ] **Step 2: Run tests, expect new ones to fail**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: 신규 케이스에서 `ci_state=none` 이 출력되어 assert_contains 실패.

- [ ] **Step 3: Wire CI fetch**

`gitea-ops/bin/gitea-pr-status` 의 다음 블록을 교체한다.

기존:
```sh
# CI placeholder — fully wired in Task 5.
ci_state="none"
ci_count=0
```

신규:
```sh
# Fetch combined CI status for head_sha. Empty statuses → CI absent.
ci_json="$(gitea_get "/repos/$GITEA_REPO/commits/$head_sha/status")"
ci_count="$(printf '%s' "$ci_json" | jq -r '.total_count // 0')"
if [ "$ci_count" = "0" ]; then
    ci_state="none"
else
    ci_state="$(printf '%s' "$ci_json" | jq -r '.state // "pending"')"
fi
```

- [ ] **Step 4: Re-run tests, expect pass**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: `OK`.

- [ ] **Step 5: Commit**

```sh
cd /home/altair823/claude-skills
git add gitea-ops/bin/gitea-pr-status gitea-ops/tests/test_gitea_pr_status.sh
git commit -m "$(cat <<'EOF'
feat(gitea-ops): gitea-pr-status에 CI 상태 조회 추가

head_sha 의 combined status 를 조회해 ci_state 를 success/failure/error/
pending/none 으로 분류한다. failure/error 시 exit 2, pending(--wait-ci 미사용)
시 exit 1, 통계가 없으면 none 으로 처리해 gate 통과를 막지 않는다.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `--wait-ci` polling + timeout exit 3

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-status`
- Modify: `gitea-ops/tests/test_gitea_pr_status.sh`

- [ ] **Step 1: Add failing tests for --wait-ci**

`gitea-ops/tests/test_gitea_pr_status.sh` 의 `echo OK` 직전에 다음 블록을 추가한다.

```sh
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
```

- [ ] **Step 2: Run tests, expect new ones to fail**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: --wait-ci 가 동작하지 않아 첫 케이스에서 ci_state=pending 으로 멈춰 `ci_state=success` assertion 실패.

- [ ] **Step 3: Implement polling**

`gitea-ops/bin/gitea-pr-status` 에서 CI fetch 블록 직후, gate evaluation 직전에 다음을 삽입한다.

```sh
# Optional polling for pending CI.
if [ "$WAIT_CI" = "1" ] && [ "$ci_state" = "pending" ]; then
    elapsed=0
    while [ "$ci_state" = "pending" ] && [ "$elapsed" -lt "$CI_TIMEOUT" ]; do
        sleep "$CI_INTERVAL"
        elapsed=$((elapsed + CI_INTERVAL))
        ci_json="$(gitea_get "/repos/$GITEA_REPO/commits/$head_sha/status")"
        ci_count="$(printf '%s' "$ci_json" | jq -r '.total_count // 0')"
        if [ "$ci_count" = "0" ]; then
            ci_state="none"
        else
            ci_state="$(printf '%s' "$ci_json" | jq -r '.state // "pending"')"
        fi
    done
fi
```

- [ ] **Step 4: Re-run tests, expect pass**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: `OK`. (timeout 케이스는 약 2초 소요, transition 케이스는 즉시.)

- [ ] **Step 5: Run full test suite**

```sh
cd /home/altair823/claude-skills/gitea-ops
for t in tests/test_*.sh; do sh "$t" || { echo "FAIL: $t"; exit 1; }; done
echo "all tests pass"
```

Expected: `all tests pass`.

- [ ] **Step 6: Commit**

```sh
cd /home/altair823/claude-skills
git add gitea-ops/bin/gitea-pr-status gitea-ops/tests/test_gitea_pr_status.sh
git commit -m "$(cat <<'EOF'
feat(gitea-ops): gitea-pr-status에 --wait-ci polling + timeout exit 3 추가

CI 가 pending 인 경우 --wait-ci 옵션으로 30초 간격 (조정 가능) 으로 최대
20분 (기본) 까지 polling 한다. 도중 success 도달 시 즉시 통과, failure/error
시 exit 2, 시간 초과 시 exit 3 으로 호출자가 사용자 위임 결정을 내리도록 한다.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `--json` 모드 검증 (회귀 방지)

**Files:**
- Modify: `gitea-ops/tests/test_gitea_pr_status.sh`

- [ ] **Step 1: Add failing test for --json**

`gitea-ops/tests/test_gitea_pr_status.sh` 의 `echo OK` 직전에 다음을 추가한다.

```sh
# --- --json: parseable object with all fields ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"My PR","body":"body","draft":false,"changed_files":7,"base":{"ref":"main","sha":"d"},"head":{"ref":"feat","sha":"abc"}}'
fixture GET /api/v1/repos/owner/repo/commits/abc/status \
    '{"state":"success","total_count":1,"statuses":[{"context":"build","state":"success"}]}'

out="$("$BIN/gitea-pr-status" 42 --json)"
assert_eq "$(printf '%s' "$out" | jq -r '.title_ok')"      "true"    "json title_ok"
assert_eq "$(printf '%s' "$out" | jq -r '.body_ok')"       "true"    "json body_ok"
assert_eq "$(printf '%s' "$out" | jq -r '.changed_files')" "7"       "json changed_files"
assert_eq "$(printf '%s' "$out" | jq -r '.draft')"         "false"   "json draft"
assert_eq "$(printf '%s' "$out" | jq -r '.base')"          "main"    "json base"
assert_eq "$(printf '%s' "$out" | jq -r '.head')"          "feat"    "json head"
assert_eq "$(printf '%s' "$out" | jq -r '.head_sha')"      "abc"     "json head_sha"
assert_eq "$(printf '%s' "$out" | jq -r '.ci_state')"      "success" "json ci_state"
assert_eq "$(printf '%s' "$out" | jq -r '.ci_count')"      "1"       "json ci_count"
assert_eq "$(printf '%s' "$out" | jq -r '.gate_passed')"   "true"    "json gate_passed"
teardown
```

- [ ] **Step 2: Run tests, expect pass (already implemented in Task 4)**

```sh
sh /home/altair823/claude-skills/gitea-ops/tests/test_gitea_pr_status.sh
```

Expected: `OK`. JSON 분기는 Task 4 에서 이미 구현되었으므로 추가 코드 없이 통과해야 한다.

- [ ] **Step 3: Commit**

```sh
cd /home/altair823/claude-skills
git add gitea-ops/tests/test_gitea_pr_status.sh
git commit -m "$(cat <<'EOF'
test(gitea-ops): gitea-pr-status --json 출력 회귀 테스트 추가

JSON 모드의 모든 필드 (title_ok, body_ok, changed_files, draft, base, head,
head_sha, ci_state, ci_count, gate_passed) 가 spec 대로 직렬화되는지 확인한다.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: SKILL.md 업데이트

**Files:**
- Modify: `gitea-ops/SKILL.md`

- [ ] **Step 1: Add Entry-gate subsection**

`gitea-ops/SKILL.md` 의 `## PR 생성 전 선택지: 리뷰 루프` 섹션 안, `### 루프 한 회차 동작` 바로 앞에 다음 subsection 을 삽입한다.

```markdown
### Entry-gate

리뷰 루프 모드를 선택했을 때, 루프 1회차의 `gitea-pr-diff` 호출 **전에** 다음 검증을 통과해야 한다. 통과 못 하면 루프 진입 거부, 사용자에게 누락 항목을 보고하고 PR 보완 후 재시도 안내.

`gitea-pr-status <PR#> --wait-ci` 한 번으로 모두 점검 가능 (스크립트 항목 참조).

#### 필수 항목 (항상)
- `title` 비어있지 않음
- `body` 비어있지 않음
- `changed_files > 0`
- `draft == false`
- `base` / `head` branch 존재

#### CI 항목 (조건부)
PR head SHA 의 combined status 를 조회. `total_count == 0` 이면 CI 미설정으로 간주, 항목 skip. 통계가 있으면 다음 정책:

- `state=success` → 통과.
- `state=failure` 또는 `state=error` → 거부, 사용자에게 보고.
- `state=pending` → 30초 간격으로 최대 20분 polling. 도중 success 도달 시 통과, fail 도달 시 거부.
- 20분 경과 후에도 pending 유지 시 자동 실패 처리하지 않고 **사용자에게 위임** — Claude 는 현재 상태를 보고하고 사용자의 결정 (연장 / 중단 / 강제 진입) 을 기다린다 (`gitea-pr-status` exit 3).
```

- [ ] **Step 2: Add a one-line prefix to "루프 한 회차 동작"**

`### 루프 한 회차 동작` 의 첫 본문 줄 (`리뷰 루프 모드에서는 매 회차마다...`) 앞에 다음 한 줄을 삽입한다.

```markdown
회차 1 진입 전 위 [Entry-gate](#entry-gate) 를 통과해야 한다. 통과 못 한 PR 에는 리뷰 루프를 시작하지 않는다.

```

- [ ] **Step 3: Add `gitea-pr-status` script docs**

`gitea-ops/SKILL.md` 의 `### gitea-pr-diff` subsection 직후에 다음을 삽입한다.

````markdown
### `gitea-pr-status`

```
gitea-pr-status <PR#> [--json] [--wait-ci]
                      [--ci-timeout SECONDS] [--ci-poll-interval SECONDS]
                      [-r owner/repo] [-u URL]
```

PR entry-gate 점검에 필요한 메타와 CI 상태를 한 번에 출력한다.

- `--json`: 단일 JSON 객체 출력. 미지정 시 사람-친화 `key=value` 라인.
- `--wait-ci`: CI 가 `pending` 일 때 polling. 미지정 시 즉시 현재 상태만 출력.
- `--ci-timeout SECONDS`: polling 최대 시간 (기본 1200 = 20분).
- `--ci-poll-interval SECONDS`: polling 간격 (기본 30).

출력 (텍스트):

```
title_ok=true
body_ok=true
changed_files=12
draft=false
base=main
head=feat/widget
head_sha=abc1234...
ci_state=success
ci_count=3
gate_passed=true
```

`ci_state` 값: `none | pending | success | failure | error`. `gate_passed` 는 모든 필수 항목 통과 + (CI 없음 OR `ci_state=success`) 일 때만 true.

#### 종료 코드

- `0`: gate_passed=true.
- `1`: 필수 항목 실패 또는 CI pending(--wait-ci 미사용).
- `2`: CI failure / error.
- `3`: `--wait-ci` 사용 시 timeout 도달. **자동 실패 아님** — 호출자가 결과를 사용자에게 보고하고 결정을 위임해야 한다는 신호.
- 그 외: API 오류 등 일반 실패.

````

- [ ] **Step 4: Add 영속성 항목 to 작성 규칙**

`gitea-ops/SKILL.md` 의 `## 작성 규칙` 섹션 마지막 bullet (현재 `**PR review (...)**` 로 시작하는 항목과 그 sub-bullet 들) 다음에 다음 항목을 추가한다.

```markdown
- **리뷰·코멘트 영속성**: review summary, inline review comment, issue comment 는 한 번 등록되면 **수정·삭제하지 않는다**. 오타나 잘못된 판단을 발견한 경우에도 새 review 또는 새 코멘트로 정정한다 — timeline 의 회차 기록은 영구 보존되어야 한다. 본 skill 의 어떤 스크립트도 `PATCH`/`DELETE` × {`pulls/{n}/reviews/{id}`, `pulls/{n}/comments/{id}`, `issues/comments/{id}`} 6개 endpoint 를 호출하지 않는다 — `_common.sh` 상단의 `FORBIDDEN ENDPOINTS` 주석 참조. 새 스크립트 추가 시에도 이 endpoint 사용 금지.
```

- [ ] **Step 5: Sanity check — view rendered diff**

```sh
cd /home/altair823/claude-skills
git diff gitea-ops/SKILL.md
```

Expected: 위 4개 변경이 모두 반영되어 있고 기존 내용은 손상 없음.

- [ ] **Step 6: Commit**

```sh
cd /home/altair823/claude-skills
git add gitea-ops/SKILL.md
git commit -m "$(cat <<'EOF'
docs(gitea-ops): SKILL.md에 entry-gate, gitea-pr-status, 영속성 규칙 추가

리뷰 루프 모드의 entry-gate 정책 (필수 항목 + CI 상태 polling 20분, pending
timeout 시 사용자 위임), 신규 헬퍼 gitea-pr-status 의 사용법과 종료 코드,
그리고 review/inline comment/issue comment 의 PATCH/DELETE 호출 금지 규칙을
작성 규칙에 명문화한다.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: 최종 통합 검증

**Files:** (변경 없음, 검증만)

- [ ] **Step 1: Run all tests**

```sh
cd /home/altair823/claude-skills/gitea-ops
for t in tests/test_*.sh; do
    printf '\n=== %s ===\n' "$t"
    sh "$t" || { echo "FAIL: $t"; exit 1; }
done
echo "ALL OK"
```

Expected: 각 테스트가 `OK` 출력 후 `ALL OK`.

- [ ] **Step 2: Verify forbidden endpoints sentinel grep 결과**

```sh
grep -c "FORBIDDEN ENDPOINTS" /home/altair823/claude-skills/gitea-ops/bin/_common.sh
```

Expected: `1`.

- [ ] **Step 3: Verify no PATCH/DELETE on protected endpoints in any script**

```sh
cd /home/altair823/claude-skills/gitea-ops
grep -RnE '"(PATCH|DELETE)"' bin/ || echo "no PATCH/DELETE method strings found"
```

Expected: `no PATCH/DELETE method strings found` (현재 스크립트 어디에도 PATCH/DELETE method 가 없음을 확인).

- [ ] **Step 4: 종합 보고**

다음 항목을 사용자에게 짧게 보고:

- 신규 스크립트: `gitea-pr-status` (TDD 9개 테스트 포함).
- `_common.sh` 에 forbidden endpoints sentinel 추가.
- `tests/lib.sh` 에 `fixture_seq` 추가, 기존 테스트 영향 없음.
- `SKILL.md` 에 Entry-gate, `gitea-pr-status` 문서, 영속성 규칙 추가.
- 기존 동작 (단발 모드, 회차 종료 조건, 사람 머지 단계) 변경 없음.

---

## Self-Review Checklist (plan author 사후 점검)

- [x] **Spec coverage**: Entry-gate (Task 8 docs + Tasks 3–6 script), gitea-pr-status (Tasks 3–7), 영속성 (Task 1 sentinel + Task 8 docs) 모두 task 로 매핑됨.
- [x] **Placeholder scan**: 모든 step 에 실제 코드/명령 있음. "TBD/TODO/적절한 처리" 문구 없음.
- [x] **Type consistency**: 출력 필드명 (`title_ok`, `body_ok`, `changed_files`, `draft`, `base`, `head`, `head_sha`, `ci_state`, `ci_count`, `gate_passed`) Task 3/4/5/7 전반에서 일관. Exit code (0/1/2/3) Tasks 3–6 전반에서 일관.
