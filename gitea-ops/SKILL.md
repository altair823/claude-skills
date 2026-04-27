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
gitea-pr --title "Add widget" --head feat/widget

# 2. 리뷰어 (별도 Claude 세션, reviewer-token):
gitea-pr-diff 42                    # 분석용 meta+diff dump
gitea-pr-review 42 --event APPROVE \
    --body "Approved. Logic sound."

# 3. Author merges (gate auto-checks for APPROVED review):
gitea-pr-merge 42                   # gate 통과, merge, cleanup
```

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

### `gitea-pr-merge`

```
gitea-pr-merge <PR#> [options]

Options:
  --method <merge|squash|rebase>   merge 방식 (기본: merge)
  --force                          review gate 우회
  --keep-branch                    원격 head branch 보존
  --keep-worktree                  로컬 worktree 보존
  --worktree <path>                명시적 worktree 경로 (기본: cwd)
  -r owner/repo                    repo 오버라이드
  -u URL                           Gitea base URL 오버라이드
```

**Review gate**: 머지 호출 직전 `GET /pulls/<n>/reviews`로 APPROVED & non-dismissed 리뷰가 1+개 있는지 확인. 없으면 거부, `--force`로 우회. PR이 이미 머지된 상태면 gate 자체를 스킵.

기본 동작 (한 번에 끝내기):
1. `GET /pulls/<n>`로 PR 메타 조회 (이미 머지면 머지 호출 스킵)
2. `POST /pulls/<n>/merge` (`Do: merge|squash|rebase`)
3. `git push origin --delete <head_ref>` — 실패는 경고만
4. cwd가 head branch worktree면 main worktree로 cd → `git fetch --prune && git checkout main && git pull` → `git worktree remove <path>`

cwd가 main worktree이거나 head 브랜치가 아닌 곳이면 cleanup 자동 스킵 — 안전.

예시:
```sh
gitea-pr-merge 42                  # 기본: merge + branch 삭제 + worktree 정리
gitea-pr-merge 42 --method squash
gitea-pr-merge 42 --keep-branch    # 브랜치 유지 (worktree만 정리)
```

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

## 작업 후

생성된 object의 URL을 항상 출력해 사용자가 클릭으로 이동할 수 있게 함.

## 작성 규칙

Claude가 본 skill을 통해 PR/release/issue/review를 작성할 때 따르는 기본 규칙:

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

이 규칙은 Claude가 본 repo 또는 Gitea remote에 PR을 만들거나 review를 등록할 때 적용. 사용자가 "영어로", "english" 등을 명시하면 우회.
