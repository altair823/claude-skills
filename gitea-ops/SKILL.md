---
name: gitea-ops
description: Drive Gitea via REST API from the CLI — create releases with minisign/sha256 assets, open PRs, file/close issues. Use when the user asks to cut a release, open a PR, or file/close an issue on a Gitea remote. Auto-detects host + repo from the current git remote; falls back to ~/.config/gitea-ops/config.
---

# gitea-ops

Thin wrapper around Gitea's REST API. Zero deps beyond `curl`, `jq`, `git`, and
(for release signing) `sha256sum` + `minisign`.

## When to use

Invoke when the user wants any of:
- Cut a tagged release and attach binary artifacts (with sha256 + minisign)
- Open a pull request programmatically
- File or close an issue programmatically
- Bulk-query issues/PRs for a Gitea repo

Do NOT use for GitHub/GitLab — different API shape.

## Setup

1. Personal Access Token: generate at `https://<host>/user/settings/applications`
   with scopes **repository**, **issue**, **package** (for release assets).
2. Store token: `~/.config/gitea-ops/token` (mode 0600) **or** `GITEA_TOKEN` env.
3. Optional defaults: `~/.config/gitea-ops/config` with
   ```
   GITEA_URL=https://gitea.example.com
   GITEA_REPO=owner/repo
   ```
   When `origin` remote matches the Gitea URL these are auto-derived.

## Scripts

Every script auto-detects host + repo from `git remote get-url origin` if
invoked inside a working copy whose origin points at a Gitea host. Override
with `-u <URL>` / `-r <owner/repo>`.

### `gitea-release`

```
gitea-release <TAG> [--name TITLE] [--notes TEXT | --notes-file PATH] [--auto-notes]
              [--draft] [--prerelease] [--target COMMITISH]
              [--asset PATH]... [--sign KEYPATH]
              [-r owner/repo] [-u URL]
```

- Pushes the tag if it exists locally but not on remote.
- Creates the release.
- For each `--asset`, also uploads `<asset>.sha256` (auto-generated) and,
  if `--sign KEYPATH` given, `<asset>.minisig`.
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

Pushes `--head` if it exists locally but not on remote, then opens the PR.

### `gitea-pr-merge`

```
gitea-pr-merge <PR#> [options]

Options:
  --method <merge|squash|rebase>   Merge strategy (default: merge)
  --keep-branch                    Keep remote head branch after merge
  --keep-worktree                  Keep local worktree after merge
  --worktree <path>                Explicit worktree path (default: cwd)
  -r owner/repo                    Override target repo
  -u URL                           Override Gitea base URL
```

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

Prints created issue number + URL.

### `gitea-issue-close`

```
gitea-issue-close <NUMBER> [--comment "..."] [-r owner/repo] [-u URL]
```

## Error modes

- 401 → token missing/invalid. Tell user to check `~/.config/gitea-ops/token`.
- 403 → token lacks scope.
- 404 on `/repos/.../releases/tags/TAG` means tag not yet on remote — scripts
  handle this by pushing then retrying once.

## After actions

Always print the created object's URL so the user can click through.
