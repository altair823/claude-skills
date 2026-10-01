# GitHub 미러

Gitea 저장소를 GitHub로 미러링하는 방법은 두 가지다.

- **지속 미러** (`gitea-mirror-init`): GitHub 저장소를 만들고 Gitea에 push mirror를 등록한다. 이후 주기적으로(기본 8시간, `sync_on_commit=true`) 자동 동기화된다. 포트폴리오용 공개 저장소는 보통 이 방식을 쓴다.
- **일회성 push** (`gitea-mirror-push`): 주기 동기화 없이 한 번만 push한다. 개발 브랜치를 잠시 미러링할 때 쓴다.

명령은 SKILL.md 명령 표에 적힌 경로(이 스킬의 `bin/` 디렉토리)로 실행한다. PATH에는 없다.

## 추가 의존성과 셋업

미러 명령만 `gh` CLI(2.x 이상)가 필요하다. `gh repo create`, `gh repo view`를 부르며, release, PR, issue 명령은 `gh`가 없어도 된다.

1. **GitHub PAT**: Fine-grained PAT를 만들고 미러 대상 저장소에만 `contents:write` 권한을 준다. 이 PAT는 gh CLI 인증 토큰과 별개이며, Gitea가 GitHub로 push할 때 쓰도록 Gitea 쪽에 저장된다.
2. **PAT 위치**: `~/.config/gitea-ops/github-mirror-token`(mode 0600), `GITHUB_MIRROR_TOKEN` 환경변수, `--token`이나 `--token-file` 중 하나.
3. **gh CLI 인증**: `gh auth login`을 하고, 필요하면 `gh auth setup-git`도 실행한다.

## 공개 미러 보호

`--public` 미러는 git history 전체를 영구히 공개한다. 그래서 `gitea-mirror-init`과 `gitea-mirror-push`는 실행 직전에 `git log --all -p`에서 비밀값 패턴을 정규식으로 검사한다. 대상은 password, api_key, token, private_key, aws, client_secret 뒤에 `=`이나 `:`가 오고, 따옴표 안에 8자 이상의 값이 있는 줄이다.

의심 패턴을 찾으면 기본 동작은 중단이다. 사용자가 결정한 뒤 다음 중 하나로 다시 실행한다.

- `--no-secret-scan`: 검사를 생략한다. 비밀값이 없다고 확신할 때만 쓴다.
- `--force-secret-scan`: 오탐(false positive)임을 확인한 뒤 그대로 진행한다.
- history를 정리(filter-repo)한 뒤 다시 실행한다.

오탐이 잦은 경로(`*.md`, `docs/**`)는 pathspec(`-- ':!*.md' ':!docs/**'`)으로 검사에서 제외한다. 변수 확장만 있는 줄(`"$VAR"`, `"${VAR}"`, bash 간접 참조 `"${!VAR}"` 포함)도 자동으로 제외한다.

## 명령

### `gitea-mirror-init`

```
gitea-mirror-init [--gitea-repo owner/repo] [--gh-repo OWNER/NAME]
                  (--public|--private) [--token-file PATH | --token TOKEN]
                  [--interval 8h0m0s] [--no-sync-on-commit]
                  [--no-secret-scan] [--force-secret-scan]
                  [--description TEXT] [--skip-create]
```

`--gh-repo`를 주지 않으면 `<gh 사용자>/<Gitea 저장소 이름>`을 쓴다. GitHub 저장소가 이미 있으면 중단한다. 다른 이름으로 다시 실행하거나, `--skip-create`로 기존 저장소에 push mirror만 등록한다(이때 공개 여부와 description은 무시한다). 등록 직후 첫 동기화를 시작하며, 실패해도 경고만 출력한다(다음 주기에 다시 시도한다).

### `gitea-mirror-push`

```
gitea-mirror-push --gh-repo OWNER/NAME [--force-mirror]
                  [--no-secret-scan] [--force-secret-scan]
```

기본 동작은 `git push --all --tags`다. force push를 하지 않으므로 fast-forward가 안 되면 거부된다. 삭제한 branch와 tag는 GitHub에 그대로 남는다(`--prune`을 쓰지 않는다). `--force-mirror`는 `git push --mirror`로 모든 ref를 강제로 덮어쓰므로, 협업자가 GitHub에 직접 올린 커밋이 사라질 수 있다. 현재 디렉토리가 git working copy여야 하고 GitHub 저장소가 이미 있어야 한다.

### `gitea-mirror-ls`

```
gitea-mirror-ls [--gitea-repo owner/repo] [--json]
```

### `gitea-mirror-sync`

```
gitea-mirror-sync [--gitea-repo owner/repo]
```

저장소의 모든 push mirror를 한꺼번에 동기화한다. Gitea API가 mirror 하나만 골라 동기화하는 기능을 지원하지 않기 때문이다.

### `gitea-mirror-unlink`

```
gitea-mirror-unlink <mirror-name> [--gitea-repo owner/repo]
```

`<mirror-name>`은 `gitea-mirror-ls` 출력의 첫 번째 열이다. GitHub 저장소 자체는 지우지 않는다. 지우려면 `gh repo delete`를 따로 실행한다.
