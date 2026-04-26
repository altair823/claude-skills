# gitea-ops: 출력/문서/생성 본문 한국어화

**Date:** 2026-04-26
**Status:** Draft

## Goal

`gitea-ops` 스킬 전반을 한국어로 개선한다. 대상은 (a) 모든 script의 사용자 출력과 `die` 메시지, (b) `--help` 헤더, (c) `SKILL.md` 본문 전체, (d) Claude가 본 스킬을 통해 PR/review/issue 본문을 작성할 때의 기본 언어 규칙. 모든 변경은 단일 PR로 들어가 일관성을 즉시 확보한다.

## Non-Goals

- Plan 문서 한국어화. (별개 작업; 본 PR 범위 아님)
- 코드 식별자 (변수명, 함수명) 변경.
- 코드 내부 주석 한국어화. (영문 유지)
- Curl/API 호출 contents 변경. (Gitea API 변경 없음)
- 외부 도구 호환성 변경. (CLI signature, exit code, fixture format 무변경)
- 사용자가 직접 작성하는 PR/review body의 언어 강제. (Claude 생성물에만 적용)

## Architecture

세 가지 변경 축:

1. **Script 한국어화** — 7개 script (`gitea-pr`, `gitea-pr-merge`, `gitea-pr-diff`, `gitea-pr-review`, `gitea-release`, `gitea-issue`, `gitea-issue-close`) 및 공통 helper `_common.sh`의 사용자 출력과 `die` 메시지를 한국어화. `--help` 헤더 주석도 한국어 산문으로 변환 (단 Usage signature는 영문 그대로).

2. **SKILL.md 한국어화** — 섹션 헤더와 산문 모두 한국어. CLI signature / API path / shell 명령 / JSON schema 등 code 성격 영역은 영문 그대로. 신규 `## 작성 규칙` 섹션 추가하여 Claude의 PR/review/issue body 기본 언어 규칙 명시.

3. **Test 갱신** — 5개 test 파일의 `assert_contains`/`assert_file_contains` substring을 한국어로 갱신. Assert description (3번째 인자)은 영문 유지.

### 보존 규칙

한국어 산문 안에서 다음은 영문 inline으로 보존:

- **CLI 식별자**: 스크립트 이름 (`gitea-pr-merge`), flag (`--force`, `--event`), `[gitea-pr-merge]` prefix.
- **기술 키워드**: PR, branch, merge, commit, fetch, push, pull, head, base, tag, release, review, gate, token, worktree, JSON, API, stdin, stdout.
- **Code/명령/경로/URL/JSON schema**: 그대로.
- **Conventional Commits prefix** (`feat(scope):`, `fix(scope):` 등): 영문 prefix + 한국어 본문 가능.

## Components

### Script 사용자 출력 — 변환 표

#### `gitea-pr-merge` info 메시지

| 영문 (현재) | 한국어 (변환 후) |
|---|---|
| `[gitea-pr-merge] PR #42 merged (merge, branch feat/x)` | `[gitea-pr-merge] PR #42 머지 완료 (방식: merge, head: feat/x)` |
| `[gitea-pr-merge] PR #42 already merged — skipping merge call` | `[gitea-pr-merge] PR #42 이미 머지됨 — merge 호출 스킵` |
| `[gitea-pr-merge] deleted remote branch feat/x` | `[gitea-pr-merge] 원격 branch 삭제: feat/x` |
| `[gitea-pr-merge] warning: could not delete remote branch feat/x` | `[gitea-pr-merge] 경고: 원격 branch 삭제 실패: feat/x` |
| `[gitea-pr-merge] not in a git work tree; skipping branch delete` | `[gitea-pr-merge] git work tree 아님 — branch 삭제 스킵` |
| `[gitea-pr-merge] not on head branch (main != feat/x); skipping worktree cleanup` | `[gitea-pr-merge] 현재 head branch 아님 (main != feat/x) — worktree 정리 스킵` |
| `[gitea-pr-merge] cwd is the main worktree; refusing self-removal` | `[gitea-pr-merge] cwd가 main worktree임 — self-removal 거부` |
| `[gitea-pr-merge] removed worktree /tmp/wt/x` | `[gitea-pr-merge] worktree 정리: /tmp/wt/x` |
| `[gitea-pr-merge] cleanup aborted mid-sequence — worktree X not removed` | `[gitea-pr-merge] cleanup 중단됨 — worktree 미정리: X` |
| `[gitea-pr-merge] warning: reviews list >= 50; pagination not implemented, gate may misfire` | `[gitea-pr-merge] 경고: reviews 응답 ≥ 50건 — pagination 미구현, gate 오작동 가능` |

#### `gitea-pr-merge` die 메시지

| 영문 | 한국어 |
|---|---|
| `PR# required` | `PR# 인자 필요` |
| `invalid --method: X (use merge\|squash\|rebase)` | `--method 값 오류: X (merge\|squash\|rebase 중 선택)` |
| `unknown flag: --bogus` | `알 수 없는 flag: --bogus` |
| `unexpected positional: foo` | `예기치 않은 인자: foo` |
| `PR #42 not found or missing head.ref` | `PR #42 존재하지 않거나 head.ref 누락` |
| `merge failed: ...` | `merge 실패: ...` |
| `failed to fetch reviews: ...` | `reviews 조회 실패: ...` |
| `no APPROVED review on PR #42; use --force to override` | `PR #42에 APPROVED review 없음 — --force로 우회 가능` |
| `could not determine main worktree` | `main worktree 식별 실패` |
| `cannot cd to main worktree: X` | `main worktree로 cd 실패: X` |

#### `gitea-pr` info / die

| 영문 | 한국어 |
|---|---|
| `[gitea-pr] pushing branch feat/x` | `[gitea-pr] branch push: feat/x` |
| `[gitea-pr] #42 https://...` | `[gitea-pr] #42 작성 완료: https://...` |
| `[gitea-pr] failed:\n<resp>` | `[gitea-pr] PR 작성 실패:\n<resp>` |
| `--title required` | `--title 인자 필요` |
| `--head required` | `--head 인자 필요` |
| `unknown arg: X` | `알 수 없는 인자: X` |

#### `gitea-pr-diff`

| 영문 | 한국어 |
|---|---|
| `PR #42: <title>` | `PR #42: <title>` (그대로) |
| `URL: ...` | `URL: ...` (그대로) |
| `Base: main (def5678)` | `Base: main (def5678)` (그대로 — git 키워드) |
| `Head: feat/x (abc1234)` | `Head: feat/x (abc1234)` (그대로) |
| `State: open` | `State: open` (그대로) |
| `Author: alice` | `작성자: alice` |
| `Files changed: 12 (+100 -20)` | `변경 파일: 12개 (+100 -20)` |
| `--- DIFF ---` | `--- DIFF ---` (그대로) |
| `PR# required` | `PR# 인자 필요` |
| `--raw and --json are mutually exclusive` | `--raw와 --json은 동시 사용 불가` |
| `unknown flag: ...` | `알 수 없는 flag: ...` |
| `unexpected positional: ...` | `예기치 않은 인자: ...` |
| `PR #42: <gitea message>` | `PR #42: <gitea message>` (그대로 — Gitea 응답) |
| `PR #42 not found` | `PR #42 존재하지 않음` |
| `PR #42 files: <message>` | `PR #42 files: <message>` (그대로) |

#### `gitea-pr-review`

| 영문 | 한국어 |
|---|---|
| `PR# required` | `PR# 인자 필요` |
| `--event required` | `--event 인자 필요` |
| `invalid --event: X (use APPROVE\|REQUEST_CHANGES\|COMMENT)` | `--event 값 오류: X (APPROVE\|REQUEST_CHANGES\|COMMENT 중 선택)` |
| `--body and --inline cannot both read stdin` | `--body와 --inline 둘 다 stdin 사용 불가` |
| `--body required (or --body -, or --inline)` | `--body 또는 --inline 중 하나 이상 필요` |
| `inline file not readable: X` | `inline 파일 읽을 수 없음: X` |
| `invalid inline JSON: not an array` | `inline JSON 오류: 배열 아님` |
| `invalid inline JSON: each item needs path, body, and new_position or old_position` | `inline JSON 오류: 각 항목에 path/body/new_position 또는 old_position 필요` |
| `self-review not allowed: ...` | `self-review 불가: ...` |
| `review failed: ...` | `review 등록 실패: ...` |
| `[gitea-pr-review] unexpected response:\n<resp>` | `[gitea-pr-review] 예기치 않은 응답:\n<resp>` |

#### `gitea-release` / `gitea-issue` / `gitea-issue-close`

(상세 표 생략; 동일 원칙 적용 — info는 한국어, signature/flag/path 영문 보존)

핵심:
- `[gitea-release] tag X already on remote` → `[gitea-release] tag X 이미 remote에 존재`
- `[gitea-release] release created: <url>` → `[gitea-release] release 생성 완료: <url>`
- `[gitea-issue] #N <url>` → `[gitea-issue] #N 작성 완료: <url>`
- `[gitea-issue-close] closed #N` → `[gitea-issue-close] #N 닫음`

#### `_common.sh` die 메시지

| 영문 | 한국어 |
|---|---|
| `gitea-ops: <msg>` | `gitea-ops: <msg>` (prefix 그대로, 본문만 한국어) |
| `no token (set GITEA_TOKEN or write ~/.config/gitea-ops/token)` | `token 필요 (GITEA_TOKEN env 또는 ~/.config/gitea-ops/token 파일)` |
| `cannot parse remote URL: ...` | `remote URL 파싱 실패: ...` |
| `no GITEA_URL (set --url, GITEA_URL, or config)` | `GITEA_URL 미설정 (--url / GITEA_URL env / config 파일 중 하나 필요)` |
| `no GITEA_REPO (set --repo, GITEA_REPO, or config)` | `GITEA_REPO 미설정 (--repo / GITEA_REPO env / config 파일 중 하나 필요)` |
| `missing command: jq` | `필수 명령 없음: jq` |
| `reviewer token required (set GITEA_REVIEWER_TOKEN or write ~/.config/gitea-ops/reviewer-token)` | `reviewer token 필요 (GITEA_REVIEWER_TOKEN env 또는 ~/.config/gitea-ops/reviewer-token 파일)` |

### `--help` 헤더 주석

각 script 상단의 주석 블록 (sed -n 'N,Mp' "$0" 으로 출력되는 영역). 산문은 한국어, Usage signature line은 영문 그대로. 변환 후 `--help` 출력에 `set -eu` 누출 없도록 sed 범위 재확인.

예시 (`gitea-pr-merge`):

```sh
#!/bin/sh
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

### `SKILL.md` 한국어화

섹션 헤더 매핑:

| 현재 | 변환 후 |
|---|---|
| `## When to use` | `## 사용 시점` |
| `## Workflow` | `## 워크플로` |
| `## Setup` | `## 셋업` |
| `## Scripts` | `## 스크립트` |
| `## Error modes` | `## 에러 처리` |
| `## After actions` | `## 작업 후` |
| `### gitea-release` 외 script subsection | 그대로 (식별자) |

각 섹션 본문 산문 한국어. CLI signature, code block, shell 명령, JSON schema는 영문 그대로.

신규 섹션 (파일 끝):

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

### Test 갱신

5개 test 파일 (`test_common_helpers.sh`, `test_gitea_pr_diff.sh`, `test_gitea_pr_review.sh`, `test_gitea_pr_merge.sh`, `test_gitea_release_auto_notes.sh`)의 모든 `assert_contains`/`assert_file_contains` substring 인자를 한국어 변환 표에 맞춰 갱신.

기본 패턴:

```sh
# 전:
assert_contains "$out" "merged" "success message mentions merged"
# 후:
assert_contains "$out" "머지 완료" "success message mentions merged"
```

Assert description (3번째 인자) — 영문 유지 (테스트 코드 내부 식별자 성격).

substring 선택 시 주의: 다른 메시지와 의도치 않게 매칭되지 않도록 충분히 구체적으로. 예: `"PR"` → `"PR#"` 또는 `"PR# 인자"`.

## Data Flow

기존 호출 흐름 무변경. 사용자가 `gitea-pr-merge 8` 실행 → 동일하게 API 호출 / 머지 / cleanup 수행. 출력 텍스트만 한국어로 표시.

Claude 작성 흐름 (신규):
- 사용자가 "PR 만들어" / "리뷰해" 요청.
- Claude는 SKILL.md `작성 규칙` 섹션 따름 → PR title (Conventional Commits prefix + 한국어), body (한국어 산문 + 영문 기술 키워드).
- `gitea-pr` / `gitea-pr-review` 명령어 실행.

## Error Handling

| 상황 | 동작 |
|---|---|
| 한국어 메시지에서 substring assert 못 잡음 | Test 갱신 단계에서 즉시 발견 — 같은 commit 안에서 substring 더 구체화 |
| `--help` 헤더 길이 변동으로 sed 범위 안 맞음 | `--help` 실행해 `set -eu` 누출 확인 + 빈 라인 / `set -eu` 라인 포함 여부 확인 |
| SKILL.md code fence 불균형 | 변환 후 `awk '/^```/{c++} END{print c}'`로 짝수 확인 |
| 한국어 텍스트의 EUC-KR 비호환 글자 | 본 변경은 화면 출력만; UTF-8 사용. paperboy의 EUC-KR 제약과 무관. |

## Testing

### Test 갱신 외 검증

1. **각 script `--help` 실행** — 한국어 헤더 출력 + `set -eu` 누출 없음 + Usage line 영문 유지.
2. **5개 test 파일 green** — 갱신된 substring으로 모두 통과.
3. **SKILL.md markdown 검증** — code fence 짝수, 헤더 nesting OK.
4. **수동 smoke test** — `gitea-pr-merge --help`, `gitea-pr-diff 8 | head -10`, `gitea-pr --help` 등 직접 실행해 한국어 출력 확인.

### 새 Test 케이스

별도 추가 없음. 기존 테스트의 substring만 갱신. 한국어 substring이 매칭되면 전체 메시지가 한국어임이 충분히 확인됨.

## Migration / Rollout

### Commit 분할

단일 PR. Commit 단위로 분리:

1. `feat(gitea-ops): _common.sh die 메시지 한국어화 + 테스트 갱신`
2. `feat(gitea-ops): gitea-pr 출력/--help 한국어화 + 테스트 갱신` (gitea-pr는 dedicated test 없음 — _common 또는 통합 테스트로 검증)
3. `feat(gitea-ops): gitea-pr-merge 출력/--help 한국어화 + 테스트 갱신`
4. `feat(gitea-ops): gitea-pr-diff 출력/--help 한국어화 + 테스트 갱신`
5. `feat(gitea-ops): gitea-pr-review 출력/--help 한국어화 + 테스트 갱신`
6. `feat(gitea-ops): gitea-release 출력/--help 한국어화 + 테스트 갱신`
7. `feat(gitea-ops): gitea-issue/gitea-issue-close 출력/--help 한국어화`
8. `docs(gitea-ops): SKILL.md 한국어화 + 작성 규칙 섹션 추가`

각 commit이 self-contained — 변경된 script + 그 script의 테스트가 같이 들어가 항상 green.

### Rollout

- PR 1개 (본 spec과 동일한 새 feature branch).
- Reviewer-token 사용해 dogfood (review gate 통과 확인).
- Breaking change 없음. CLI signature / exit code / fixture format 무변경.
- 사용자가 영문 출력을 grep하는 외부 스크립트가 있다면 깨질 수 있음 — 개인 repo 사용자에게 직접 확인.

### 후속

- Plan 문서 한국어화는 별개 작업으로 보류.
- 기존 영문 커밋 / PR description retroactive 변환 안 함.
