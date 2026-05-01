---
name: gitea-ops
description: Drive Gitea via REST API from the CLI — create releases with minisign/sha256 assets, open PRs, file/close issues. Use when the user asks to cut a release, open a PR, or file/close an issue on a Gitea remote. Auto-detects host + repo from the current git remote; falls back to ~/.config/gitea-ops/config.
---

# gitea-ops

Gitea REST API thin wrapper. 의존성은 `curl`, `jq`, `git`, 그리고 (release 서명용) `sha256sum` + `minisign` 뿐.

## 사용 시점

사용자가 다음 중 하나를 원할 때 호출:
- tag release를 만들고 binary artifact 첨부 (sha256 + minisign 포함)
- pull request 작성 (프로그램적으로)
- issue 작성/닫기 (프로그램적으로)
- Gitea repo의 issue/PR bulk 조회

GitHub/GitLab에는 사용 금지 — API 구조가 다름.

## Workflow

```sh
# 1. 작성자가 PR 생성
gitea-pr --title "위젯 추가" --head feat/widget

# 2. 리뷰어 (별도 Claude 세션, reviewer-token):
gitea-pr-diff 42                    # 분석용 meta+diff dump
gitea-pr-review 42 --event APPROVE \
    --body "전반적으로 로직이 타당하고 회귀 위험이 보이지 않아 머지에 동의합니다."

# 3. 사람이 Gitea UI에서 직접 머지 — Claude는 자동 머지하지 않음.
#    리뷰가 APPROVE 상태면 작성자/메인테이너가 웹에서 merge 버튼 클릭.
#    이때 "Delete branch after merge" 옵션을 함께 체크해 원격 head branch를 정리하고,
#    로컬 worktree는 `git worktree remove <path>`로 별도 정리한다.
```

리뷰 결과가 문제 없을 때도 **APPROVE 코멘트는 반드시 등록**한다 (`gitea-pr-review --event APPROVE`).
Claude가 직접 머지하지 않더라도, 사람이 머지 결정을 내릴 때 명시적인 승인 신호가 필요하기 때문.

## PR 생성 전 선택지: 리뷰 루프

`gitea-pr`로 PR을 만들기 직전, Claude는 사용자에게 다음 두 가지 모드 중 어느 것으로 진행할지 **반드시 묻고 답을 받는다**. 사용자 응답 없이 임의로 결정하지 않는다.

1. **단발 (기본)** — PR을 만들고 종료. 리뷰는 사용자가 필요할 때 별도로 요청한다.
2. **리뷰 루프** — PR을 만든 직후 Claude가 자동으로 셀프 리뷰를 돌리고, 리뷰가 actionable한 지적이나 권장 사항을 담고 있으면 그 내용을 후속 커밋으로 반영한 뒤 다시 리뷰한다. 모든 actionable 코멘트가 해소되고 `event=APPROVE`만 남을 때까지 반복.

질문 형태 예시 (대화창):

> PR을 어떤 모드로 진행할까요?
> 1. **단발** (기본) — PR만 생성.
> 2. **리뷰 루프** — 자동 리뷰 → 수정 → 재리뷰를 모두 APPROVE될 때까지 반복.

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

### 루프 한 회차 동작

회차 1 진입 전 위 [Entry-gate](#entry-gate) 를 통과해야 한다. 통과 못 한 PR 에는 리뷰 루프를 시작하지 않는다.

리뷰 루프 모드에서는 매 회차마다 다음을 **반드시 모두** 수행한다. 어느 단계도 생략 금지 — 특히 (2) 의 `gitea-pr-review` 호출을 빼먹고 commit/push만 하면 그건 회차가 아니라 단순 후속 작업으로 간주된다.

1. `gitea-pr-diff <PR#>`로 현재 PR diff을 dump.
2. 리뷰어 관점에서 분석 후 `gitea-pr-review` **반드시 호출** — 매 회차에 새로운 review를 한 건씩 PR에 등록해야 한다.
   - 본문/코드에 명확한 결함, 의도 불명확, 누락, 권장 개선이 있으면 `--event REQUEST_CHANGES` + 해당 inline 코멘트.
   - actionable한 지적이 없고 칭찬·수긍 코멘트만 남으면 `--event APPROVE`.
   - summary body 첫 줄에 `회차 N` prefix를 붙여 timeline에서 회차를 식별 가능하게 한다 (예: `회차 2 — 회차 1 지적 모두 반영. 추가 권장 1건.`).
3. **종료 조건**: 방금 등록한 review의 `event=APPROVE` 이고 inline 코멘트에 issue/suggestion 카테고리가 0개 (칭찬만 있음). 이때 루프 종료.
4. 종료 조건 미충족: inline 코멘트와 summary를 토대로 코드/문서를 수정 → 새 커밋 → push → 다음 회차의 (1) 로 진입.

> **참고**: Gitea는 새 commit이 push되면 직전 review에 "Outdated" 배지를 붙여 표시할 수 있지만, review 자체와 inline 코멘트는 PR timeline과 review 목록에 영구 보존된다. 기본 설정에서는 새 commit push가 이전 review를 자동 dismiss하지 않는다 — 단지 "Outdated" 배지만 붙고 review는 그대로 남는다 (Gitea protected branch 설정의 `dismiss_stale_approvals` 옵션 — UI 표기 "Dismiss stale approvals" — 을 켠 환경에선 별도 동작이 가능). "최종 APPROVE 하나만 보임" = 회차마다 review를 등록하지 않은 것 — UI에서 사라진 게 아님.

### 가드

- **최대 회차 5회**. 5회차 이후에도 actionable 코멘트가 남으면 루프를 강제 종료하고 사용자에게 결과를 보고한다 — 무한 회전 방지.
- **수정 거부 옵션**: 리뷰 코멘트의 rationale에 동의하지 못하는 경우 (의도된 단순화 등) Claude는 반영 대신 사유를 사용자에게 보고하고 결정을 위임한다. 자기가 단 리뷰를 무비판적으로 따르지 않는다.
- **수렴 실패 감지**: 동일한 inline 코멘트가 두 회차 연속 같은 위치에 다시 등장하면 그 자체로 강제 종료 신호 — 회차를 더 돌려도 풀리지 않는다는 뜻이므로 사용자에게 보고하고 멈춘다.

### 사람 머지 단계는 변경 없음

루프가 APPROVE로 종료되어도 머지 버튼은 여전히 사람이 Gitea UI에서 누른다. 루프는 사람이 머지를 누르기 전 단계까지의 PR 품질을 자동으로 끌어올리는 역할만 한다.

## 셋업

1. Personal Access Token: `https://<host>/user/settings/applications`에서 발급.
   scope: **repository**, **issue**, **package** (release asset용).
2. token 저장: `~/.config/gitea-ops/token` (mode 0600) **또는** `GITEA_TOKEN` env.
3. 기본값 (선택): `~/.config/gitea-ops/config`에
   ```
   GITEA_URL=https://gitea.example.com
   GITEA_REPO=owner/repo
   ```
   `origin` remote가 Gitea URL과 일치하면 자동 추출됨.
4. **Reviewer token** (separate Gitea account, repo write scope): generate at
   `https://<host>/user/settings/applications` while logged in as the reviewer
   account. Required only by `gitea-pr-review`.

   Create the file (one-time):
   ```sh
   mkdir -p ~/.config/gitea-ops
   touch ~/.config/gitea-ops/reviewer-token
   chmod 600 ~/.config/gitea-ops/reviewer-token
   # then: paste the token string into ~/.config/gitea-ops/reviewer-token
   ```

   Or set `GITEA_REVIEWER_TOKEN` env. An empty placeholder file is rejected by
   `gitea-pr-review` until a token is pasted in.

## 스크립트

모든 스크립트는 working copy 내에서 호출 시 `git remote get-url origin`으로 host + repo를
자동 감지 (origin이 Gitea host를 가리키는 경우). `-u <URL>` / `-r <owner/repo>`로 오버라이드.

### `gitea-release`

```
gitea-release <TAG> [--name TITLE] [--notes TEXT | --notes-file PATH] [--auto-notes]
              [--draft] [--prerelease] [--target COMMITISH]
              [--asset PATH]... [--sign KEYPATH]
              [-r owner/repo] [-u URL]
```

- tag가 로컬에만 있고 remote에 없으면 push.
- release 생성.
- 각 `--asset`마다 자동 생성된 `<asset>.sha256` 함께 업로드, `--sign KEYPATH` 있으면 `<asset>.minisig`도 업로드.
- `--auto-notes`: 직전 release(`/releases?limit=2`의 두 번째 항목) 시점 이후
  머지된 PR을 `## 변경사항 (since <tag>)` 섹션으로 노트 본문 맨 위에 prepend.
  PR이 0건이면 섹션 자체를 생략. `--notes`/`--notes-file`와 함께 쓰면 사용자
  텍스트가 그 아래에 이어짐.

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

### `gitea-pr-review`

```
gitea-pr-review <PR#> --event <APPROVE|REQUEST_CHANGES|COMMENT>
                      [--body "..." | --body -]
                      [--inline FILE | --inline -]
                      [-r owner/repo] [-u URL]
```

`--body` 또는 `--inline` 중 최소 하나는 필요하다 (둘 다 지정 가능).

reviewer token (separate from main token) 강제. Body는 `--body -`로 stdin에서, inline comments는 JSON file 또는 `--inline -` stdin.

Inline JSON schema (배열):
```json
[{"path":"file.go","new_position":42,"body":"..."},
 {"path":"old.sh","old_position":10,"body":"..."}]
```
각 항목은 `path`, `body`, `new_position` 또는 `old_position` 필수.

예시:
```sh
gitea-pr-review 42 --event APPROVE --body "Approved. Logic sound."
gitea-pr-review 42 --event REQUEST_CHANGES \
    --body "$(cat <<'EOF'
Several inline issues — see below.
EOF
)" --inline /tmp/review-42.json
```

422 self-review 응답은 명확한 메시지로 안내. PR author와 reviewer-token 계정이 같으면 발생.

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

## 에러 처리

- 401 → token 누락/무효. 사용자에게 `~/.config/gitea-ops/token` 확인 안내.
- 403 → token scope 부족.
- `/repos/.../releases/tags/TAG`에서 404 → tag가 아직 remote에 없음. 스크립트가 push 후 1회 재시도.

## 인코딩 / Multi-byte 안전성

JSON 본문을 POST/PATCH 할 때는 항상 `curl --data-binary @-` 를 사용한다. 일반 `--data`는 입력에서 CR/LF 등을 strip 하면서 부수 처리를 하기 때문에, 한글·이모지 같은 multi-byte UTF-8 시퀀스가 산발적으로 invalid byte로 손상되어 Gitea에 U+FFFD(`���`)로 저장되는 사례가 실제로 발생했다 (PR #11 리뷰 코멘트의 "만" → `���`).

`_common.sh:api_json` 과 `gitea-pr-review` 가 이 규칙을 따른다. 새 endpoint 추가 시에도 `--data-binary` 로 통일.

## 작업 후

생성된 object의 URL을 항상 출력해 사용자가 클릭으로 이동할 수 있게 함.

## 작성 규칙

Claude가 본 skill을 통해 PR/release/issue/review를 작성할 때 따르는 기본 규칙:

- **caveman 모드 미적용**: 세션에 caveman 모드가 활성화되어 있어도 PR title/body, issue, release notes, review summary, inline review comment는 **평소처럼 자연스러운 산문**으로 작성한다. 압축·문장 단편화·관사 생략 금지. 이 글들은 사용자/리뷰어가 두고두고 읽는 영구 기록이므로 의도와 맥락이 명확해야 함. (대화창 출력만 caveman 적용.)
- **본문 언어**: 한국어 기본. 사용자가 영문 명시 시 영문.
- **기술 키워드**: PR/branch/merge/commit/fetch/push/pull/head/base/tag/release/review/gate/token/worktree 등은 한국어 산문 안에서 영문 inline. 번역하지 않음.
- **CLI 식별자/flag/URL**: 영문 그대로.
- **commit 메시지 / PR title**: Conventional Commits (`feat(scope): ...`, `fix(scope): ...` 등) — 영문 prefix + 한국어 본문 OK.
- **체크리스트 / 표 헤더**: 한국어.
- **Code block / API 응답 예시 / shell 명령**: 영문 그대로.
- **Co-Authored-By trailer**: 영문 자동.
- **PR review (`gitea-pr-review`)**: summary body는 짧게 (방향성/총평), 구체적 지적은 inline comment로. 적극적으로 달 것.
  - **문제 (`new_position`/`old_position` 지적)**: bug, 의도 불명확, edge case 누락, 보안/성능 우려, 명명 개선 등.
  - **칭찬**: 좋은 결정, 깔끔한 추상화, 영리한 jq filter, test 커버리지 같은 의도적 잘한 부분도 inline으로 코멘트. 무미건조한 review가 아니라 진짜 읽고 있다는 신호.
  - 기본 3–10개. 문제가 많은 PR이면 더 많아도 OK. 0개는 review를 안 한 것 같음.
- **리뷰·코멘트 영속성**: review summary, inline review comment, issue comment 는 한 번 등록되면 **수정·삭제하지 않는다**. 오타나 잘못된 판단을 발견한 경우에도 새 review 또는 새 코멘트로 정정한다 — timeline 의 회차 기록은 영구 보존되어야 한다. 본 skill 의 어떤 스크립트도 `PATCH`/`DELETE` × {`pulls/{n}/reviews/{id}`, `pulls/{n}/comments/{id}`, `issues/comments/{id}`} 6개 endpoint 를 호출하지 않는다 — `_common.sh` 상단의 `FORBIDDEN ENDPOINTS` 주석 참조. 새 스크립트 추가 시에도 이 endpoint 사용 금지.

이 규칙은 Claude가 본 repo 또는 Gitea remote에 PR을 만들거나 review를 등록할 때 적용. 사용자가 "영어로", "english" 등을 명시하면 우회.
