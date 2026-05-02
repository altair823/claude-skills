---
name: gitea-ops
description: Drive Gitea via REST API from the CLI — create releases with minisign/sha256 assets, open PRs, file/close issues, and mirror Gitea repos to GitHub (gh CLI). Use when the user asks to cut a release, open a PR, file/close an issue, or set up/control a Gitea→GitHub push mirror. Auto-detects host + repo from the current git remote.
---

# gitea-ops

Gitea REST API thin wrapper, [`tea` CLI](https://gitea.com/gitea/tea) 위에 구성. 의존성: `tea` (>= 0.14), `jq`, `git`. release 서명용 추가: `sha256sum`, `minisign`. 모든 인증·host 자동 감지·multi-byte UTF-8 송신은 tea 가 처리 — curl 직호출 없음.

## 사용 시점

- tag release + binary asset (sha256/minisign)
- PR 작성, issue 작성/닫기, PR/issue bulk 조회
- Gitea repo 를 GitHub 으로 mirror (push mirror 등록 + 일회성 push) — `## GitHub Mirror` 절 참조

직접적인 GitHub/GitLab API 작업에는 사용 금지 (API 다름). Gitea→GitHub mirror 는 본 skill 의 mirror 절이 담당.

## Workflow

```sh
# 1. 작성자가 PR 생성
gitea-pr --title "위젯 추가" --head feat/widget

# 2. 리뷰어 (별도 Claude 세션, reviewer-token):
gitea-pr-diff 42                    # 분석용 meta+diff dump
gitea-pr-review 42 --event APPROVE \
    --body "전반적으로 로직이 타당하고 회귀 위험이 보이지 않아 머지에 동의합니다."

# 3. 사람이 Gitea UI에서 머지 (Claude 자동 머지 안 함). "Delete branch after merge"
#    체크 + 로컬 worktree 는 `git worktree remove <path>` 로 정리.
```

리뷰 결과가 문제 없을 때도 **APPROVE 코멘트는 반드시 등록** — 사람이 머지 결정 시 명시적 승인 신호가 필요하기 때문.

## PR 생성 전 선택지: 리뷰 루프

`gitea-pr`로 PR을 만들기 직전, Claude는 사용자에게 다음 두 가지 모드 중 어느 것으로 진행할지 **반드시 묻고 답을 받는다**. 사용자 응답 없이 임의로 결정하지 않는다.

1. **단발 (기본)** — PR을 만들고 종료. 리뷰는 사용자가 필요할 때 별도로 요청한다.
2. **리뷰 루프** — PR을 만든 직후 Claude가 자동으로 셀프 리뷰를 돌리고, 리뷰가 actionable한 지적이나 권장 사항을 담고 있으면 그 내용을 후속 커밋으로 반영한 뒤 다시 리뷰한다. 모든 actionable 코멘트가 해소되고 `event=APPROVE`만 남을 때까지 반복.

### Entry-gate

리뷰 루프 1회차 `gitea-pr-diff` 호출 전 통과 필수. 실패 시 진입 거부 + 누락 항목 보고. `gitea-pr-status <PR#> --wait-ci` 한 번으로 점검.

#### 필수 항목 (항상)
- `title` 비어있지 않음
- `body` 비어있지 않음
- `changed_files > 0`
- `draft == false`
- `base` / `head` branch 존재

#### CI 항목 (조건부)
PR head SHA combined status 조회. `total_count==0` (CI 없음) → skip. `success` → 통과, `failure`/`error` → 거부, `pending` → 30초 간격 최대 20분 polling. 20분 timeout 시 **자동 실패 처리 안 함** — 사용자에게 결정 위임 (`gitea-pr-status` exit 3).

### 루프 한 회차 동작

회차 1 진입 전 [Entry-gate](#entry-gate) 통과 필수. 매 회차마다 (1)~(4) **모두** 수행 — 특히 (2) 의 `gitea-pr-review` 생략하면 회차가 아니라 단순 후속 작업.

1. `gitea-pr-diff <PR#>`로 현재 PR diff을 dump.
2. 리뷰어 관점에서 분석 후 `gitea-pr-review` **반드시 호출** — 매 회차에 새로운 review를 한 건씩 PR에 등록해야 한다.
   - actionable 한 지적이 **하나라도** 있으면 `--event REQUEST_CHANGES` + 해당 inline 코멘트. 명백한 결함·의도 불명확·누락·권장 개선뿐 아니라 **사소한 nit/cosmetic (코드: 오타, 명명 미세 조정, 불필요한 빈 줄, 사소한 가독성 개선; prose: 어색한 표현, 모호한 어휘, 표기 일관성) 도 포함**한다. nit 이라고 APPROVE 로 묻어 두지 않는다 — 회차 한 번 더 도는 비용보다 누락된 cleanup 이 머지 후 별도 PR 로 이어지는 비용이 더 크다.
   - actionable 한 지적이 0건이고 칭찬·수긍 코멘트만 남으면 `--event APPROVE`.
   - summary body 첫 줄에 `회차 N` prefix를 붙여 timeline에서 회차를 식별 가능하게 한다 (예: `회차 2 — 회차 1 지적 모두 반영. 추가 권장 1건.`).
3. **종료 조건**: 방금 등록한 review의 `event=APPROVE` 이고 inline 코멘트에 issue/suggestion 카테고리가 0개 (칭찬만 있음). 이때 루프 종료.
4. 종료 조건 미충족: inline 코멘트와 summary를 토대로 코드/문서를 수정 → 새 커밋 → push → 다음 회차의 (1) 로 진입.

> **참고**: 회차마다 `gitea-pr-review` 등록 필수. Gitea 는 commit push 시 이전 review 를 자동 dismiss 하지 않고 "Outdated" 배지만 붙임 (`dismiss_stale_approvals` 켠 환경 예외). "APPROVE 하나만 보임"은 회차 누락 신호 — UI 에서 사라진 게 아님.

### 머지 안내

리뷰 루프가 APPROVE 로 종료된 직후 사용자에게 "이제 사용자가 Gitea UI 에서 머지" 라고 안내할 때 **반드시 해당 PR URL 을 포함**한다 (예: `https://gitea.example/owner/repo/pulls/N`). 사용자가 한 클릭으로 머지 화면에 이동할 수 있어야 함 — URL 없이 "머지하세요" 만 보내면 사용자가 PR 번호를 다시 찾아야 한다.

**PR URL 확보 방법 (권장 순)**:

1. `gitea-pr` 생성 직후 출력된 PR URL 을 caller 가 보존했다가 머지 안내 시 재사용. 가장 견고 — review URL 형식이 바뀌어도 영향 없음.
2. 보존이 어려우면 `gitea-pr-review` 출력 (`https://host/owner/repo/pulls/N#issuecomment-XXX`) 에서 `#` 앞까지 잘라내 PR URL 로 사용.

### 가드

- **최대 회차 5회**. 5회차 이후에도 actionable 코멘트가 남으면 루프를 강제 종료하고 사용자에게 결과를 보고한다 — 무한 회전 방지.
- **수정 거부 옵션**: 리뷰 코멘트의 rationale에 동의하지 못하는 경우 (의도된 단순화 등) Claude는 반영 대신 사유를 사용자에게 보고하고 결정을 위임한다. 자기가 단 리뷰를 무비판적으로 따르지 않는다.
- **수렴 실패 감지**: 동일한 inline 코멘트가 두 회차 연속 같은 위치에 다시 등장하면 그 자체로 강제 종료 신호 — 회차를 더 돌려도 풀리지 않는다는 뜻이므로 사용자에게 보고하고 멈춘다.

## 환경 사전 점검

토큰 첫 사용 전: 의존성 (`tea jq git`, release 서명이면 `minisign sha256sum` 추가) + 토큰 파일 UTF-8 no BOM + mode 0600 확인.

**PowerShell 함정**: 기본 `>` / `Out-File` 은 UTF-16 LE BOM 으로 저장 → tea 가 token 파일 읽기 실패. 반드시 `Set-Content -Encoding utf8NoBOM` 또는 `[IO.File]::WriteAllText()` 사용. harbor-ops/paperboy-ops config 도 동일 규칙.

## 셋업

1. **Author token** 발급: `https://<host>/user/settings/applications`. scope **반드시 포함**: `read:user` (tea 가 token 검증 시 호출), `write:repository`, `write:issue`, `write:package` (release asset 용).
2. **Reviewer token** 발급: 별도 Gitea 계정으로 로그인 후 동일 페이지에서. scope 동일 (`read:user`, `write:repository`).
3. **tea login 등록** — 두 가지 방법:
   - **(권장) tea 직접 등록**: `tea logins add --name gitea-ops-author --url https://<host> --token <T>` + `tea logins add --name gitea-ops-reviewer --url https://<host> --token <T>`.
   - **(자동 마이그레이션)** `~/.config/gitea-ops/token` (author) + `~/.config/gitea-ops/reviewer-token` (reviewer) 에 토큰을 저장 (mode 0600). 첫 호출 시 스크립트가 `git remote` 의 host 를 추론해 자동으로 `tea logins add`. host 자동 감지 실패 시 `GITEA_URL` env 로 override.
4. **호출 시 repo 자동 감지** — cwd 가 git repo 면 tea 가 `origin` 으로부터 owner/repo 추론. `-r owner/repo` 로 override 가능. 별도 config 파일 불필요.

login 이름 override: `GITEA_LOGIN_AUTHOR` / `GITEA_LOGIN_REVIEWER` env.

## 스크립트

모든 스크립트는 cwd 가 git working copy 일 때 tea 가 자동으로 `origin` 에서 host + owner/repo 를 추론한다. `-r <owner/repo>` 로 override (스크립트는 `--repo` 옵션을 그대로 tea 에 전달).

### `gitea-release`

```
gitea-release <TAG> [--name TITLE] [--notes TEXT | --notes-file PATH] [--auto-notes]
              [--draft] [--prerelease] [--target COMMITISH]
              [--asset PATH]... [--sign KEYPATH]
              [-r owner/repo] [-u URL]
```

- 로컬 전용 tag 면 push 후 release 생성.
- 각 `--asset` 에 `<asset>.sha256` 자동 첨부, `--sign KEYPATH` 면 `<asset>.minisig` 도.
- `--auto-notes`: 직전 release 이후 머지된 PR 을 `## 변경사항 (since <tag>)` 섹션으로 노트 맨 위에 prepend. PR 0 건이면 섹션 생략. `--notes` 와 병용 시 사용자 텍스트가 아래.

예시:
```sh
gitea-release v0.1.2 --auto-notes --notes "Image: harbor.example.com/foo:v0.1.2"
```

### `gitea-pr`

```
gitea-pr --title "..." --body "..." --head BRANCH [--base main]
         [--draft] [--assignee USER]... [--label LABEL]...
         [-r owner/repo] [-u URL]
```

`--head`가 로컬에만 있고 remote에 없으면 push 후 PR 작성.

### `gitea-pr-diff`

```
gitea-pr-diff <PR#> [--raw|--json] [-r owner/repo] [-u URL]
```

PR meta + unified diff을 stdout에 출력. 기본은 사람-친화 헤더 (title/base/head/files-changed) + diff. `--raw`는 diff body만, `--json`은 단일 JSON 객체.

Claude가 review 분석 input으로 사용:

```sh
gitea-pr-diff 42 > /tmp/pr-42.txt   # 분석용 dump
```

**아티팩트 위치 규칙**: dump 파일은 반드시 worktree **밖** (`/tmp/`, `~/.cache/` 등) 에 쓴다. 절대 `git add` / `git commit` 하지 않는다. 실수로 staging 에 들어갔다면 별도 정리 커밋을 만들지 말고 **같은 커밋에서 unstage 후 제거**. 정리 커밋은 history 노이즈이므로 회피.

### `gitea-pr-status`

```
gitea-pr-status <PR#> [--json] [--wait-ci]
                      [--ci-timeout SECONDS] [--ci-poll-interval SECONDS]
                      [-r owner/repo] [-u URL]
```

PR entry-gate 메타 + CI 상태를 한 번에 출력. flag: `--json` (기본은 `key=value`), `--wait-ci` (pending polling), `--ci-timeout SECONDS` (기본 1200), `--ci-poll-interval SECONDS` (기본 30).

출력 키: `title_ok` / `body_ok` / `changed_files` / `draft` / `base` / `head` / `head_sha` / `ci_state` (`none|pending|success|failure|error`) / `ci_count` / `gate_passed`. `gate_passed=true` 는 모든 필수 항목 통과 + (CI 없음 OR `ci_state=success`) 일 때만.

종료 코드: `0` 통과 / `1` 필수 실패 또는 CI pending(--wait-ci 미사용) / `2` CI failure·error / `3` --wait-ci timeout (**자동 실패 아님** — 사용자 결정 위임 신호) / 그 외 API 오류.

### `gitea-pr-review`

```
gitea-pr-review <PR#> --event <APPROVE|REQUEST_CHANGES|COMMENT>
                      [--body "..." | --body -]
                      [--inline FILE | --inline -]
                      [-r owner/repo] [-u URL]
```

`--body` / `--inline` 중 최소 하나 필요 (둘 다 가능). reviewer token 강제. Body 는 `--body -` (stdin), inline 은 JSON file 또는 `--inline -`.

Inline JSON 은 배열, 각 항목 `{path, body, new_position|old_position}`. 예: `[{"path":"file.go","new_position":42,"body":"..."}]`

예시:
```sh
gitea-pr-review 42 --event APPROVE --body "Approved. Logic sound."
gitea-pr-review 42 --event REQUEST_CHANGES --body "..." --inline /tmp/review-42.json
```

422 self-review: PR author 와 reviewer-token 계정이 같으면 발생. 명확한 메시지로 안내.

### `gitea-issue`

```
gitea-issue --title "..." [--body "..."] [--label LABEL]...
            [--assignee USER]... [--milestone ID]
            [-r owner/repo] [-u URL]
```

생성된 issue 번호 + URL을 출력.

### `gitea-issue-close`

```
gitea-issue-close <NUMBER> [--comment "..."] [-r owner/repo] [-u URL]
```

## GitHub Mirror

Gitea repo 를 GitHub 으로 mirror — 두 가지 모드:

1. **지속 자동** (`gitea-mirror-init`): GitHub repo 생성 + Gitea push mirror 등록. Gitea 가 cron (default 8h, sync_on_commit=true) 으로 자동 동기화. portfolio 용도 default.
2. **일회성** (`gitea-mirror-push`): cron 등록 없이 `git push --mirror` 한 번. dev branch 임시 미러 등.

### 추가 의존성 (mirror 명령에서만)

`gh` CLI (>= 2.x) — `gh repo create` / `gh repo view` 호출. release/PR/issue 명령은 영향 없음 (lazy require_cmd). 사전 인증: `gh auth login` + (선택) `gh auth setup-git` (git credential helper 등록 시 `gitea-mirror-push` 가 매끄럽게 동작).

### 셋업 (mirror 만)

1. **GitHub PAT 발급**: GitHub Settings → Developer settings → Personal access tokens → Fine-grained PAT. **scope 최소화** — 해당 mirror repo 만 contents:write. gh CLI 의 auth 토큰과 별개 (Gitea 측에 저장되어 push 인증에 사용).
2. **PAT 저장**: `~/.config/gitea-ops/github-mirror-token` (mode 0600) 또는 `GITHUB_MIRROR_TOKEN` env 또는 명령마다 `--token` / `--token-file` 명시.
3. **gh CLI 인증**: `gh auth login`. `gh auth setup-git` 로 git credential helper 등록.

### Public mirror 보호

`--public` 미러는 *모든 git history 가 영구 노출*. `gitea-mirror-init` / `gitea-mirror-push` 가 호출 직전 `git log --all -p` 에 대해 정규식 secret scan (password / api_key / token / private_key / aws / client_secret + `=` 또는 `:` 후 따옴표 안 8자 이상). 발견 시:

- 기본 동작: die. Claude 가 결과를 사용자에게 보고하고 다음 결정 받아 재호출:
  - `--no-secret-scan` (검토 생략 — 사용자가 ASCII safe 라고 확신할 때)
  - `--force-secret-scan` (false positive 확인 후 강행)
  - history 정리 (git filter-repo) 후 재시도
- false positive 가 흔한 경로 (`*.md`, `docs/**`) 는 git pathspec (`-- ':!*.md' ':!docs/**'`) 으로 git log 단계에서 제외.

### 명령 시그니처

#### `gitea-mirror-init`

```
gitea-mirror-init [--gitea-repo owner/repo] [--gh-repo OWNER/NAME]
                  (--public|--private) [--token-file PATH | --token TOKEN]
                  [--interval 8h0m0s] [--no-sync-on-commit]
                  [--no-secret-scan] [--force-secret-scan]
                  [--description TEXT]
```

- `--gh-repo` 미명시 default: `<gh user>/<gitea repo name>` (같은 이름). 이미 존재하면 die — Claude 가 사용자에게 다른 이름 받아 `--gh-repo` 로 재호출.
- 첫 sync 자동 trigger. 실패 시 경고만 (Gitea 다음 cron 자동 재시도).

#### `gitea-mirror-push`

```
gitea-mirror-push --gh-repo OWNER/NAME [--no-secret-scan] [--force-secret-scan]
```

cwd 가 git working copy + GitHub repo 가 이미 존재 필요 (없으면 `gitea-mirror-init` 또는 `gh repo create` 먼저).

#### `gitea-mirror-ls`

```
gitea-mirror-ls [--gitea-repo owner/repo] [--json]
```

#### `gitea-mirror-sync`

```
gitea-mirror-sync [--gitea-repo owner/repo]
```

repo 의 모든 push mirror 를 일괄 sync trigger (Gitea API 가 mirror 단위 sync 미지원).

#### `gitea-mirror-unlink`

```
gitea-mirror-unlink <mirror-name> [--gitea-repo owner/repo]
```

`<mirror-name>` 은 `gitea-mirror-ls` 출력의 첫 컬럼. GitHub repo 자체는 보존 (별도 `gh repo delete`).

## 에러 처리

- `tea logins add` 가 `token does not have at least one of required scope(s), required=[read:user]` → token 발급 시 `read:user` 누락. 재발급 후 등록.
- 401 (tea api 호출 시) → token 만료/회수. 새 token 으로 `tea logins edit` 또는 token 파일 갱신 후 `tea logins delete <name>` + 재등록.
- 403 → 작업 scope 부족 (예: write:issue 없이 issue 생성).
- `/repos/.../releases/tags/TAG` 에서 404 → tag 가 아직 remote 에 없음. `gitea-release` 가 push 후 1회 재시도.

## 인코딩 / Multi-byte 안전성

JSON 본문은 모두 `tea api -d @-` (stdin) 로 전송한다. 과거 curl `--data` 경로의 CR/LF strip 함정 (PR #11 리뷰의 "만" → `���`) 은 사라졌지만, **자동 안전성은 보장되지 않는다** — tea 0.14.0 의 stdin → HTTPS 본문 변환 어딘가에서 비결정적 multi-byte 손상이 관찰되었다 (PR #14 회차 3, 4 의 review summary body 에서 한 글자가 byte-wise replacement 로 대체된 사례). bash → jq → printf → tea read(stdin) 까지는 strace 로 정상 UTF-8 보존 확인됐고, 손상은 tea 내부 처리에서 발생.

**대응**:

- 다국어 본문 (한국어/일본어/이모지 등) 을 등록한 직후에는 **반드시 결과 (등록된 review/issue/PR body) 를 다시 fetch 해 손상 여부 확인**. 손상 발견 시 새 review/comment 로 정정 (영속성 규약 — 등록된 본문은 직접 수정 금지).
- 영문 ASCII 만 들어가는 호출은 영향 없음.
- 비결정적이라 동일 byte 시퀀스도 어떤 호출은 정상, 다른 호출은 손상. 짧은 본문 (회차 1, 2) 에서는 미발생, 긴 본문 (회차 3, 4) 에서 발생한 패턴이 있으나 단정 어려움.

`_common.sh:tea_api_json` 이 이 경로를 사용한다. 새 endpoint 추가 시에도 동일 helper 또는 직접 `tea api -X METHOD -d @-` 패턴 사용. tea 상위 버전에서 fix 가 확인되면 본 절 갱신.

## 작업 후

생성된 object의 URL을 항상 출력해 사용자가 클릭으로 이동할 수 있게 함.

## 작성 규칙

PR/release/issue/review 본문 작성 시 (대화창 출력과 별개):

- **언어**: 한국어 기본 (사용자 "영어로" 명시 시 영문). PR/branch/merge/commit/push/head/base/tag/release/review/gate/token/worktree 등 기술 키워드는 한국어 산문 안에 영문 inline. CLI 식별자·flag·URL·code block 은 영문 그대로. 체크리스트/표 헤더는 한국어.
- **commit 메시지 / PR title**: Conventional Commits — `feat(scope): ...`, `fix(scope): ...`. 영문 prefix + 한국어 본문 OK.
- **caveman 모드 미적용**: caveman 모드여도 PR/issue/review 본문은 자연스러운 산문 (영구 기록). 대화창만 caveman.
- **PR review (`gitea-pr-review`)**: summary 는 짧게 (방향성/총평), 구체 지적은 inline. 적극적으로 달 것.
  - 문제 (bug/의도 불명확/edge case 누락/보안·성능/명명) + **칭찬도 의도적으로** (좋은 추상화, 영리한 jq filter, test 커버리지 등) — 무미건조하지 않게.
  - 기본 3–10 개. 0 개는 review 안 한 것 같음.
- **리뷰·코멘트 영속성**: review summary, inline comment, issue comment 는 등록 후 **수정·삭제 금지**. 오타도 새 review/코멘트로 정정. 본 skill 어떤 스크립트도 `PATCH`/`DELETE` × {`pulls/{n}/reviews/{id}`, `pulls/{n}/comments/{id}`, `issues/comments/{id}`} 6 endpoint 호출 안 함 — `_common.sh` 상단 `FORBIDDEN ENDPOINTS` 주석. 새 스크립트도 금지.
- **리뷰 의견 반영 default**: 단발 모드에서 actionable 코멘트(issue/suggestion) 나오면 별도 지시 없는 한 **동일 PR 후속 커밋으로 즉시 반영**. 백로그 이월은 사용자 명시 시만. 리뷰 루프 모드는 [루프 한 회차 동작](#루프-한-회차-동작) (4) 가 같은 규칙. "수정 거부 옵션" 우선 — rationale 동의 못 하면 사용자 결정 위임.
