---
name: gitea-ops
description: Use when the user wants to open, review, or merge a Gitea pull request, cut a Gitea release, file or close an issue, create a new Gitea repository, or mirror a Gitea repository to GitHub. Not for GitHub or GitLab APIs.
---

# gitea-ops

[`tea` CLI](https://gitea.com/gitea/tea) 기반으로 Gitea REST API를 호출하는 스크립트 모음이다. 의존성은 `tea`(0.14 이상), `jq`, `git`이다. release 서명에는 `sha256sum`과 `minisign`, 미러에는 `gh`, 저장소 생성에는 `curl`과 bitwarden-ops가 더 필요하다.

명령은 PATH에 없다. 항상 아래 표의 경로 그대로 실행한다. 호스트와 owner/repo는 현재 디렉토리의 git remote(`origin`)에서 자동으로 찾고, `-r owner/repo`와 `-u URL`(또는 `GITEA_URL`)로 바꿀 수 있다. 전체 옵션은 각 명령의 `--help`로 확인한다.

## 명령

| 명령 | 하는 일 |
|---|---|
| `${CLAUDE_SKILL_DIR}/bin/gitea-pr --title T --body B --head BRANCH [--base main] [--draft] [--assignee U]... [--label L]... [--no-lint] [--no-trailer]` | PR 생성. head가 로컬에만 있으면 먼저 push한다. 제목, 브랜치, 본문 lint에 실패하면 push와 생성을 모두 거부한다. `--no-lint`는 lint와 trailer를 함께 끈다. |
| `${CLAUDE_SKILL_DIR}/bin/gitea-pr-status <PR#> [--json] [--wait-ci]` | PR 사전 점검 항목과 CI 상태 출력 |
| `${CLAUDE_SKILL_DIR}/bin/gitea-pr-diff <PR#> [--raw] [--json]` | PR 메타데이터와 unified diff 출력(리뷰 분석용) |
| `${CLAUDE_SKILL_DIR}/bin/gitea-pr-review <PR#> --event EVENT [--body TEXT] [--inline FILE]` | 리뷰어 계정으로 리뷰 등록. EVENT는 `APPROVE`, `REQUEST_CHANGES`, `COMMENT` 중 하나다. `--body`와 `--inline` 중 하나 이상 필요하고, 값으로 `-`를 주면 stdin에서 읽는다 |
| `${CLAUDE_SKILL_DIR}/bin/gitea-pr-merge <PR#> [--style STYLE] [--delete-branch] [--ignore-missing-ci]` | PR 머지. STYLE은 `merge`(기본), `rebase`, `squash`다. 아래 머지 원칙을 따른다 |
| `${CLAUDE_SKILL_DIR}/bin/gitea-issue --title T [--body B] [--label L]... [--assignee U]... [--milestone ID]` | issue 생성. 번호와 URL 출력 |
| `${CLAUDE_SKILL_DIR}/bin/gitea-issue-close <NUMBER> [--comment TEXT]` | issue 닫기(코멘트 선택) |
| `${CLAUDE_SKILL_DIR}/bin/gitea-release <TAG> [--name T] [--notes TEXT] [--notes-file PATH] [--auto-notes] [--draft] [--prerelease] [--target COMMITISH] [--asset PATH]... [--sign KEYPATH]` | release 생성과 asset 업로드 |
| `${CLAUDE_SKILL_DIR}/bin/gitea-repo-create <이름> [--org ORG] [--user] [--public] [--description TEXT]` | 저장소 생성. 아래 저장소 생성 절을 따른다 |
| `${CLAUDE_SKILL_DIR}/bin/gitea-mirror-init`, `${CLAUDE_SKILL_DIR}/bin/gitea-mirror-push`, `${CLAUDE_SKILL_DIR}/bin/gitea-mirror-ls`, `${CLAUDE_SKILL_DIR}/bin/gitea-mirror-sync`, `${CLAUDE_SKILL_DIR}/bin/gitea-mirror-unlink` | GitHub 미러. `refs/mirror.md` 참고 |

명령별 세부 동작:

- `gitea-pr`: 본문 끝에 `Assisted-by: Claude Code` trailer를 붙인다. 이미 있으면 다시 붙이지 않으며 `--no-trailer`로 끈다.
- `gitea-pr-diff`: 기본 출력은 헤더(title, base, head, 변경 파일)와 diff다. `--raw`는 diff만, `--json`은 JSON 객체 하나를 출력한다. 출력을 파일로 저장할 때는 worktree 밖(`/tmp/`, `~/.cache/` 등)에 두고 `git add`하지 않는다. 실수로 stage했다면 같은 커밋 안에서 unstage하고 제거한다(정리용 커밋을 따로 만들지 않는다).
- `gitea-pr-review`: inline JSON은 `[{"path":"file.go","new_position":42,"body":"..."}]` 형식의 배열이다(`new_position` 대신 `old_position`도 된다). PR 작성자와 리뷰어가 같은 계정이면 422 self-review 오류가 난다.
- `gitea-release`: tag가 로컬에만 있으면 먼저 push한다. `--asset`마다 `<asset>.sha256`을 함께 올리고, `--sign`을 주면 `<asset>.minisig`도 올린다. `--auto-notes`는 직전 release 이후 머지된 PR 목록을 `## 변경사항 (since <tag>)` 절로 노트 맨 위에 넣는다(0건이면 넣지 않는다). `--notes`를 함께 주면 사용자 텍스트가 그 아래에 온다.

## 머지 원칙

- 사용자가 이 대화에서 명시적으로 머지를 요청했을 때만 `gitea-pr-merge`를 실행한다. "머지해", "리뷰하고 머지까지 해", "머지하고 정리해" 같은 요청이 여기에 해당한다. 머지라는 말 없이 "알아서 해"라고만 했다면 해당하지 않는다.
- 스스로 판단해 머지하지 않는다. 리뷰 반복이 APPROVE로 끝났어도 마찬가지다. 요청이 없으면 PR URL을 알려 주고 사용자가 Gitea 화면에서 머지하게 한다.
- `tea api`나 curl로 머지 API(`POST .../pulls/N/merge`)를 직접 부르지 않는다.
- `gitea-pr-merge`는 PR이 열려 있는지, draft가 아닌지, `mergeable`인지, CI가 없거나 성공했는지, 변경 요청(REQUEST_CHANGES) 리뷰가 남아 있지 않은지 확인한 뒤 머지한다. 워크플로 파일이 있는데 CI 상태가 0건이면 거부한다. 방금 push했다면 잠시 뒤 한 번 더 실행하고, 그래도 0건이면 그 워크플로가 PR에서 도는지 확인한다. PR에서 돌지 않는 워크플로(태그 push 전용 등)일 때만 `--ignore-missing-ci`를 붙인다. 거부되면 출력된 이유를 사용자에게 그대로 전하고 멈춘다. 재시도 반복문을 만들거나 다른 경로로 우회하지 않는다. CI가 진행 중이면 `gitea-pr-status <PR#> --wait-ci`로 기다린 뒤 한 번 더 실행하는 것은 괜찮다.
- 머지 후 로컬 정리는 `git worktree remove <path>`로 한다. 원격 브랜치는 `--delete-branch`로 지운다.

## 저장소 생성

- 저장소는 `gitea-repo-create`로만 만든다. author 토큰에는 저장소 생성에 필요한 `write:user`, `write:organization` scope가 없다. curl basic auth, 직접 API 호출, 다른 토큰으로 우회하지 않는다.
- 기본은 비공개이고 소유자는 `altair823-org`(`GITEA_DEFAULT_ORG`로 변경)다. 사용자가 공개나 개인 계정을 말했을 때만 `--public`, `--user`를 쓴다.
- 토큰은 Bitwarden 항목 `bw://GITEA_ADMIN_TOKEN/notes`(`GITEA_ADMIN_TOKEN_REF`로 변경)를 bitwarden-ops `bw-get`으로 읽는다. 금고가 잠겨 있으면 bitwarden-ops 안내를 따른다.
- 같은 이름의 저장소가 이미 있으면 새로 만들지 않고 URL만 출력한다. 출력은 웹 URL과 clone URL 두 줄이다.

## PR 작업 흐름

1. PR을 만들기 직전에 사용자에게 단발로 끝낼지, 리뷰 반복을 할지 묻는다.
2. `gitea-pr`로 PR을 만들고 출력된 URL을 보관한다.
3. 리뷰 반복을 고르면 `refs/review-loop.md` 절차를 따른다. 리뷰 반복은 리뷰어 로그인(`gitea-ops-reviewer`)이 있어야 한다. 없으면 `tea api`로 코멘트를 직접 등록하지 말고, 리뷰어 토큰이 없어 진행할 수 없다고 사용자에게 알린다.
4. 끝나면 PR URL을 알려 준다. 머지는 머지 원칙을 따른다.

## 참고 문서

- `refs/review-loop.md`: 리뷰 반복을 시작하기 전에 읽는다. PR 사전 점검, `gitea-pr-status` 출력 키와 종료 코드, 회차 규칙, 종료 조건, 안전 장치가 있다.
- `refs/writing-rules.md`: PR, issue, release, review 본문을 쓰기 전에 읽는다. 언어, 제목과 브랜치 정규식, 본문 구성, trailer, 리뷰 작성법, 등록한 코멘트를 고치지 않는 규칙, 다국어 본문 손상 확인 방법이 있다.
- `refs/mirror.md`: GitHub 미러를 만들거나 다룰 때 읽는다.

refs 문서에 나오는 명령 이름도 위 표의 경로로 실행한다.

## 인증

- **author 토큰**: tea 로그인 `gitea-ops-author`. 필요한 scope는 `read:user`(tea 검증용), `write:repository`, `write:issue`, `write:package`(release asset)다.
- **reviewer 토큰**: 별도 계정의 tea 로그인 `gitea-ops-reviewer`. scope는 `read:user`, `write:repository`다. 컴퓨터에 따라 없을 수 있으므로 리뷰 반복 전에 `tea logins ls`로 확인한다.
- 로그인이 없으면 첫 호출 때 `~/.config/gitea-ops/token`(author)이나 `~/.config/gitea-ops/reviewer-token`(reviewer) 파일, 또는 `GITEA_TOKEN`, `GITEA_REVIEWER_TOKEN` 환경변수로 자동 등록한다. 호스트는 git remote에서 찾고, 실패하면 `GITEA_URL`을 쓴다. 로그인 이름은 `GITEA_LOGIN_AUTHOR`, `GITEA_LOGIN_REVIEWER`로 바꿀 수 있다.
- 토큰 파일은 UTF-8(BOM 없음), mode 0600이어야 한다. PowerShell의 기본 `>`와 `Out-File`은 UTF-16 LE BOM으로 저장해 tea가 읽지 못한다. `Set-Content -Encoding utf8NoBOM`이나 `[IO.File]::WriteAllText()`를 쓴다.

## 오류 대응

- `tea logins add`가 `... required=[read:user]`로 실패: 토큰에 `read:user` scope가 없다. 토큰을 다시 발급한다.
- 401: 토큰이 만료되거나 회수됐다. `tea logins edit`로 새 토큰을 넣거나, 파일을 갱신한 뒤 `tea logins delete <name>` 후 다시 등록한다.
- 403: scope가 부족하다(예: `write:issue` 없이 issue 생성).
- `/repos/.../releases/tags/TAG` 404: tag가 아직 원격에 없다. `gitea-release`가 push한 뒤 한 번 다시 시도한다.
- `lint failed: title does not match ^(feat|fix|...)...`: PR 제목을 `feat(scope): ...` 형식으로 고친다. 여러 영역에 걸친 변경이면 scope를 생략해도 된다.
- `lint failed: branch does not match ^(feat|fix|...)/...`: `git branch -m <새 이름>`으로 바꾼 뒤 다시 push한다.
- `lint failed: body missing required header ## 요약`: `## 요약`, `## 검증` 헤더를 넣고 `## 요약` 아래에 1자 이상 쓴다.

## 작업 후

- 만든 PR, issue, release, review, 저장소의 URL을 항상 출력해 사용자가 바로 열 수 있게 한다.
- 한국어 같은 다국어 본문을 등록했다면 다시 조회해 글자가 깨지지 않았는지 확인한다(`refs/writing-rules.md`).
- 등록한 리뷰와 코멘트는 수정하거나 삭제하지 않는다. 정정은 새 코멘트로 한다.
