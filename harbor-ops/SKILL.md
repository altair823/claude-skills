---
name: harbor-ops
description: Use when the user wants to interact with a private Harbor container registry — browse (projects / repos / tags / scan summaries), create or delete projects, push a local image, or delete / promote tags. Read-only ops live in `harbor-ls`; write ops live in `harbor-project`, `harbor-login`, `harbor-push`, `harbor-tag`. All commands share a multi-profile config and use stored robot-account credentials. `harbor-push` runs in an isolated DOCKER_CONFIG so the user's `~/.docker/config.json` is never modified. Auto-detects project from Dockerfile / docker-compose / k8s manifests in cwd.
---

# harbor-ops

Harbor private registry CLI. Read: `harbor-ls`. Write: `harbor-project`, `harbor-login`, `harbor-push`, `harbor-tag`. Deps: `bash >= 4.3`, `curl`, `jq` (+ `numfmt` for sizes; `docker` for login/push).

## When to use

- "What projects/repos/tags are on Harbor?" → `harbor-ls projects|repos|tags`
- "Did the scan pass?" → `harbor-ls scan <project>/<repo>:<tag>`
- "Create/delete a project" → `harbor-project create|delete <name>`
- "Push image to Harbor" → `harbor-push <local> <project>/<repo>:<tag>`
- "Delete/promote a tag" → `harbor-tag delete|copy ...`

Do NOT use for non-Harbor registries (Docker Hub/GHCR/ECR have different APIs).

## Pre-flight check

Before the first authenticated call: deps (`curl jq` + `docker` for login/push) + config file is UTF-8 no BOM + mode 0600. The config is shell-sourced — a BOM corrupts the first variable name and silently breaks auth.

**PowerShell pitfall**: default `>` / `Out-File` writes UTF-16 LE BOM. Use `Set-Content -Encoding utf8NoBOM` or `[IO.File]::WriteAllText()`.

## Setup

1. Generate a CLI Secret in Harbor: *User Profile → CLI Secret → Generate*.
   For CI, use a robot account secret instead.

2. Create `~/.config/harbor-ops/config` (mode `0600`):

   ```
   HARBOR_DEFAULT_PROFILE=prod

   prod_HARBOR_URL=https://harbor.example.com
   prod_HARBOR_USER=alice
   prod_HARBOR_SECRET=<cli-secret-or-robot-secret>

   # Optional: more profiles
   staging_HARBOR_URL=https://harbor-staging.example.com
   staging_HARBOR_USER=alice
   staging_HARBOR_SECRET_FILE=~/.config/harbor-ops/secrets/staging
   ```

   `chmod 600 ~/.config/harbor-ops/config`. **Never commit** — secrets inline. For dotfile sync use the `_HARBOR_SECRET_FILE` variant + exclude the secret file from version control.

   **Quote `$` values**: robot accounts (`robot$<name>`) and many secrets contain `$`. Bash expands unquoted `$foo` and silently corrupts the credential. Always single-quote: `prod_HARBOR_USER='robot$readonly'`, `prod_HARBOR_SECRET='abc$xyz'`.

3. Symlink the skill into Claude Code's skills dir:

   ```sh
   ln -sfn ~/claude-skills/harbor-ops ~/.claude/skills/harbor-ops
   ```

### Windows

Git Bash 2.x (bash 4.4+) / WSL2 OK. NTFS ignores `chmod` — mode-0600 best-effort on native Git Bash; rely on user-directory ACLs.

## Binaries

### `harbor-ls` (read)

```
harbor-ls projects                          List all projects
harbor-ls repos    [<project>]              List repos in a project
harbor-ls tags     <project>/<repo>         List tags / artifacts
harbor-ls scan     <project>/<repo>:<tag>   Severity-count scan summary
```

Common flags:

| Flag | Effect |
|---|---|
| `--profile <name>` | Select a profile from config |
| `--json` | Emit JSON instead of a table |
| `--limit <N>` | Truncate results client-side |
| `--filter <glob>` | Glob match on the primary name field |
| `--no-detect` | Disable manifest-based project detection |
| `--debug` | Verbose stderr logging |

### `harbor-project` (write)

```
harbor-project create <name> [--public] [--yes]
harbor-project delete <name> [--yes]
harbor-project set-public <name> <true|false>
```

`create` defaults to private. `delete` requires confirmation (`--yes` or
an interactive tty). Project names must match Harbor's rule: lowercase
`[a-z0-9._-]`, 1–63 chars.

### `harbor-login` (write)

```
harbor-login [--profile <name>]
```

Persistent `docker login` to the active Harbor host. Modifies `~/.docker/config.json` — only for long-lived sessions. Use `harbor-push` for one-shot (it leaves user docker config untouched).

### `harbor-push` (write)

```
harbor-push <local-image> <project>/<repo>:<tag> [--profile <name>]
```

Tags `<local-image>` for the active Harbor host and pushes. Sets `DOCKER_CONFIG` to a fresh tmpdir for the call duration — login state discarded on exit, user's `~/.docker/config.json` untouched.

### `harbor-tag` (write)

```
harbor-tag delete <project>/<repo>:<tag> [--yes]
harbor-tag copy   <src-project>/<src-repo>:<src-tag> <dst-project>/<dst-repo>:<dst-tag>
```

`delete` removes the tag pointer (the underlying artifact survives if other
tags reference it). `copy` uses Harbor's `POST /artifacts?from=...` to
promote across projects/repos without re-uploading any blob.

### Project auto-detection

When `<project>` (or `<project>/<repo>`) is omitted, walks cwd → git root / `$HOME` scanning `Dockerfile`, `docker-compose.{yml,yaml}`, `compose.{yml,yaml}`, `*.{yml,yaml}` (with `image:` key), lexicographic. First reference matching `<active-host>/<project>/<repo>(:<tag>)?` wins.

### Examples

Browse:

```sh
harbor-ls projects
harbor-ls projects --filter 'team-*'
harbor-ls repos myproj
harbor-ls tags myproj/api --limit 5
harbor-ls tags myproj/api --filter 'v1.*'
harbor-ls scan myproj/api:v1.2.0
```

Push a fresh nginx image into a new project:

```sh
docker pull nginx:1.27-alpine
harbor-project create playground
harbor-push nginx:1.27-alpine playground/nginx:v1
harbor-ls tags playground/nginx
```

Promote between projects + clean up the source tag:

```sh
harbor-tag copy staging/api:v1.2.0 prod/api:v1.2.0
harbor-tag delete staging/api:v1.2.0 --yes
```

## Exit codes

`0` success / `1` API error (network, 4xx non-auth, 5xx, malformed) / `2` config or auth error / `3` project auto-detect failed / `4` invalid argument.
