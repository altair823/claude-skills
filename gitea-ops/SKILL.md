---
name: gitea-ops
description: Drive Gitea via REST API from the CLI — create releases with minisign/sha256 assets, open PRs, file/close issues, and mirror Gitea repos to GitHub (gh CLI). Use when the user asks to cut a release, open a PR, file/close an issue, or set up/control a Gitea→GitHub push mirror. Auto-detects host + repo from the current git remote.
---

# gitea-ops

Gitea REST API 얇은 wrapper, [`tea` CLI](https://gitea.com/gitea/tea) 기반. 의존성: `tea` (>= 0.14), `jq`, `git` (release 서명 시 `sha256sum`, `minisign` 추가). 인증·host 감지·UTF-8 송신은 tea 가 처리 — curl 직호출 없음.

## 사용 시점

- tag release + binary asset (sha256/minisign)
- PR 작성, issue 작성/닫기, PR/issue bulk 조회
- Gitea repo → GitHub mirror (`## GitHub Mirror` 참조)

GitHub/GitLab 직접 API 작업엔 사용 금지 (API 다름).

## Workflow

```sh
# 1. 작성자가 PR 생성
gitea-pr --title "feat(gitea-ops): 위젯 추가" --head feat/gitea-ops-widget

# 2. 리뷰어 (별도 Claude 세션, reviewer-token)
gitea-pr-diff 42                    # 분석용 meta+diff dump
gitea-pr-review 42 --event APPROVE \
    --body "전반적으로 로직이 타당하고 회귀 위험이 보이지 않아 머지에 동의합니다."

# 3. 사람이 Gitea UI에서 머지 (Claude 자동 머지 안 함). "Delete branch after merge"
#    체크 + `git worktree remove <path>` 로 로컬 정리.
```

문제 없는 리뷰도 **APPROVE 코멘트는 반드시 등록** — 사람의 머지 결정에 명시적 승인 신호 필요.

## PR 생성 전 선택지: 리뷰 루프

`gitea-pr` 로 PR 생성 직전, 사용자에게 모드를 **반드시 묻고 답을 받는다** (임의 결정 금지).

1. **단발 (기본)** — PR을 만들고 종료. 리뷰는 필요할 때 별도로 요청.
2. **리뷰 루프** — PR 생성 직후 자동으로 셀프 리뷰. actionable 지적/권장이 있으면 후속 커밋으로 반영한 뒤 다시 리뷰 — 모든 actionable 코멘트가 해소되고 `event=APPROVE`만 남을 때까지 반복.

### Entry-gate

1회차 `gitea-pr-diff` 호출 전 통과 필수 (실패 시 거부 + 누락 항목 보고). `gitea-pr-status <PR#> --wait-ci` 로 점검.

**필수 항목 (항상)**
- `title`/`body` 비어있지 않음, `changed_files > 0`, `draft == false`, `base`/`head` branch 존재
- PR 제목이 정규식 `^(feat|fix|docs|refactor|chore|test)(\([a-z0-9-]+\))?: .+` 통과
- 브랜치 이름이 정규식 `^(feat|fix|docs|refactor|chore|test)/[a-z0-9]+(-[a-z0-9]+)*$` 통과
- PR body 에 `## 요약` 및 `## 검증` 헤더 존재, `## 요약` 절 본문이 whitespace 제거 후 1자 이상

**CI 항목 (조건부)**
PR head SHA combined status 조회. `total_count==0` (CI 없음) → skip. `success` → 통과, `failure`/`error` → 거부, `pending` → 30초 간격 최대 20분 polling. timeout 시 **자동 실패 처리 안 함** — 사용자에게 결정 위임 (`gitea-pr-status` exit 3).

### 루프 한 회차 동작

회차 1 전 [Entry-gate](#entry-gate) 통과 필수. 매 회차 (1)~(4) **모두** 수행 — (2) 의 `gitea-pr-review` 생략하면 회차가 아닌 단순 후속 작업.

1. `gitea-pr-diff <PR#>` 로 현재 diff dump.
2. 리뷰어 관점으로 분석 후 `gitea-pr-review` **반드시 호출** — 회차마다 새 review 한 건 등록.
   - actionable 지적(결함·불명확·누락뿐 아니라 **오타·명명·가독성 등 nit/cosmetic 포함**)이 **하나라도** 있으면 `--event REQUEST_CHANGES` + inline 코멘트 — nit 도 APPROVE 로 묻지 않는다.
   - 0건, 칭찬·수긍만 있으면 `--event APPROVE`.
   - summary 첫 줄에 `회차 N` prefix (예: `회차 2 — 회차 1 지적 모두 반영. 추가 권장 1건.`).
3. **종료 조건**: 방금 등록한 review 가 `event=APPROVE` 이고 inline 코멘트에 issue/suggestion 카테고리 0개.
4. 미충족 시: inline 코멘트/summary 반영 → 새 커밋 → push → 다음 회차 (1) 로.

> Gitea 는 push 시 이전 review 를 자동 dismiss 하지 않고 "Outdated" 배지만 붙인다. "APPROVE 하나만 보임"은 회차 누락 신호.

### 머지 안내

APPROVE 로 종료되면 머지 안내 시 **반드시 PR URL 포함** (예: `https://gitea.example/owner/repo/pulls/N`) — 없으면 사용자가 PR 번호를 다시 찾아야 한다.

**PR URL 확보 (권장 순)**: (1) `gitea-pr` 생성 직후 출력된 URL 을 보존해 재사용 (가장 견고). (2) 어려우면 `gitea-pr-review` 출력 (`https://host/owner/repo/pulls/N#issuecomment-XXX`) 에서 `#` 앞까지 잘라 사용.

### 가드

- **최대 회차 5회**. 이후에도 actionable 코멘트가 남으면 루프 강제 종료 + 사용자 보고.
- **수정 거부 옵션**: rationale 에 동의 못하면 반영 대신 사유를 보고하고 결정 위임 — 리뷰를 무비판적으로 따르지 않는다.
- **수렴 실패 감지**: 동일 inline 코멘트가 두 회차 연속 같은 위치에 재등장하면 강제 종료 + 사용자 보고.

## 환경 사전 점검

토큰 첫 사용 전: 의존성 (`tea jq git`, 서명 시 `minisign sha256sum` 추가) + 토큰 파일 UTF-8 no BOM + mode 0600 확인.

**PowerShell 함정**: 기본 `>`/`Out-File` 은 UTF-16 LE BOM 저장 → tea 가 token 파일 읽기 실패. `Set-Content -Encoding utf8NoBOM` 또는 `[IO.File]::WriteAllText()` 사용.

## 셋업

1. **Author token**: `https://<host>/user/settings/applications`. 필수 scope: `read:user` (tea 검증용), `write:repository`, `write:issue`, `write:package` (release asset).
2. **Reviewer token**: 별도 계정, 동일 페이지. scope `read:user`, `write:repository`.
3. **tea login 등록**: (권장) `tea logins add --name gitea-ops-author --url https://<host> --token <T>` (+ reviewer 동일) / (자동) `~/.config/gitea-ops/token`(author) + `~/.config/gitea-ops/reviewer-token`(reviewer), mode 0600 — 첫 호출 시 `git remote` host 로 자동 등록 (실패 시 `GITEA_URL` env override).
4. **repo 자동 감지**: cwd 가 git repo 면 tea 가 `origin` 에서 owner/repo 추론, `-r owner/repo` 로 override.

login 이름 override: `GITEA_LOGIN_AUTHOR`/`GITEA_LOGIN_REVIEWER` env.

## 스크립트

repo 자동 감지는 [셋업](#셋업) 참조. `-r <owner/repo>` 는 스크립트가 `--repo` 로 tea 에 전달.

### `gitea-release`

```
gitea-release <TAG> [--name TITLE] [--notes TEXT | --notes-file PATH] [--auto-notes]
              [--draft] [--prerelease] [--target COMMITISH]
              [--asset PATH]... [--sign KEYPATH]
              [-r owner/repo] [-u URL]
```

로컬 전용 tag 면 push 후 release 생성. 각 `--asset` 에 `<asset>.sha256` 자동 첨부, `--sign KEYPATH` 면 `<asset>.minisig` 도. `--auto-notes`: 직전 release 이후 머지된 PR 을 `## 변경사항 (since <tag>)` 로 노트 맨 위에 prepend (0건이면 생략), `--notes` 병용 시 사용자 텍스트가 아래.

```sh
gitea-release v0.1.2 --auto-notes --notes "Image: harbor.example.com/foo:v0.1.2"
```

### `gitea-pr`

```
gitea-pr --title "..." --body "..." --head BRANCH [--base main]
         [--draft] [--assignee USER]... [--label LABEL]...
         [--no-lint] [--no-trailer]
         [-r owner/repo] [-u URL]
```

`--head` 가 로컬에만 있으면 push 후 PR 작성. `_lint.sh` lint 실패 시 push·생성 모두 거부, `--no-lint` 로 우회 (sledgehammer, `--no-trailer` 동반 적용). `Assisted-by: Claude Code` trailer 자동 부착 (idempotent), `--no-trailer` 로 끔.

### `gitea-pr-diff`

```
gitea-pr-diff <PR#> [--raw|--json] [-r owner/repo] [-u URL]
```

PR meta + unified diff 을 stdout 출력. 기본은 헤더(title/base/head/files-changed)+diff, `--raw` 는 diff body 만, `--json` 은 단일 JSON 객체.

```sh
gitea-pr-diff 42 > /tmp/pr-42.txt   # 분석용 dump
```

**아티팩트 위치**: dump 는 worktree **밖** (`/tmp/`, `~/.cache/` 등) 에 쓰고 절대 `git add`/`commit` 하지 않는다. 실수로 staging 됐다면 같은 커밋에서 unstage 후 제거 (별도 정리 커밋 금지).

### `gitea-pr-status`

```
gitea-pr-status <PR#> [--json] [--wait-ci]
                      [--ci-timeout SECONDS] [--ci-poll-interval SECONDS]
                      [-r owner/repo] [-u URL]
```

PR entry-gate 메타 + CI 상태를 한 번에 출력. `--json` (기본 `key=value`), `--wait-ci` (pending polling), `--ci-timeout` (기본 1200), `--ci-poll-interval` (기본 30).

출력 키: `title_ok`/`body_ok`/`changed_files`/`draft`/`base`/`head`/`head_sha`/`ci_state` (`none|pending|success|failure|error`)/`ci_count`/`lint_title`/`lint_branch`/`lint_body`/`gate_passed`. `gate_passed=true` 는 모든 필수 항목 통과 + 모든 `lint_*` = `pass` + (CI 없음 또는 `ci_state=success`).

lint 실패 사유는 stderr 로 emit (stdout 은 항상 클린 — 자동화 caller 는 stdout 만 파이프).

종료 코드: `0` 통과/`1` 필수 실패 또는 CI pending(--wait-ci 미사용)/`2` CI failure·error/`3` --wait-ci timeout (**자동 실패 아님** — 사용자 결정 위임 신호)/그 외 API 오류.

### `gitea-pr-review`

```
gitea-pr-review <PR#> --event <APPROVE|REQUEST_CHANGES|COMMENT>
                      [--body "..." | --body -]
                      [--inline FILE | --inline -]
                      [-r owner/repo] [-u URL]
```

`--body` / `--inline` 중 최소 하나 필요 (둘 다 가능). reviewer token 강제. `--body -` 로 stdin, inline 은 JSON file 또는 `--inline -`. Inline JSON 은 배열, 각 항목 `{path, body, new_position|old_position}`. 예: `[{"path":"file.go","new_position":42,"body":"..."}]`

```sh
gitea-pr-review 42 --event REQUEST_CHANGES --body "..." --inline /tmp/review-42.json
```

422 self-review: PR author 와 reviewer-token 계정이 같으면 발생 (명확한 메시지로 안내).

### `gitea-issue`

```
gitea-issue --title "..." [--body "..."] [--label LABEL]...
            [--assignee USER]... [--milestone ID]
            [-r owner/repo] [-u URL]
```

생성된 issue 번호 + URL 출력.

### `gitea-issue-close`

```
gitea-issue-close <NUMBER> [--comment "..."] [-r owner/repo] [-u URL]
```

## GitHub Mirror

Gitea repo 를 GitHub 으로 mirror — 두 모드:
- **지속 자동** (`gitea-mirror-init`): GitHub repo 생성 + push mirror 등록, cron (default 8h, sync_on_commit=true) 자동 동기화. portfolio 기본.
- **일회성** (`gitea-mirror-push`): cron 없이 `git push --mirror` 1회. dev branch 임시 미러 등.

### 추가 의존성 (mirror 전용)

`gh` CLI (>= 2.x) — `gh repo create`/`view` 호출, release/PR/issue 명령엔 무관 (lazy require_cmd). 사전: `gh auth login` (+ 선택 `gh auth setup-git`).

### 셋업 (mirror 만)

1. **GitHub PAT**: Fine-grained PAT, 해당 mirror repo 만 `contents:write` — scope 최소화 (gh CLI auth 토큰과 별개, push 인증용으로 Gitea 측에 저장).
2. **PAT 저장**: `~/.config/gitea-ops/github-mirror-token` (mode 0600)/`GITHUB_MIRROR_TOKEN` env/`--token`·`--token-file`.
3. **gh CLI 인증**: `gh auth login` + `gh auth setup-git`.

### Public mirror 보호

`--public` 미러는 *git history 전체가 영구 노출*. `gitea-mirror-init`/`-push` 가 호출 직전 `git log --all -p` 에 정규식 secret scan (password/api_key/token/private_key/aws/client_secret + `=`/`:` 뒤 따옴표 안 8자 이상). 발견 시 기본은 die, 사용자 결정 후 재호출: `--no-secret-scan`(생략, ASCII safe 확신 시) / `--force-secret-scan`(false positive 확인 후 강행) / history 정리(filter-repo) 후 재시도.

false positive 잦은 경로 (`*.md`, `docs/**`) 는 pathspec (`-- ':!*.md' ':!docs/**'`) 으로 제외. 변수 expansion 만 있는 line (`"$VAR"`, `"${VAR}"`, `"${!VAR}"` — bash indirect 포함) 은 자동 제외.

### 명령 시그니처

#### `gitea-mirror-init`

```
gitea-mirror-init [--gitea-repo owner/repo] [--gh-repo OWNER/NAME]
                  (--public|--private) [--token-file PATH | --token TOKEN]
                  [--interval 8h0m0s] [--no-sync-on-commit]
                  [--no-secret-scan] [--force-secret-scan]
                  [--description TEXT] [--skip-create]
```

`--gh-repo` 미명시 default `<gh user>/<gitea repo name>`. 이미 존재하면 die — 다른 이름 재호출 또는 `--skip-create` 로 기존 repo 에 push mirror 만 등록 (visibility/description 무시). 첫 sync 자동 trigger, 실패해도 경고만 (다음 cron 재시도).

#### `gitea-mirror-push`

```
gitea-mirror-push --gh-repo OWNER/NAME [--force-mirror]
                  [--no-secret-scan] [--force-secret-scan]
```

Default: `git push --all --tags` (force 없이, fast-forward 안 되면 reject; 삭제된 branch/tag 는 GitHub 에 stale 로 남음 — `--prune` 안 함). `--force-mirror`: `git push --mirror` (모든 ref + force-update + remote-tracking) — collaborator 직접 commit 손실 위험. cwd 가 git working copy + GitHub repo 존재 필요.

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

`<mirror-name>` 은 `gitea-mirror-ls` 출력 첫 컬럼. GitHub repo 자체는 보존 (별도 `gh repo delete`).

## 에러 처리

- `tea logins add` 가 `... required=[read:user]` → token 발급 시 `read:user` 누락, 재발급.
- 401 (tea api 호출 시) → token 만료/회수. 새 token 으로 `tea logins edit` 또는 파일 갱신 후 `tea logins delete <name>` + 재등록.
- 403 → scope 부족 (예: write:issue 없이 issue 생성).
- `/repos/.../releases/tags/TAG` 404 → tag 가 아직 remote 에 없음. `gitea-release` 가 push 후 1회 재시도.
- `lint failed: title does not match ^(feat|fix|...)...` → PR title 정규식 미통과. `feat(scope): ...` 로 수정 (cross-cutting 이면 scope 생략 OK).
- `lint failed: branch does not match ^(feat|fix|...)/...` → 브랜치 이름 정규식 미통과. `git branch -m new-name` 후 재push.
- `lint failed: body missing required header ## 요약` → PR body 가 표준 골격 미준수. `## 요약`/`## 검증` 헤더 추가, `## 요약` 본문 1자 이상.

## 인코딩 / Multi-byte 안전성

JSON 본문은 모두 `tea api -d @-` (stdin) 로 전송한다. 과거 curl `--data` 경로의 CR/LF strip 함정은 사라졌지만 **자동 안전성은 보장되지 않는다** — tea 0.14.0 의 stdin → HTTPS 변환 어딘가에서 비결정적 multi-byte 손상이 관찰되었다 (긴 review body 에서 한 글자가 replacement 로 대체된 사례). bash→jq→printf→tea(stdin) 까지는 UTF-8 보존 확인됨 — 손상은 tea 내부 처리에서 발생.

**대응**: 다국어 본문 (한국어/일본어/이모지 등) 을 등록한 직후 **반드시 결과를 다시 fetch 해 손상 여부 확인** — 발견 시 새 review/comment 로 정정 (영속성 규약, 등록된 본문 직접 수정 금지). 영문 ASCII 만 있는 호출은 영향 없음. 비결정적이라 동일 시퀀스도 호출마다 다름 — 짧은 본문은 미발생, 긴 본문에서 발생 경향이나 단정 어려움.

`_common.sh:tea_api_json` 이 이 경로를 사용한다. 새 endpoint 도 동일 helper 또는 `tea api -X METHOD -d @-` 패턴 사용.

## 작업 후

생성된 object의 URL을 항상 출력해 사용자가 클릭으로 이동할 수 있게 함.

## 작성 규칙

PR/release/issue/review 본문 작성 시 (대화창 출력과 별개):

- **언어**: 한국어 기본 (사용자 "영어로" 명시 시 영문). 기술 키워드(PR/branch/merge/commit/push/head/base/tag/release/review/gate/token/worktree 등)는 한국어 산문에 영문 inline. CLI 식별자·flag·URL·code block 은 영문 그대로.
- **PR title / commit**: Conventional Commits, PR title 정규식 강제 (entry-gate / `gitea-pr` lint):
  ```
  ^(feat|fix|docs|refactor|chore|test)(\([a-z0-9-]+\))?: .+
  ```
  scope 는 lowercase+숫자+하이픈 (보통 스킬 이름). **cross-cutting 변경에 한해** scope 생략 허용 — 단일 스킬만 영향이면 scope 필수. 영문 prefix+한국어 본문 OK. commit 메시지는 lint 안 함 — 권장 `chore(scope): PR #N 회차 K 리뷰 반영`.
- **브랜치 이름**: `<type>/<topic-kebab>` 강제 (entry-gate / `gitea-pr` lint):
  ```
  ^(feat|fix|docs|refactor|chore|test)/[a-z0-9]+(-[a-z0-9]+)*$
  ```
  scope 는 topic 에 kebab 으로 포함 (`feat/homelab-ops-exec-and-curated-verbs`), 생략 시 `docs/cross-cutting-readme` 처럼 type+topic 만. PR title 의 scope 유무와 브랜치 scope 일치는 lint 가 검증 안 함 — 사용자 책임.
- **PR 본문 골격**: 필수 헤더 `## 요약` + `## 검증` (정확히 이 문자열), `## 요약` 뒤 비어있지 않은 본문 1자 이상 (whitespace 제외). 권장 헤더: `설계:`/`계획:` 줄 (`## 요약` 직후), `## 시험 항목 (Test Plan)`, `## 비범위`/`## 변경 없음`, `## 카테고리` (자유 명명). 표준 골격:
  ```markdown
  ## 요약
  <수준·동기·핵심 설계 1–2 문단>

  설계: docs/superpowers/specs/...

  ## 검증
  - 전체 테스트 녹색

  ## 시험 항목 (Test Plan)
  - [ ] ...
  ```
- **Trailer**: body 마지막 빈 줄 다음 `Assisted-by: Claude Code` 한 줄. `gitea-pr` 자동 부착·idempotent, `--no-trailer` 로 끔. 옛 `🤖 Generated with [Claude Code](...)` 푸터는 비권장.
- **caveman 모드 미적용**: PR/issue/review 본문은 caveman 모드여도 자연스러운 산문 (영구 기록, 대화창만 caveman).
- **PR review 작성**: summary 는 짧게, 구체 지적은 inline. 문제(bug/불명확/edge case/보안·성능/명명) + **칭찬도 의도적으로**, 기본 3–10개 (0개는 review 안 한 것 같음).
- **리뷰·코멘트 영속성**: review summary/inline comment/issue comment 는 등록 후 **수정·삭제 금지** — 오타도 새 review/코멘트로 정정. `PATCH`/`DELETE` × {`pulls/{n}/reviews/{id}`, `pulls/{n}/comments/{id}`, `issues/comments/{id}`} 는 FORBIDDEN ENDPOINTS (`_common.sh` 상단 주석) — 어떤 스크립트도 호출 안 함.
- **리뷰 의견 반영 default**: 단발 모드에서 actionable 코멘트가 나오면 별도 지시 없는 한 **동일 PR 후속 커밋으로 즉시 반영** (백로그 이월은 사용자 명시 시만). 리뷰 루프는 [루프 한 회차 동작](#루프-한-회차-동작) (4) 동일 규칙. "수정 거부 옵션" 우선.
