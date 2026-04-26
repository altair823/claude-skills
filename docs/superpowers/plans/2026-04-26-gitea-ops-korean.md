# gitea-ops Korean Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert all `gitea-ops` user-facing output, `die` messages, `--help` headers, and `SKILL.md` to Korean prose (with English CLI identifiers and technical keywords preserved inline). Add a `## 작성 규칙` section to `SKILL.md` so Claude defaults to Korean when generating PR/review/issue bodies through this skill.

**Architecture:** Modify the seven scripts (`gitea-pr`, `gitea-pr-merge`, `gitea-pr-diff`, `gitea-pr-review`, `gitea-release`, `gitea-issue`, `gitea-issue-close`) and shared `_common.sh` so all printf/die strings facing the user are Korean. Each script's `--help` header comment is rewritten to Korean prose with English Usage signatures retained. The five test files have their `assert_contains`/`assert_file_contains` substring arguments updated to match the new Korean output. `SKILL.md` is rewritten end-to-end with Korean section headers and prose, English code blocks and signatures, plus one new `## 작성 규칙` section.

**Tech Stack:** POSIX `/bin/sh`, `curl`, `jq`, `git`. Test harness: existing `tests/lib.sh`. Encoding: UTF-8 throughout.

**Reference spec:** `docs/superpowers/specs/2026-04-26-gitea-ops-korean-design.md`

---

## File Structure

| Path | Action | Purpose |
|------|--------|---------|
| `gitea-ops/bin/_common.sh` | Modify | `die` 메시지 한국어화 (prefix `gitea-ops:` 유지). |
| `gitea-ops/bin/gitea-pr` | Modify | info/die/--help 한국어화. |
| `gitea-ops/bin/gitea-pr-merge` | Modify | info/die/--help/gate warning 한국어화. |
| `gitea-ops/bin/gitea-pr-diff` | Modify | info/die/--help/header labels 한국어화. |
| `gitea-ops/bin/gitea-pr-review` | Modify | info/die/--help 한국어화. |
| `gitea-ops/bin/gitea-release` | Modify | info/die/--help 한국어화. (`## 변경사항` 섹션은 이미 한국어 — 무변경) |
| `gitea-ops/bin/gitea-issue` | Modify | info/die/--help 한국어화. |
| `gitea-ops/bin/gitea-issue-close` | Modify | info/die/--help 한국어화. |
| `gitea-ops/tests/test_common_helpers.sh` | Modify | reviewer-token 관련 assert substring 한국어로 갱신. |
| `gitea-ops/tests/test_gitea_pr_diff.sh` | Modify | assert substring 한국어로 갱신. |
| `gitea-ops/tests/test_gitea_pr_review.sh` | Modify | assert substring 한국어로 갱신. |
| `gitea-ops/tests/test_gitea_pr_merge.sh` | Modify | assert substring 한국어로 갱신. |
| `gitea-ops/tests/test_gitea_release_auto_notes.sh` | (no change) | `## 변경사항` 이미 한국어, 다른 assert 없음. |
| `gitea-ops/SKILL.md` | Modify | 섹션 헤더+산문 한국어화, code block 영문 유지, `## 작성 규칙` 섹션 추가. |

각 commit은 한 script + 그 script의 테스트를 같이 변경하여 항상 green을 유지한다.

---

## Task 1: `_common.sh` die 메시지 한국어화

**Files:**
- Modify: `gitea-ops/bin/_common.sh`
- Modify: `gitea-ops/tests/test_common_helpers.sh`

- [ ] **Step 1: Update `_common.sh` die messages**

In `gitea-ops/bin/_common.sh`, replace each English die message with the Korean equivalent. Apply these exact substitutions:

```sh
# Line ~19:
die "no token (set GITEA_TOKEN or write $GITEA_TOKEN_FILE)"
# →
die "token 필요 (GITEA_TOKEN env 또는 $GITEA_TOKEN_FILE 파일)"
```

```sh
# Line ~58 (parse_remote default branch):
*) die "cannot parse remote URL: $url" ;;
# →
*) die "remote URL 파싱 실패: $url" ;;
```

```sh
# Line ~86:
[ -n "${GITEA_URL:-}" ] || die "no GITEA_URL (set --url, GITEA_URL, or config)"
[ -n "${GITEA_REPO:-}" ] || die "no GITEA_REPO (set --repo, GITEA_REPO, or config)"
# →
[ -n "${GITEA_URL:-}" ] || die "GITEA_URL 미설정 (--url / GITEA_URL env / config 파일 중 하나 필요)"
[ -n "${GITEA_REPO:-}" ] || die "GITEA_REPO 미설정 (--repo / GITEA_REPO env / config 파일 중 하나 필요)"
```

```sh
# In require_cmd():
die "missing command: $c"
# →
die "필수 명령 없음: $c"
```

```sh
# In load_reviewer_token():
die "reviewer token required (set GITEA_REVIEWER_TOKEN or write $GITEA_REVIEWER_TOKEN_FILE)"
# →
die "reviewer token 필요 (GITEA_REVIEWER_TOKEN env 또는 $GITEA_REVIEWER_TOKEN_FILE 파일)"
```

The `gitea-ops:` prefix from `die()` itself is preserved.

- [ ] **Step 2: Update test substrings**

In `gitea-ops/tests/test_common_helpers.sh`, find this assertion (in the "missing both" test case):

```sh
assert_file_contains "$TEST_TMP/err" "reviewer token" "error mentions reviewer token"
```

The Korean substring `"reviewer token"` is still present (kept inline in `"reviewer token 필요 ..."`), so this assertion still passes. **No change needed.**

If `gitea_get` invocation tests rely on other strings, leave them alone.

- [ ] **Step 3: Run tests**

Run: `sh gitea-ops/tests/test_common_helpers.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 4: Commit**

```sh
git add gitea-ops/bin/_common.sh
git commit -m "feat(gitea-ops): _common.sh die 메시지 한국어화"
```

(`tests/test_common_helpers.sh` is unchanged; not added.)

---

## Task 2: `gitea-pr` 한국어화

**Files:**
- Modify: `gitea-ops/bin/gitea-pr`

- [ ] **Step 1: Rewrite header comment**

Replace lines 2-8 of `gitea-ops/bin/gitea-pr` with:

```sh
# Gitea에 pull request를 생성한다.
#
# Usage:
#   gitea-pr --title "..." --body "..." --head BRANCH [--base main]
#            [--draft] [--assignee USER]... [--label LABEL]...
#            [-r owner/repo] [-u URL]
```

The Usage block stays English. Surrounding prose becomes Korean.

- [ ] **Step 2: Update sed range**

Verify line count of the new header. If it's 7 lines (lines 2-8), the existing `sed -n '2,8p' "$0"` is still correct. If different, adjust to the new `'2,Np'` range so the printed help block ends just before `set -eu`.

The new header occupies lines 2-7 (6 prose lines), so update:

```sh
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
```

to:

```sh
        -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
```

(Adjust the number based on actual file inspection. Run `gitea-pr --help 2>&1 | grep -c 'set -eu'` and confirm it returns `0` after the change.)

- [ ] **Step 3: Update die / info messages**

Find and replace these die calls:

```sh
[ -n "$TITLE" ] || die "--title required"
[ -n "$HEAD" ]  || die "--head required"
# →
[ -n "$TITLE" ] || die "--title 인자 필요"
[ -n "$HEAD" ]  || die "--head 인자 필요"
```

```sh
*) die "unknown arg: $1" ;;
# →
*) die "알 수 없는 인자: $1" ;;
```

Find and replace these info messages:

```sh
printf '[gitea-pr] pushing branch %s\n' "$HEAD" >&2
# →
printf '[gitea-pr] branch push: %s\n' "$HEAD" >&2
```

```sh
printf '[gitea-pr] failed:\n%s\n' "$resp" >&2
# →
printf '[gitea-pr] PR 작성 실패:\n%s\n' "$resp" >&2
```

```sh
printf '[gitea-pr] #%s %s\n' "$num" "$url" >&2
# →
printf '[gitea-pr] #%s 작성 완료: %s\n' "$num" "$url" >&2
```

- [ ] **Step 4: Smoke test --help**

Run: `gitea-ops/bin/gitea-pr --help`
Expected output starts with the new Korean header. Should NOT contain `set -eu`. Should contain `--title`.

Run: `gitea-ops/bin/gitea-pr --help 2>&1 | grep -c 'set -eu'`
Expected: `0`.

- [ ] **Step 5: Commit**

```sh
git add gitea-ops/bin/gitea-pr
git commit -m "feat(gitea-ops): gitea-pr 출력/--help 한국어화"
```

---

## Task 3: `gitea-pr-merge` 한국어화

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-merge`
- Modify: `gitea-ops/tests/test_gitea_pr_merge.sh`

- [ ] **Step 1: Rewrite header comment**

Replace the comment header block (lines 2-17) of `gitea-ops/bin/gitea-pr-merge` with Korean prose:

```sh
# Gitea PR을 merge하고, 원격 head branch와 로컬 worktree를 정리한다.
#
# Usage:
#   gitea-pr-merge <PR#> [options]
#
# Options:
#   --method <merge|squash|rebase>   merge 방식 (기본: merge)
#   --force                          review gate 우회
#   --keep-branch                    원격 head branch 보존
#   --keep-worktree                  로컬 worktree 보존
#   --worktree <path>                명시적 worktree 경로 (기본: cwd)
#   -r owner/repo                    repo 오버라이드
#   -u URL                           Gitea base URL 오버라이드
#
# Review gate: APPROVED & non-dismissed review가 1개 이상 있어야 merge 진행.
#              없으면 거부 (--force로 우회). 이미 머지된 PR은 gate 스킵.
```

- [ ] **Step 2: Update sed range**

Count the new header lines (should be lines 2-17 = 16 prose lines). If sed range was `'2,17p'`, recheck. Run after edits:

```sh
gitea-ops/bin/gitea-pr-merge --help 2>&1 | grep -c 'set -eu'
```
Expected: `0`. Adjust sed range until satisfied.

- [ ] **Step 3: Update die messages**

```sh
die "unknown flag: $1"
# →
die "알 수 없는 flag: $1"
```

```sh
die "unexpected positional: $1"
# →
die "예기치 않은 인자: $1"
```

```sh
die "PR# required"
# →
die "PR# 인자 필요"
```

```sh
die "invalid --method: $METHOD (use merge|squash|rebase)"
# →
die "--method 값 오류: $METHOD (merge|squash|rebase 중 선택)"
```

```sh
die "PR #$PR not found or missing head.ref"
# →
die "PR #$PR 존재하지 않거나 head.ref 누락"
```

```sh
die "failed to fetch reviews: ${err_msg:-unexpected response}"
# →
die "reviews 조회 실패: ${err_msg:-예기치 않은 응답}"
```

```sh
die "no APPROVED review on PR #$PR; use --force to override"
# →
die "PR #$PR에 APPROVED review 없음 — --force로 우회 가능"
```

```sh
die "merge failed: $err_msg"
# →
die "merge 실패: $err_msg"
```

```sh
die "could not determine main worktree"
# →
die "main worktree 식별 실패"
```

```sh
die "cannot cd to main worktree: $main_wt"
# →
die "main worktree로 cd 실패: $main_wt"
```

- [ ] **Step 4: Update info messages**

```sh
printf '[gitea-pr-merge] PR #%s (%s) already merged — skipping merge call\n' "$PR" "$head_ref" >&2
# →
printf '[gitea-pr-merge] PR #%s (%s) 이미 머지됨 — merge 호출 스킵\n' "$PR" "$head_ref" >&2
```

```sh
printf '[gitea-pr-merge] PR #%s merged (%s, branch %s)\n' "$PR" "$METHOD" "$head_ref" >&2
# →
printf '[gitea-pr-merge] PR #%s 머지 완료 (방식: %s, head: %s)\n' "$PR" "$METHOD" "$head_ref" >&2
```

```sh
printf '[gitea-pr-merge] warning: could not delete remote branch %s — see git error above\n' "$head_ref" >&2
# →
printf '[gitea-pr-merge] 경고: 원격 branch 삭제 실패 — git 에러 위 참조: %s\n' "$head_ref" >&2
```

```sh
printf '[gitea-pr-merge] deleted remote branch %s\n' "$head_ref" >&2
# →
printf '[gitea-pr-merge] 원격 branch 삭제: %s\n' "$head_ref" >&2
```

```sh
printf '[gitea-pr-merge] not in a git work tree; skipping branch delete\n' >&2
# →
printf '[gitea-pr-merge] git work tree 아님 — branch 삭제 스킵\n' >&2
```

```sh
printf '[gitea-pr-merge] not in a git work tree; skipping worktree cleanup\n' >&2
# →
printf '[gitea-pr-merge] git work tree 아님 — worktree 정리 스킵\n' >&2
```

```sh
printf '[gitea-pr-merge] cwd not on head branch (%s != %s); skipping worktree cleanup\n' "$current_branch" "$head_ref" >&2
# →
printf '[gitea-pr-merge] 현재 head branch 아님 (%s != %s) — worktree 정리 스킵\n' "$current_branch" "$head_ref" >&2
```

```sh
printf '[gitea-pr-merge] cwd is the main worktree; refusing self-removal\n' >&2
# →
printf '[gitea-pr-merge] cwd가 main worktree임 — self-removal 거부\n' >&2
```

```sh
printf "[gitea-pr-merge] cleanup aborted mid-sequence — worktree %s not removed\n" "$target_wt" >&2
# →
printf "[gitea-pr-merge] cleanup 중단됨 — worktree 미정리: %s\n" "$target_wt" >&2
```

```sh
printf '[gitea-pr-merge] removed worktree %s\n' "$target_wt" >&2
# →
printf '[gitea-pr-merge] worktree 정리: %s\n' "$target_wt" >&2
```

```sh
printf '[gitea-pr-merge] warning: reviews list >= 50; pagination not implemented, gate may misfire\n' >&2
# →
printf '[gitea-pr-merge] 경고: reviews 응답 ≥ 50건 — pagination 미구현, gate 오작동 가능\n' >&2
```

- [ ] **Step 5: Update test substrings**

In `gitea-ops/tests/test_gitea_pr_merge.sh`, update each `assert_contains`/`assert_file_contains` substring to match the new Korean output. Apply these substitutions (find + replace exactly):

```sh
assert_contains "$out" "Usage:" "--help shows usage"
# (unchanged — Usage: is in English signature line)

assert_contains "$out" "PR#" "--help mentions PR# arg"
# (unchanged — PR# substring still present)

assert_contains "$out" "--force" "--help mentions --force flag"
# (unchanged)

assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
# →
assert_file_contains "$TEST_TMP/err" "PR# 인자" "error mentions PR# requirement"

assert_file_contains "$TEST_TMP/err" "unknown" "error mentions unknown"
# →
assert_file_contains "$TEST_TMP/err" "알 수 없는 flag" "error mentions unknown flag"

assert_contains "$out" "merged" "success message mentions merged"
# →
assert_contains "$out" "머지 완료" "success message mentions merged"

assert_contains "$out" "feat/topic" "success message mentions branch"
# (unchanged — branch name itself)

assert_contains "$out" "already merged" "warns already merged"
# →
assert_contains "$out" "이미 머지됨" "warns already merged"

assert_file_contains "$TEST_TMP/err" "not mergeable" "error message propagated"
# (unchanged — propagated from Gitea response message field)

assert_file_contains "$GIT_LOG" "push origin --delete feat/topic" "deletes remote branch"
# (unchanged — git command verbatim)

assert_file_contains "$TEST_TMP/out" "could not delete remote branch" "warns on failure"
# →
assert_file_contains "$TEST_TMP/out" "원격 branch 삭제 실패" "warns on failure"

assert_contains "$out" "not on head branch" "warns when not on head"
# →
assert_contains "$out" "현재 head branch 아님" "warns when not on head"

assert_contains "$out" "refusing self-removal" "warns about self-removal"
# →
assert_contains "$out" "self-removal 거부" "warns about self-removal"

assert_file_contains "$TEST_TMP/err" "no APPROVED" "error mentions no APPROVED"
# →
assert_file_contains "$TEST_TMP/err" "APPROVED review 없음" "error mentions no APPROVED"

assert_file_contains "$TEST_TMP/err" "--force" "error mentions --force"
# (unchanged — --force is English flag)

assert_file_contains "$TEST_TMP/err" "no APPROVED" "dismissed does not count"
# →
assert_file_contains "$TEST_TMP/err" "APPROVED review 없음" "dismissed does not count"
```

- [ ] **Step 6: Run tests**

Run: `sh gitea-ops/tests/test_gitea_pr_merge.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 7: Commit**

```sh
git add gitea-ops/bin/gitea-pr-merge gitea-ops/tests/test_gitea_pr_merge.sh
git commit -m "feat(gitea-ops): gitea-pr-merge 출력/--help 한국어화 + 테스트 갱신"
```

---

## Task 4: `gitea-pr-diff` 한국어화

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-diff`
- Modify: `gitea-ops/tests/test_gitea_pr_diff.sh`

- [ ] **Step 1: Rewrite header comment**

Replace the header block (lines 2-11) of `gitea-ops/bin/gitea-pr-diff` with:

```sh
# PR 메타데이터 + unified diff을 stdout에 출력한다 (review 분석용).
#
# Usage:
#   gitea-pr-diff <PR#> [--raw|--json] [-r owner/repo] [-u URL]
#
# 기본:    사람-친화 헤더 (PR title, base, head, file list) + diff.
# --raw:   diff body만 출력.
# --json:  {title, base, head, files:[...], diff:"..."} 단일 JSON 객체.
```

Adjust sed range so `--help` does not leak `set -eu`.

- [ ] **Step 2: Update die messages**

```sh
[ "$MODE" = "json" ] && die "--raw and --json are mutually exclusive"
# →
[ "$MODE" = "json" ] && die "--raw와 --json은 동시 사용 불가"
```

```sh
[ "$MODE" = "raw" ] && die "--raw and --json are mutually exclusive"
# →
[ "$MODE" = "raw" ] && die "--raw와 --json은 동시 사용 불가"
```

```sh
die "unknown flag: $1"
# →
die "알 수 없는 flag: $1"
```

```sh
die "unexpected positional: $1"
# →
die "예기치 않은 인자: $1"
```

```sh
die "PR# required"
# →
die "PR# 인자 필요"
```

```sh
die "PR #$PR: $err_msg"
# (unchanged form — message text comes from Gitea API; the prefix "PR #N:" is unambiguous)
```

```sh
die "PR #$PR not found"
# →
die "PR #$PR 존재하지 않음"
```

```sh
die "PR #$PR files: $files_err"
# →
die "PR #$PR files: $files_err"
# (unchanged — short identifier-like; message text from Gitea)
```

- [ ] **Step 3: Update header labels in default mode**

Find the default-mode print block:

```sh
printf 'PR #%s: %s\n' "$PR" "$title"
[ -n "$url" ] && printf 'URL: %s\n' "$url"
# OR (after Task 3 carry-forward):
if [ -n "$url" ]; then printf 'URL: %s\n' "$url"; fi
printf 'Base: %s (%s)\n' "$base_ref" "$base_sha"
printf 'Head: %s (%s)\n' "$head_ref" "$head_sha"
printf 'State: %s\n' "$state"
printf 'Author: %s\n' "$author"
printf 'Files changed: %s (+%s -%s)\n' "$n_files" "$total_add" "$total_del"
```

Replace ONLY these two lines (others stay English git keywords):

```sh
printf 'Author: %s\n' "$author"
# →
printf '작성자: %s\n' "$author"
```

```sh
printf 'Files changed: %s (+%s -%s)\n' "$n_files" "$total_add" "$total_del"
# →
printf '변경 파일: %s개 (+%s -%s)\n' "$n_files" "$total_add" "$total_del"
```

`PR #N:`, `URL:`, `Base:`, `Head:`, `State:`, `--- DIFF ---` stay as-is (git/PR keywords).

- [ ] **Step 4: Update test substrings**

In `gitea-ops/tests/test_gitea_pr_diff.sh`:

```sh
assert_contains "$out" "Usage:" "--help shows usage"
# (unchanged)

assert_contains "$out" "PR#" "--help mentions PR# arg"
# (unchanged)

assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
# →
assert_file_contains "$TEST_TMP/err" "PR# 인자" "error mentions PR# requirement"

assert_file_contains "$TEST_TMP/err" "unknown" "error mentions unknown"
# →
assert_file_contains "$TEST_TMP/err" "알 수 없는 flag" "error mentions unknown flag"

assert_file_contains "$TEST_TMP/err" "mutually exclusive" "error names conflict"
# →
assert_file_contains "$TEST_TMP/err" "동시 사용 불가" "error names conflict"

assert_contains "$out" "PR #42: Add widget" "header has PR title"
# (unchanged — PR #N: prefix preserved)

assert_contains "$out" "feat/widget" "header has head ref"
# (unchanged)

assert_contains "$out" "main" "header has base ref"
# (unchanged)

assert_contains "$out" "alice" "header has author"
# (unchanged — author username)

assert_contains "$out" "src/a.go" "file list shows path"
# (unchanged)

assert_contains "$out" "+10 -3" "file list shows stats"
# (unchanged)

assert_contains "$out" "--- DIFF ---" "diff section header"
# (unchanged)

assert_contains "$out" "+new" "diff body included"
# (unchanged)

assert_contains "$out" "DIFF_BODY_42" "raw includes diff"
# (unchanged)

# In the --raw header-leak guard:
case "$out" in *"PR #42:"*) echo FAIL: header leaked into raw >&2; exit 1 ;; esac
# (unchanged — PR #N: prefix preserved)

# --json field assertions:
assert_eq "$title" "My PR" ...
assert_eq "$fpath" "f.go" ...
assert_eq "$base_ref" "main" ...
assert_eq "$head_ref" "feat" ...
assert_eq "$fstatus" "modified" ...
assert_eq "$diff_field" "diff --git a/f.go" ...
# (all unchanged — JSON field values from fixtures)

# 404 test:
assert_file_contains "$TEST_TMP/err" "999" "error mentions PR number"
# (unchanged — PR number 999 still in message)

# files-error tests:
assert_file_contains "$TEST_TMP/err" "files" "error mentions files endpoint"
# (unchanged — "files" substring still in "PR #42 files: ...")
```

- [ ] **Step 5: Run tests**

Run: `sh gitea-ops/tests/test_gitea_pr_diff.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 6: Commit**

```sh
git add gitea-ops/bin/gitea-pr-diff gitea-ops/tests/test_gitea_pr_diff.sh
git commit -m "feat(gitea-ops): gitea-pr-diff 출력/--help 한국어화 + 테스트 갱신"
```

---

## Task 5: `gitea-pr-review` 한국어화

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-review`
- Modify: `gitea-ops/tests/test_gitea_pr_review.sh`

- [ ] **Step 1: Rewrite header comment**

Replace the header block (lines 2-12) of `gitea-ops/bin/gitea-pr-review` with:

```sh
# Gitea PR에 reviewer token으로 review를 등록한다.
#
# Usage:
#   gitea-pr-review <PR#> --event <APPROVE|REQUEST_CHANGES|COMMENT>
#                          [--body "..." | --body -]
#                          [--inline FILE | --inline -]
#                          [-r owner/repo] [-u URL]
#
# --body 또는 --inline 중 하나 이상 필요 (둘 다 가능).
#
# Reviewer token은 $GITEA_REVIEWER_TOKEN env 또는 ~/.config/gitea-ops/reviewer-token 파일에서 로드.
```

Adjust sed range so `--help` does not leak `set -eu`. Run `gitea-pr-review --help 2>&1 | grep -c 'set -eu'` → expect `0`.

- [ ] **Step 2: Update die messages**

```sh
die "unknown flag: $1"
# →
die "알 수 없는 flag: $1"
```

```sh
die "unexpected positional: $1"
# →
die "예기치 않은 인자: $1"
```

```sh
die "PR# required"
# →
die "PR# 인자 필요"
```

```sh
die "--event required"
# →
die "--event 인자 필요"
```

```sh
die "invalid --event: $EVENT (use APPROVE|REQUEST_CHANGES|COMMENT)"
# →
die "--event 값 오류: $EVENT (APPROVE|REQUEST_CHANGES|COMMENT 중 선택)"
```

```sh
die "--body and --inline cannot both read stdin"
# →
die "--body와 --inline 둘 다 stdin 사용 불가"
```

```sh
die "--body required (or --body -, or --inline)"
# →
die "--body 또는 --inline 중 하나 이상 필요"
```

```sh
die "inline file not readable: $INLINE_FILE"
# →
die "inline 파일 읽을 수 없음: $INLINE_FILE"
```

```sh
die "invalid inline JSON: not an array"
# →
die "inline JSON 오류: 배열 아님"
```

```sh
die "invalid inline JSON: each item needs path, body, and new_position or old_position"
# →
die "inline JSON 오류: 각 항목에 path/body/new_position 또는 old_position 필요"
```

```sh
die "self-review not allowed: $err_msg"
# →
die "self-review 불가: $err_msg"
```

```sh
die "review failed: $err_msg"
# →
die "review 등록 실패: $err_msg"
```

- [ ] **Step 3: Update info / error message**

```sh
printf '[gitea-pr-review] unexpected response:\n%s\n' "$resp" >&2
# →
printf '[gitea-pr-review] 예기치 않은 응답:\n%s\n' "$resp" >&2
```

- [ ] **Step 4: Update test substrings**

In `gitea-ops/tests/test_gitea_pr_review.sh`:

```sh
assert_contains "$out" "Usage:" "--help shows usage"
# (unchanged)

assert_contains "$out" "--event" "--help mentions --event"
# (unchanged)

assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
# →
assert_file_contains "$TEST_TMP/err" "PR# 인자" "error mentions PR# requirement"

assert_file_contains "$TEST_TMP/err" "event" "error mentions event"
# →
assert_file_contains "$TEST_TMP/err" "--event 인자" "error mentions --event requirement"

assert_file_contains "$TEST_TMP/err" "invalid --event" "error mentions invalid event"
# →
assert_file_contains "$TEST_TMP/err" "--event 값 오류" "error mentions invalid event"

assert_file_contains "$TEST_TMP/err" "body" "error mentions body"
# →
assert_file_contains "$TEST_TMP/err" "--body 또는 --inline" "error mentions body/inline requirement"

assert_file_contains "$TEST_TMP/err" "stdin" "error mentions stdin conflict"
# →
assert_file_contains "$TEST_TMP/err" "stdin 사용 불가" "error mentions stdin conflict"

assert_file_contains "$TEST_TMP/err" "reviewer token" "error mentions reviewer token"
# (unchanged — substring still present in "reviewer token 필요 ...")

# POST shape tests use JSON-body substrings — all unchanged:
assert_contains "$body" '"event":"APPROVED"' ...
assert_contains "$body" '"body":"looks good"' ...
assert_contains "$body" '"comments"' ...
assert_contains "$body" '"a.go"' ...
assert_contains "$body" '"new_position":12' ...
assert_contains "$body" '"old_position":3' ...
assert_contains "$body" '"event":"COMMENT"' ...
assert_contains "$body" "from stdin" ...

assert_contains "$out" "review-7" "review URL printed"
# (unchanged — fixture html_url substring)

assert_contains "$out" "u" "review URL printed (matches fixture html_url)"
# (unchanged — fixture html_url substring)

assert_file_contains "$TEST_TMP/err" "inline" "error mentions inline"
# →
assert_file_contains "$TEST_TMP/err" "inline JSON 오류" "error mentions inline JSON failure"

assert_file_contains "$TEST_TMP/err" "self-review" "error mentions self-review"
# (unchanged — self-review substring still in "self-review 불가 ...")
```

- [ ] **Step 5: Run tests**

Run: `sh gitea-ops/tests/test_gitea_pr_review.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 6: Commit**

```sh
git add gitea-ops/bin/gitea-pr-review gitea-ops/tests/test_gitea_pr_review.sh
git commit -m "feat(gitea-ops): gitea-pr-review 출력/--help 한국어화 + 테스트 갱신"
```

---

## Task 6: `gitea-release` 한국어화

**Files:**
- Modify: `gitea-ops/bin/gitea-release`

- [ ] **Step 1: Rewrite header comment**

Replace the header block (lines 2-8) of `gitea-ops/bin/gitea-release` with:

```sh
# Gitea release를 생성하고 자산을 업로드한다 (자동 sha256 + minisign 옵션).
#
# Usage:
#   gitea-release <TAG> [--name TITLE] [--notes TEXT | --notes-file PATH]
#                 [--draft] [--prerelease] [--target COMMITISH]
#                 [--asset PATH]... [--sign KEYPATH]
#                 [--auto-notes] [-r owner/repo] [-u URL]
```

Note: `--auto-notes` is in the script but missing from the existing usage block. Add it. Adjust sed range so `--help` does not leak `set -eu`.

- [ ] **Step 2: Update die messages**

```sh
die "unknown flag: $1"
# →
die "알 수 없는 flag: $1"
```

```sh
die "unexpected positional: $1"
# →
die "예기치 않은 인자: $1"
```

```sh
die "TAG required"
# →
die "TAG 인자 필요"
```

```sh
die "asset missing: $asset"
# →
die "asset 파일 없음: $asset"
```

```sh
die "minisign failed for $asset"
# →
die "minisign 서명 실패: $asset"
```

- [ ] **Step 3: Update info messages**

```sh
printf '[gitea-release] warning: pulls page limit reached (50); some PRs may be missing from notes\n' >&2
# →
printf '[gitea-release] 경고: pulls 응답 50건 도달 — 일부 PR이 노트에 누락 가능\n' >&2
```

```sh
printf '[gitea-release] pushing tag %s\n' "$TAG" >&2
# →
printf '[gitea-release] tag push: %s\n' "$TAG" >&2
```

```sh
printf '[gitea-release] failed to create release:\n%s\n' "$resp" >&2
# →
printf '[gitea-release] release 생성 실패:\n%s\n' "$resp" >&2
```

```sh
printf '[gitea-release] created id=%s url=%s\n' "$rel_id" "$html_url" >&2
# →
printf '[gitea-release] release 생성 완료: id=%s url=%s\n' "$rel_id" "$html_url" >&2
```

```sh
printf '[gitea-release] upload %s\n' "$base" >&2
# →
printf '[gitea-release] asset 업로드: %s\n' "$base" >&2
```

```sh
printf '[gitea-release] upload %s\n' "$sha_name" >&2
# →
printf '[gitea-release] asset 업로드: %s\n' "$sha_name" >&2
```

```sh
printf '[gitea-release] upload %s\n' "$sig_name" >&2
# →
printf '[gitea-release] asset 업로드: %s\n' "$sig_name" >&2
```

(Three identical `upload` lines all become `asset 업로드:`.)

The `## 변경사항` header lines in `build_pr_section()` are already Korean — no change.

- [ ] **Step 4: Smoke test --help and run release tests**

Run: `gitea-ops/bin/gitea-release --help`
Expected: Korean prose header, no `set -eu` leak.

Run: `sh gitea-ops/tests/test_gitea_release_auto_notes.sh`
Expected: prints `OK`, exit 0. (Tests verify `## 변경사항` content which is unchanged.)

- [ ] **Step 5: Commit**

```sh
git add gitea-ops/bin/gitea-release
git commit -m "feat(gitea-ops): gitea-release 출력/--help 한국어화"
```

---

## Task 7: `gitea-issue` + `gitea-issue-close` 한국어화

**Files:**
- Modify: `gitea-ops/bin/gitea-issue`
- Modify: `gitea-ops/bin/gitea-issue-close`

- [ ] **Step 1: Rewrite `gitea-issue` header**

Replace lines 2-7 of `gitea-ops/bin/gitea-issue` with:

```sh
# Gitea에 issue를 생성한다.
#
# Usage:
#   gitea-issue --title "..." [--body "..."] [--label LABEL]...
#               [--assignee USER]... [--milestone ID]
#               [-r owner/repo] [-u URL]
```

Adjust sed range. Run `gitea-issue --help 2>&1 | grep -c 'set -eu'` → expect `0`.

- [ ] **Step 2: Update `gitea-issue` die / info**

```sh
die "unknown arg: $1"
# →
die "알 수 없는 인자: $1"
```

```sh
die "--title required"
# →
die "--title 인자 필요"
```

```sh
printf '[gitea-issue] failed:\n%s\n' "$resp" >&2
# →
printf '[gitea-issue] issue 작성 실패:\n%s\n' "$resp" >&2
```

```sh
printf '[gitea-issue] #%s %s\n' "$num" "$url" >&2
# →
printf '[gitea-issue] #%s 작성 완료: %s\n' "$num" "$url" >&2
```

- [ ] **Step 3: Rewrite `gitea-issue-close` header**

Replace lines 2-5 of `gitea-ops/bin/gitea-issue-close` with:

```sh
# Gitea issue를 닫는다 (선택적으로 코멘트 추가).
#
# Usage:
#   gitea-issue-close <NUMBER> [--comment "..."] [-r owner/repo] [-u URL]
```

Adjust sed range. Run `gitea-issue-close --help 2>&1 | grep -c 'set -eu'` → expect `0`.

- [ ] **Step 4: Update `gitea-issue-close` die / info**

```sh
die "unknown flag: $1"
# →
die "알 수 없는 flag: $1"
```

```sh
die "unexpected positional: $1"
# →
die "예기치 않은 인자: $1"
```

```sh
die "issue number required"
# →
die "issue number 인자 필요"
```

```sh
printf '[gitea-issue-close] failed:\n%s\n' "$resp" >&2
# →
printf '[gitea-issue-close] issue 닫기 실패:\n%s\n' "$resp" >&2
```

```sh
printf '[gitea-issue-close] #%s closed  %s\n' "$NUM" "$url" >&2
# →
printf '[gitea-issue-close] #%s 닫음: %s\n' "$NUM" "$url" >&2
```

- [ ] **Step 5: Smoke test**

```sh
gitea-ops/bin/gitea-issue --help 2>&1 | grep -c 'set -eu'        # → 0
gitea-ops/bin/gitea-issue-close --help 2>&1 | grep -c 'set -eu'  # → 0
```

No dedicated tests for these scripts. Verify the `--help` text appears in Korean.

- [ ] **Step 6: Commit**

```sh
git add gitea-ops/bin/gitea-issue gitea-ops/bin/gitea-issue-close
git commit -m "feat(gitea-ops): gitea-issue/gitea-issue-close 출력/--help 한국어화"
```

---

## Task 8: `SKILL.md` 한국어화 + 작성 규칙 섹션

**Files:**
- Modify: `gitea-ops/SKILL.md`

- [ ] **Step 1: Read current SKILL.md to understand structure**

Read `gitea-ops/SKILL.md` end-to-end. Note current section structure:
- Title `# gitea-ops` + intro paragraph
- `## When to use`
- `## Workflow`
- `## Setup`
- `## Scripts` (with `### gitea-release`, `### gitea-pr`, `### gitea-pr-diff`, `### gitea-pr-review`, `### gitea-pr-merge`, `### gitea-issue`, `### gitea-issue-close`)
- `## Error modes`
- `## After actions`

- [ ] **Step 2: Rewrite top-level intro and section headers**

Replace headers and intro prose with Korean:

```markdown
# gitea-ops

Thin wrapper around Gitea's REST API. Zero deps beyond `curl`, `jq`, `git`, and
(for release signing) `sha256sum` + `minisign`.
```
→
```markdown
# gitea-ops

Gitea REST API thin wrapper. 의존성은 `curl`, `jq`, `git`, 그리고 (release 서명용) `sha256sum` + `minisign` 뿐.
```

Section headers:
- `## When to use` → `## 사용 시점`
- `## Setup` → `## 셋업`
- `## Scripts` → `## 스크립트`
- `## Error modes` → `## 에러 처리`
- `## After actions` → `## 작업 후`

`## Workflow` stays as-is (already in current file). Sub-section headers `### gitea-release` etc. stay (they're identifiers).

- [ ] **Step 3: Rewrite section bodies**

For each section, translate the prose to Korean while preserving:
- CLI signatures (the ` ``` `-fenced usage blocks).
- Code examples, shell snippets, JSON schema, API paths.
- Technical keywords inline (PR, branch, merge, commit, etc.).
- Existing Korean text.

The section body rewrites are mechanical translations of the spec's translation conventions. Apply them by reading each prose paragraph and rewriting it in Korean while keeping the surrounding code/identifier elements intact.

For brevity, this plan does not enumerate every paragraph — the implementer reads the file, identifies prose blocks, and translates them following the conventions in the spec (`docs/superpowers/specs/2026-04-26-gitea-ops-korean-design.md`).

Specific items to verify:
- "When to use" bullet list → 한국어 산문.
- Setup items 1-4 → 한국어 (token paths, command snippets stay English).
- Each script's prose description → 한국어. Code blocks stay.
- "Error modes" table → 한국어 산문, HTTP code/path English.
- "After actions" → 한국어.

- [ ] **Step 4: Add `## 작성 규칙` section**

Append at the very end of `SKILL.md`:

```markdown
## 작성 규칙

Claude가 본 skill을 통해 PR/release/issue/review를 작성할 때 따르는 기본 규칙:

- **본문 언어**: 한국어 기본. 사용자가 영문 명시 시 영문.
- **기술 키워드**: PR/branch/merge/commit/fetch/push/pull/head/base/tag/release/review/gate/token/worktree 등은 한국어 산문 안에서 영문 inline. 번역하지 않음.
- **CLI 식별자/flag/URL**: 영문 그대로.
- **commit 메시지 / PR title**: Conventional Commits (`feat(scope): ...`, `fix(scope): ...` 등) — 영문 prefix + 한국어 본문 OK.
- **체크리스트 / 표 헤더**: 한국어.
- **Code block / API 응답 예시 / shell 명령**: 영문 그대로.
- **Co-Authored-By trailer**: 영문 자동.

이 규칙은 Claude가 본 repo 또는 Gitea remote에 PR을 만들거나 review를 등록할 때 적용. 사용자가 "영어로", "english" 등을 명시하면 우회.
```

- [ ] **Step 5: Verify markdown integrity**

Run:
```sh
awk '/^```/{c++} END{print c}' gitea-ops/SKILL.md
```
Expected: even number (every code fence has a matching close).

Read top 5 lines and tail 5 lines to spot-check formatting.

- [ ] **Step 6: Commit**

```sh
git add gitea-ops/SKILL.md
git commit -m "docs(gitea-ops): SKILL.md 한국어화 + 작성 규칙 섹션 추가"
```

---

## Task 9: 최종 통합 검증

**Files:** None (verification only)

- [ ] **Step 1: Run all 5 test files**

```sh
sh gitea-ops/tests/test_common_helpers.sh
sh gitea-ops/tests/test_gitea_pr_diff.sh
sh gitea-ops/tests/test_gitea_pr_review.sh
sh gitea-ops/tests/test_gitea_pr_merge.sh
sh gitea-ops/tests/test_gitea_release_auto_notes.sh
```
Expected: each prints `OK`, exit 0.

- [ ] **Step 2: Smoke test all `--help` outputs**

```sh
for s in gitea-pr gitea-pr-merge gitea-pr-diff gitea-pr-review gitea-release gitea-issue gitea-issue-close; do
    echo "=== $s --help ==="
    gitea-ops/bin/$s --help 2>&1
    echo "leaked set -eu: $(gitea-ops/bin/$s --help 2>&1 | grep -c 'set -eu')"
    echo
done
```

For each: `leaked set -eu: 0`. Each header is Korean prose with English signature.

- [ ] **Step 3: Spot-check a sample script run**

```sh
gitea-ops/bin/gitea-pr-merge 2>&1 | head -2
```
Expected output: `gitea-ops: PR# 인자 필요` (proves die message localized).

```sh
gitea-ops/bin/gitea-pr-diff 99999 --raw --json 2>&1 | head -2
```
Expected output: `gitea-ops: --raw와 --json은 동시 사용 불가`.

- [ ] **Step 4: SKILL.md sanity**

```sh
awk '/^```/{c++} END{print c}' gitea-ops/SKILL.md   # → even
grep -c '## 작성 규칙' gitea-ops/SKILL.md           # → 1
```

- [ ] **Step 5: Commit if anything was tweaked**

If you found and fixed any minor issue during integration:
```sh
git add -u
git commit -m "chore(gitea-ops): integration cleanup"
```
Otherwise skip.

---

## Self-Review Notes

Spec coverage check:

- **Architecture (Section: Architecture & Scope)** — Tasks 1-7 cover the 7 scripts + _common.sh; Task 8 covers SKILL.md + 작성 규칙 섹션. ✓
- **Translation Conventions (Section: Translation Conventions)** — applied per-task with literal substitution tables. ✓
- **Header label changes (gitea-pr-diff)** — Task 4 Step 3 covers Author / Files changed → 작성자 / 변경 파일. Other labels deliberately unchanged. ✓
- **Test substring updates** — distributed across Tasks 3, 4, 5; covered every test file that asserts on script output. ✓
- **Migration / Rollout** — 8 commits, each self-contained; Task 9 final integration. ✓
- **신규 작성 규칙 섹션** — Task 8 Step 4. ✓

Placeholder scan: no "TBD"/"TODO"/"add appropriate". Task 8 Step 3 says "translate paragraph by paragraph following spec conventions" — this is a deliberate delegation to the implementer because the SKILL.md prose is English running text best translated by reading inline, not by pre-listing every sentence. The conventions and section-by-section guidance are precise enough.

Type consistency: `[gitea-pr-merge]` prefix, `--force`, `--event`, `gitea-ops:` die prefix all consistent across tasks. Korean substrings used in test asserts (`PR# 인자`, `알 수 없는 flag`, `머지 완료`, `이미 머지됨`, `현재 head branch 아님`, `self-removal 거부`, `APPROVED review 없음`, `--event 인자`, `--event 값 오류`, `inline JSON 오류`, `stdin 사용 불가`, `--body 또는 --inline`) all match the corresponding die/printf strings.
