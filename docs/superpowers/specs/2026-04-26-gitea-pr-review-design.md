# gitea-ops: PR Review Step Between Create and Merge

**Date:** 2026-04-26
**Status:** Draft

## Goal

`gitea-ops`에 PR 리뷰 단계를 추가한다. 흐름은
`gitea-pr (생성) → gitea-pr-diff + gitea-pr-review (리뷰) → gitea-pr-merge (게이트 통과 시 머지)`.
리뷰는 사람이 아니라 Claude 세션이 수행하며, PR 작성자와 분리된 reviewer 토큰을 사용한다.

## Non-Goals

- GitHub/GitLab 호환.
- 사람-루프 코드 리뷰 워크플로 (예: 코멘트 스레드 응답, resolve UI).
- Stale review 자동 검증 (Gitea 저장소 설정의 "Dismiss stale reviews"로 위임).
- 50건을 넘는 reviews pagination 정확 처리 (paperboy-ops 패턴과 동일하게 경고만).
- Reviewer-token 자동 발급/회전.

## Architecture

세 가지 변경:

1. **신규 `gitea-pr-diff`** — PR 번호로 메타와 diff를 stdout에 출력. Claude가 이 출력을 읽고 분석한다.
2. **신규 `gitea-pr-review`** — reviewer-token을 사용해 review를 POST. 기본은 summary body + inline comments, summary-only는 flag.
3. **`gitea-pr-merge` 수정** — merge 호출 직전 review 게이트 추가. APPROVED 리뷰가 1건 이상 없으면 거부, `--force`로 우회.

### Token 분리

- `~/.config/gitea-ops/token` 또는 `GITEA_TOKEN` — 기존. PR/release/issue/merge 작성용 (PR author 계정).
- `~/.config/gitea-ops/reviewer-token` 또는 `GITEA_REVIEWER_TOKEN` — 신규. review POST 전용 (다른 계정 PAT, repo write 권한).
- `gitea-pr-review`만 reviewer-token을 사용한다. 다른 모든 스크립트는 기존 token을 그대로 쓴다.
- `_common.sh`에 `load_reviewer_token()` 추가 (`load_token()` 미러). 토큰 부재 시 즉시 `die`.

### Setup 변경

`SKILL.md`의 Setup 섹션에 단계 추가:

> 4. Reviewer Personal Access Token (별도 계정): scopes **repository** (write).
>    저장: `~/.config/gitea-ops/reviewer-token` (mode 0600) 또는 `GITEA_REVIEWER_TOKEN` env.

스킬 설치 시 빈 placeholder 파일을 생성한다 (`touch ~/.config/gitea-ops/reviewer-token && chmod 600`). 사용자가 토큰 문자열을 채워 넣는다. 채워지지 않은 상태에서 `gitea-pr-review`를 호출하면 명확한 안내로 실패한다.

## Components

### `gitea-pr-diff`

```
gitea-pr-diff <PR#> [--raw|--json] [-r owner/repo] [-u URL]
```

기본 출력 (meta + diff):

```
PR #42: <title>
URL: <html_url>
Base: main (<base_sha>)
Head: <head_ref> (<head_sha>)
State: open|closed|merged
Author: <user>
Files changed: <N> (+<add> -<del>)
  M  path/a.go        (+10 -3)
  A  path/b.sh        (+50 -0)
  D  path/c.md        (+0 -20)

--- DIFF ---
<unified diff>
```

API 호출:
- `GET /repos/{repo}/pulls/{n}` — meta
- `GET /repos/{repo}/pulls/{n}/files` — file list with stats
- `GET /repos/{repo}/pulls/{n}.diff` — raw unified diff

Flags:
- `--raw` — diff body만 출력 (헤더/메타 없음).
- `--json` — `{title, base, head, files:[{path,status,additions,deletions}], diff}` JSON 한 덩어리.
- `--raw`와 `--json` 동시 사용은 거부.

### `gitea-pr-review`

```
gitea-pr-review <PR#> --event <APPROVE|REQUEST_CHANGES|COMMENT>
                      --body "..." | --body -
                      [--inline FILE | --inline -]
                      [-r owner/repo] [-u URL]
```

- reviewer-token 강제. 부재 시 die: `"reviewer token required (~/.config/gitea-ops/reviewer-token or GITEA_REVIEWER_TOKEN)"`.
- `--body -`, `--inline -`: stdin 입력. 둘 다 stdin은 금지.
- `--inline FILE`: JSON 배열, 각 항목은 다음 필드를 가진다:
  - `path` (string, 필수) — 파일 경로
  - `body` (string, 필수) — 코멘트 본문
  - `new_position` (integer) 또는 `old_position` (integer) — 둘 중 하나 필수
  ```json
  [{"path":"file.go","new_position":42,"body":"..."},
   {"path":"old.sh","old_position":10,"body":"..."}]
  ```
  스크립트는 jq로 각 항목을 검증하고, 누락된 필드가 있으면 die.
- `--event` 매핑:
  - `APPROVE` → API `"event":"APPROVED"`
  - `REQUEST_CHANGES` → `"event":"REQUEST_CHANGES"`
  - `COMMENT` → `"event":"COMMENT"`
- POST body 형태:
  ```json
  {"event":"APPROVED","body":"...","comments":[ ... ]}
  ```
  `comments`는 inline 미지정 시 생략.
- `POST /repos/{repo}/pulls/{n}/reviews` — Authorization 헤더는 reviewer-token.
- 성공 시 응답에서 review HTML URL stdout.

### `gitea-pr-merge` 수정

merge 호출 직전 게이트 단계:

1. `GET /repos/{repo}/pulls/{n}/reviews` (기존 token, 읽기만).
2. `jq '[.[] | select(.state=="APPROVED" and .dismissed==false)] | length'` 결과 ≥ 1 확인.
3. 0이면 die: `"no APPROVED review on PR #<n>; use --force to override"`.

신규 flag:
- `--force` — 게이트 스킵. 기존 머지 동작.

기존 동작 (브랜치 삭제, 워크트리 정리)은 변경 없음.

## Data Flow

```
1. PR 작성자 (token):
     gitea-pr --title ... --head feat/x
     → PR #42 생성, URL 반환

2. Claude 리뷰어 세션 (reviewer-token):
     gitea-pr-diff 42
     → meta+diff stdout, Claude가 읽고 분석

     gitea-pr-review 42 --event APPROVE \
       --body "Approved. Logic sound." \
       --inline /tmp/review-42.json
     → POST, review URL 반환

3. PR 작성자 또는 자동화 (token):
     gitea-pr-merge 42
     → GET /reviews 확인 → APPROVED ≥ 1 → 머지 진행
        (없으면 거부; --force로 우회)
```

Inline JSON은 Claude가 diff 분석 후 직접 작성해 임시 파일에 저장한 뒤 `--inline FILE`에 전달하거나, heredoc으로 `--inline -`에 파이프한다.

## Error Handling

| 상황 | 동작 |
|------|------|
| reviewer-token 파일/env 둘 다 없음 | `gitea-pr-review` 즉시 die: 안내 메시지 |
| reviewer-token 401 | die: `"reviewer token invalid"` |
| reviewer-token 403 | die: `"reviewer token lacks repo write scope"` |
| 422 self-review (author=reviewer) | die: `"self-review not allowed; reviewer-token belongs to PR author"` |
| `--body`, `--inline` 둘 다 stdin 지정 | die: `"--body and --inline cannot both read stdin"` |
| `--inline FILE` JSON parse 실패 | die: `"invalid inline JSON: <jq error>"` |
| `--event` 값 invalid | die: `"invalid --event (use APPROVE\|REQUEST_CHANGES\|COMMENT)"` |
| `gitea-pr-diff` PR# 404 | die: `"PR #<n> not found"` |
| `gitea-pr-diff` `--raw`와 `--json` 동시 | die: `"--raw and --json are mutually exclusive"` |
| `gitea-pr-merge` review 0건 | die: `"no APPROVED review on PR #<n>; use --force to override"` |
| `gitea-pr-merge` reviews API 실패 (네트워크/HTTP) | die: `"failed to fetch reviews: <curl error>"`. 게이트 우회 안 함; 사용자가 `--force`를 명시해야 진행 |
| reviews 응답 길이 ≥ 50 | warn (stderr): `"reviews list >= 50; pagination not implemented, gate may misfire"` (paperboy-ops와 동일 패턴) |

기존 helper (`die`, `require_cmd`, `resolve_remote`, `api_json`, `gitea_get`)를 재사용한다.

## Testing

기존 test harness (curl stub + fixtures, `tests/lib.sh`)를 그대로 사용. 신규 테스트 파일 3개와 기존 1개 확장:

### `tests/test_gitea_pr_diff.sh` (신규)

- 기본 mode: `GET /pulls/42`, `GET /pulls/42/files`, `GET /pulls/42.diff` 호출 검증 (call log).
- 출력에 PR title, head_ref, file list, diff 본문 포함 확인.
- `--raw`: diff body만 출력.
- `--json`: jq parse 가능 + `title`/`base`/`head`/`files`/`diff` 필드 존재 확인.
- `--raw`와 `--json` 동시 → die.
- 404 fixture → 명확 메시지로 die.

### `tests/test_gitea_pr_review.sh` (신규)

- reviewer-token 파일을 sandbox 안에 생성 (`$TEST_TMP/reviewer-token`). `lib.sh`에 `GITEA_REVIEWER_TOKEN_FILE` override hook 추가.
- `--event APPROVE --body "ok"` → POST body가 `{"event":"APPROVED","body":"ok"}` 인지 call log로 검증.
- `--inline FILE` → POST body에 `comments[]` 포함 확인.
- `--body -` stdin 수용.
- reviewer-token 없으면 die.
- `--body -` + `--inline -` 동시 → die.
- invalid `--event` → die.
- 422 self-review fixture → 명확 메시지로 die.

### `tests/test_gitea_pr_merge.sh` (확장)

기존 케이스 그대로 보존. 신규 케이스 추가:

- APPROVED 1+ fixture → merge POST 호출됨, 정상 흐름.
- Reviews 빈 배열 fixture → die `"no APPROVED review"`, merge POST 호출 안 됨 (`call_count`로 검증).
- `--force` → reviews API 호출 자체 스킵 (call log에서 GET reviews 부재 확인), 머지 진행.
- APPROVED 있지만 `dismissed=true` → reject.
- reviews 응답 본문이 비어 있거나 잘못된 JSON → die.

### `tests/test_common_helpers.sh` (확장)

- `load_reviewer_token()`: env 우선, 파일 fallback, 둘 다 없으면 die.

## Migration / Rollout

- 신규 스크립트 두 개와 `gitea-pr-merge` 게이트는 동일 PR로 머지.
- `--force` flag는 기존 사용자가 reviewer-token을 설정하지 않은 상태에서 즉시 머지를 막지 않도록 escape hatch 역할.
- `SKILL.md`에 새 워크플로 예시와 reviewer-token 설정 안내를 같이 갱신.
- 기존 `~/.config/gitea-ops/config`, `token` 파일 형식은 변경 없음.
