---
name: harbor-ops
description: Use when the user wants to interact with a private Harbor container registry — browse (projects / repos / tags / scan summaries), create or delete projects, push a local image, or delete / promote tags. Read-only ops live in `harbor-ls`; write ops live in `harbor-project`, `harbor-login`, `harbor-push`, `harbor-tag`. All commands share a multi-profile config and use stored robot-account credentials. `harbor-push` runs in an isolated DOCKER_CONFIG so the user's `~/.docker/config.json` is never modified. Auto-detects project from Dockerfile / docker-compose / k8s manifests in cwd.
---

# harbor-ops

Browse and operate on a Harbor private container registry from the CLI. The
read path is in `harbor-ls`; the write path is split across `harbor-project`,
`harbor-login`, `harbor-push`, and `harbor-tag`. Zero deps beyond
`bash >= 4.3`, `curl`, `jq` (and optionally `numfmt` for human-readable
sizes; `docker` for `harbor-login` / `harbor-push`).

## When to use

- "What projects are on our Harbor?" → `harbor-ls projects`
- "List the tags of `myproj/api`" → `harbor-ls tags myproj/api`
- "Did the last image push pass the vulnerability scan?" → `harbor-ls scan ...`
- "Create a `playground` project" → `harbor-project create playground`
- "Push this nginx image into our `playground/nginx:v1`" → `harbor-push nginx:1.27 playground/nginx:v1`
- "Drop the old `staging:v1` tag" → `harbor-tag delete staging/api:v1`
- "Promote `staging/api:v1` to `prod/api:v1`" → `harbor-tag copy staging/api:v1 prod/api:v1`

Do NOT use for non-Harbor registries (Docker Hub, GHCR, ECR have different
APIs).

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

   `chmod 600 ~/.config/harbor-ops/config`. **Never commit this file** —
   secrets are inline. If you sync dotfiles, use the `_HARBOR_SECRET_FILE`
   variant and exclude the secret file from version control.

   **Quote values that contain `$`.** Robot account names look like
   `robot$<name>` and many secrets include `$`. Bash interprets unquoted
   `$foo` as a parameter expansion, which silently corrupts the credential.
   Always wrap such values in single quotes:

   ```
   prod_HARBOR_USER='robot$harbor-ls-readonly'
   prod_HARBOR_SECRET='abc$xyz'
   ```

3. Symlink the skill into Claude Code's skills dir:

   ```sh
   ln -sfn ~/claude-skills/harbor-ops ~/.claude/skills/harbor-ops
   ```

### Windows

Works on Git Bash 2.x (bash 4.4+) and WSL2. NTFS ignores `chmod`, so the
config file's mode-0600 protection is best-effort on native Git Bash; rely
on user-directory ACLs.

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

Persistent `docker login` against the active Harbor host using the stored
config credentials. Modifies `~/.docker/config.json` — call this when you
explicitly want a long-lived docker session. For one-shot pushes use
`harbor-push` instead, which leaves the user's docker config untouched.

### `harbor-push` (write)

```
harbor-push <local-image> <project>/<repo>:<tag> [--profile <name>]
```

Tags `<local-image>` for the active Harbor host and pushes it. Internally
sets `DOCKER_CONFIG` to a fresh tmpdir for the duration of the command, so
any login state created here is discarded on exit and the user's
`~/.docker/config.json` is never touched.

### `harbor-tag` (write)

```
harbor-tag delete <project>/<repo>:<tag> [--yes]
harbor-tag copy   <src-project>/<src-repo>:<src-tag> <dst-project>/<dst-repo>:<dst-tag>
```

`delete` removes the tag pointer (the underlying artifact survives if other
tags reference it). `copy` uses Harbor's `POST /artifacts?from=...` to
promote across projects/repos without re-uploading any blob.

### Project auto-detection

When a subcommand needs `<project>` (or `<project>/<repo>`) and the user
omitted it, the skill walks up from cwd to the git root (or `$HOME`),
scanning `Dockerfile`, `docker-compose.{yml,yaml}`, `compose.{yml,yaml}`,
and `*.{yml,yaml}` files containing an `image:` key, in lexicographic
order. The first reference matching `<host>/<project>/<repo>(:<tag>)?`
where `<host>` is the active profile's Harbor host wins.

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

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | API error (network, 4xx other than auth, 5xx, malformed response) |
| 2 | Config or auth error |
| 3 | Project auto-detect failed |
| 4 | Invalid argument |
