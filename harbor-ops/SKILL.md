---
name: harbor-ops
description: Use when the user wants to browse a private Harbor container registry (projects, repositories, tags, scan results), create or delete a Harbor project, push a local image to Harbor, or delete or copy an image tag. Not for Docker Hub, GHCR, or ECR.
---

# harbor-ops

Harbor private registry CLI. Read: `harbor-ls`. Write: `harbor-project`, `harbor-login`,
`harbor-push`, `harbor-tag`. All of them live in `${CLAUDE_SKILL_DIR}/bin/` and are not on
PATH; call them by the full paths below. Deps: `bash >= 4.3`, `curl`, `jq` (+ `numfmt` for sizes,
`docker` for login/push).

## Config

`~/.config/harbor-ops/config` (mode 0600, shell-sourced). Recommended form: Bitwarden
references, so the file holds no secret.

```
HARBOR_DEFAULT_PROFILE=home
home_HARBOR_URL=https://harbor.altair823.xyz
home_HARBOR_USER_REF=bw://harbor.altair823.xyz/username
home_HARBOR_SECRET_REF=bw://harbor.altair823.xyz
```

- `_REF` values are read with the bitwarden-ops skill's `bw-get` (the sibling
  `bitwarden-ops` directory in the same repository; override with `HARBOR_BW_GET=<path>`).
  Values stay in process memory only.
- Precedence within a profile:
  - user: `<profile>_HARBOR_USER` > `<profile>_HARBOR_USER_REF`
  - secret: `<profile>_HARBOR_SECRET` > `<profile>_HARBOR_SECRET_FILE` > `<profile>_HARBOR_SECRET_REF`
- Profile: `--profile` > `HARBOR_PROFILE` env > `HARBOR_DEFAULT_PROFILE` > the only profile.
- `Bitwarden이 잠겨 있습니다` means the vault is locked. Ask the user to run the
  bitwarden-ops `bw-unlock` in their terminal, then retry. Do not work around it with raw
  `bw` calls or a manual `docker login`.
- Setting up a profile without Bitwarden (inline secret, secret file, robot account with
  `$`, Windows): read `${CLAUDE_SKILL_DIR}/refs/config.md`.

## Commands

### Read: `harbor-ls`

```
${CLAUDE_SKILL_DIR}/bin/harbor-ls projects                          List all projects
${CLAUDE_SKILL_DIR}/bin/harbor-ls repos    [<project>]              List repos in a project
${CLAUDE_SKILL_DIR}/bin/harbor-ls tags     <project>/<repo>         List tags / artifacts
${CLAUDE_SKILL_DIR}/bin/harbor-ls scan     <project>/<repo>:<tag>   Severity-count scan summary
```

| Flag | Effect |
|---|---|
| `--profile <name>` | Select a profile from config |
| `--json` | Emit JSON instead of a table |
| `--limit <N>` | Truncate results client-side |
| `--filter <glob>` | Glob match on the primary name field |
| `--no-detect` | Disable manifest-based project detection |
| `--debug` | Verbose stderr logging |

### Write: `harbor-project`

```
${CLAUDE_SKILL_DIR}/bin/harbor-project create <name> [--public] [--yes]
${CLAUDE_SKILL_DIR}/bin/harbor-project delete <name> [--yes]
${CLAUDE_SKILL_DIR}/bin/harbor-project set-public <name> <true|false>
```

`create` defaults to private. `delete` requires confirmation (`--yes` or an interactive
tty). Project names: lowercase `[a-z0-9._-]`, 1 to 63 chars.

### Write: `harbor-push`

```
${CLAUDE_SKILL_DIR}/bin/harbor-push <local-image> <project>/<repo>:<tag> [--profile <name>]
```

Tags `<local-image>` for the active Harbor host and pushes it. Logs in with a fresh
`DOCKER_CONFIG` tmpdir that is deleted on exit, so `~/.docker/config.json` is never
touched. The active docker context's endpoint (rootless or remote daemon) is kept.

### Write: `harbor-login`

```
${CLAUDE_SKILL_DIR}/bin/harbor-login [--profile <name>]
```

Persistent `docker login` to the active Harbor host. It modifies `~/.docker/config.json`,
so use it only for long-lived sessions. Prefer `harbor-push` for one-shot pushes.

### Write: `harbor-tag`

```
${CLAUDE_SKILL_DIR}/bin/harbor-tag delete <project>/<repo>:<tag> [--yes]
${CLAUDE_SKILL_DIR}/bin/harbor-tag copy   <src-project>/<src-repo>:<src-tag> <dst-project>/<dst-repo>:<dst-tag>
```

`delete` removes the tag pointer (the artifact survives if other tags reference it).
`copy` uses Harbor's `POST /artifacts?from=...` to promote across projects or repos
without re-uploading blobs.

### Project auto-detection

When `<project>` (or `<project>/<repo>`) is omitted, the tools walk from cwd up to the git
root (or `$HOME`) scanning `Dockerfile`, `docker-compose.{yml,yaml}`,
`compose.{yml,yaml}`, and `*.{yml,yaml}` with an `image:` key, in lexicographic order.
The first reference matching `<active-host>/<project>/<repo>(:<tag>)?` wins.

## Examples

```sh
${CLAUDE_SKILL_DIR}/bin/harbor-ls projects --filter 'team-*'
${CLAUDE_SKILL_DIR}/bin/harbor-ls tags myproj/api --limit 5
${CLAUDE_SKILL_DIR}/bin/harbor-ls scan myproj/api:v1.2.0

# Push a local image
${CLAUDE_SKILL_DIR}/bin/harbor-push nginx:1.27-alpine playground/nginx:v1

# Promote between projects, then remove the source tag
${CLAUDE_SKILL_DIR}/bin/harbor-tag copy staging/api:v1.2.0 prod/api:v1.2.0
${CLAUDE_SKILL_DIR}/bin/harbor-tag delete staging/api:v1.2.0 --yes
```

## Exit codes

`0` success / `1` API error (network, 4xx non-auth, 5xx, malformed) / `2` config, auth,
or locked Bitwarden / `3` project auto-detect failed / `4` invalid argument.
