---
name: harbor-ops
description: Use when the user wants to browse a private Harbor container registry — list projects, list repos in a project, list tags / artifacts in a repo, or read the vulnerability-scan severity summary for an artifact. Read-only. Auto-detects project from Dockerfile / docker-compose / k8s manifests in cwd. Multi-profile config so a single setup can target several Harbor instances.
---

# harbor-ops

Read-only browse of a Harbor private container registry from the CLI. Single
binary `harbor-ls` with subcommands. Zero deps beyond `bash >= 4.3`, `curl`,
`jq` (and optionally `numfmt` for human-readable sizes).

## When to use

- "What projects are on our Harbor?"
- "List the tags of `myproj/api`"
- "Did the last image push pass the vulnerability scan?"
- "Show repos under project X"

Do NOT use for image push/pull (that's `docker`), for write operations
(creating projects, robot accounts, replication policies), or for
non-Harbor registries (Docker Hub, GHCR, ECR have different APIs).

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

## Subcommands

```
harbor-ls projects                          List all projects
harbor-ls repos    [<project>]              List repos in a project
harbor-ls tags     <project>/<repo>         List tags / artifacts
harbor-ls scan     <project>/<repo>:<tag>   Severity-count scan summary
```

### Common flags

| Flag | Effect |
|---|---|
| `--profile <name>` | Select a profile from config |
| `--json` | Emit JSON instead of a table |
| `--limit <N>` | Truncate results client-side |
| `--filter <glob>` | Glob match on the primary name field |
| `--no-detect` | Disable manifest-based project detection |
| `--debug` | Verbose stderr logging |

### Project auto-detection

When a subcommand needs `<project>` (or `<project>/<repo>`) and the user
omitted it, the skill walks up from cwd to the git root (or `$HOME`),
scanning `Dockerfile`, `docker-compose.{yml,yaml}`, `compose.{yml,yaml}`,
and `*.{yml,yaml}` files containing an `image:` key, in lexicographic
order. The first reference matching `<host>/<project>/<repo>(:<tag>)?`
where `<host>` is the active profile's Harbor host wins.

### Examples

```sh
harbor-ls projects
harbor-ls projects --filter 'team-*'
harbor-ls repos myproj
harbor-ls tags myproj/api --limit 5
harbor-ls tags myproj/api --filter 'v1.*'
harbor-ls scan myproj/api:v1.2.0
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | API error (network, 4xx other than auth, 5xx, malformed response) |
| 2 | Config or auth error |
| 3 | Project auto-detect failed |
| 4 | Invalid argument |
