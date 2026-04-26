# harbor-ops — Design Spec

Date: 2026-04-25
Status: Approved (pending implementation plan)

## Purpose

Read-only browse of a Harbor private container registry from the CLI. Mirrors the
shape of the existing `gitea-ops` skill: a small set of bash scripts that wrap
the Harbor REST API with `curl` + `jq`. Single binary `harbor-ls` with
subcommands (`projects`, `repos`, `tags`, `scan`).

Out of scope:

- Image promotion / replication / cross-project copy
- Vulnerability CVE-level reports (only severity counts surfaced)
- Project / repo admin (create / delete / quota / robot accounts)
- Webhook / replication policy management
- Any write operations

## Scope of v1

| Subcommand | Purpose |
|---|---|
| `harbor-ls projects` | List projects in the active Harbor instance |
| `harbor-ls repos [<project>]` | List repositories in a project |
| `harbor-ls tags <project>/<repo>` | List tags / artifacts of a repository |
| `harbor-ls scan <project>/<repo>:<tag>` | Show severity-count summary of the scan overview |

## Repo Layout

```
harbor-ops/
├── SKILL.md
├── bin/
│   ├── _common.sh         # config load, profile resolve, http GET, paginate,
│   │                      # project detect, output renderer
│   └── harbor-ls          # dispatch: projects | repos | tags | scan
└── tests/
    ├── lib.sh             # assertions + curl stub (mirror gitea-ops/tests/lib.sh)
    ├── test_config_profile.sh
    ├── test_project_detect.sh
    ├── test_pagination.sh
    ├── test_harbor_ls_projects.sh
    ├── test_harbor_ls_repos.sh
    ├── test_harbor_ls_tags.sh
    ├── test_harbor_ls_scan.sh
    └── test_auth_errors.sh
```

Symlinked into Claude Code skills dir:

```sh
ln -sfn ~/claude-skills/harbor-ops ~/.claude/skills/harbor-ops
```

`README.md` at repo root gets a one-line entry under `## Skills`.

## Dependencies

Runtime: `curl`, `jq`, `bash >= 4.3` (for indirect parameter expansion
`${!var}`), `numfmt` (optional, used for human-readable size; falls back to raw
bytes when missing).

The shebang for `bin/harbor-ls` and `bin/_common.sh` is
`#!/usr/bin/env bash` — explicitly bash, not POSIX `sh`. Tests run under bash.

Windows: Git Bash 2.x (bash 4.4+) and WSL2 both supported. NTFS perm semantics
for the config file are best-effort (chmod is applied but ignored by Windows);
the README setup section calls this out.

## Configuration

Single file at `~/.config/harbor-ops/config`, mode `0600`,
bash-sourceable `KEY=VALUE`. Profiles are namespaced by a prefix on the
variable name, avoiding any need for an INI parser.

```
# ~/.config/harbor-ops/config
HARBOR_DEFAULT_PROFILE=prod

# --- profile: prod ---
prod_HARBOR_URL=https://harbor.example.com
prod_HARBOR_USER=altair
prod_HARBOR_SECRET=<cli-secret-or-robot-secret>
# Or, secret in a separate file:
# prod_HARBOR_SECRET_FILE=~/.config/harbor-ops/secrets/prod

# --- profile: staging ---
staging_HARBOR_URL=https://harbor-staging.example.com
staging_HARBOR_USER=altair
staging_HARBOR_SECRET_FILE=~/.config/harbor-ops/secrets/staging
```

### Profile resolution (in priority order)

1. `--profile <name>` flag
2. `HARBOR_PROFILE` environment variable
3. `HARBOR_DEFAULT_PROFILE` from the config file
4. If exactly one `<name>_HARBOR_URL` exists in the config, use it
5. Otherwise: error (exit 2)

Lookup uses bash indirect expansion:

```bash
profile="prod"
url_var="${profile}_HARBOR_URL"
url="${!url_var}"
```

### Secret resolution

For the resolved profile:

1. `<profile>_HARBOR_SECRET` (inline in config) — preferred for simplicity
2. `<profile>_HARBOR_SECRET_FILE` — path read at runtime. On Linux/macOS/WSL,
   if the file's mode is not `0600` (or stricter), emit a stderr warning but
   still read the file. On Windows Git Bash (NTFS), the mode check is
   skipped silently.
3. Otherwise: error (exit 2)

### Auth header

HTTP Basic. Harbor accepts the user's CLI Secret, robot account secret, or
account password in the password slot. The CLI Secret is recommended for
interactive users (especially OIDC/LDAP, where the IdP password is rejected);
robot accounts are recommended for CI.

```
Authorization: Basic <base64(user:secret)>
```

### Security notes (surfaced in SKILL.md setup section)

- Never commit `~/.config/harbor-ops/config` to a dotfiles repo when secrets
  are inline. If the config is going into version control, use
  `<profile>_HARBOR_SECRET_FILE` and exclude the secret file.
- Generate a CLI Secret in Harbor under *User Profile → CLI Secret* — that's
  the only credential local Harbor accounts and OIDC/LDAP users can both use
  for the API.

## Project Auto-Detection

When a subcommand needs `<project>` (or `<project>/<repo>`) and the user
omitted it, scan local manifests for a reference to the active Harbor URL's
host and extract the project (and repo) from the matching image reference.

### Scan targets

Walk up from the current working directory to the git repository root (or to
`$HOME` if not in a git repo), checking these files at each level:

- `Dockerfile`, `Dockerfile.*`
- `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`
- `*.yaml`, `*.yml` files containing an `image:` key (Kubernetes manifests,
  Helm `values.yaml`)

### Match rule

Extract `<host>` from the active profile's `HARBOR_URL`. Match the regex:

```
<host>/(<project>)/(<repo>)(:<tag>)?
```

The first match wins. The matched `<project>` (and `<repo>` if needed) is
filled in. If the user passed `<repo>` only, only `<project>` is filled.

Determinism: at each directory level, files are visited in lexicographic
order; within a file, lines are scanned top-to-bottom. The scan stops at the
first match.

### Behavior

- `--no-detect` — skip the manifest scan entirely (useful in CI where an
  unrelated YAML might match by accident).
- `--debug` — log to stderr which file and line provided the match.
- No match → error: `project not detected from manifests; pass <project>
  explicitly` (exit 3).

## Subcommand Specifications

### Common flags

| Flag | Effect |
|---|---|
| `--profile <name>` | Select profile (overrides env + config default) |
| `--json` | Emit JSON instead of a table |
| `--limit <N>` | After fetching all pages, truncate to first N entries |
| `--filter <glob>` | Glob-match against the primary name field |
| `--no-detect` | Disable manifest-based project detection |
| `--debug` | Verbose stderr logging |
| `-h`, `--help` | Per-subcommand help |

### `harbor-ls projects [--filter G] [--limit N]`

- API: `GET /api/v2.0/projects` (paginated)
- Auto-detect: N/A
- Table columns: `NAME`, `ID`, `PUBLIC`, `REPO_COUNT`, `QUOTA_USED`, `CREATED`
- Filter target: project name

### `harbor-ls repos [<project>] [--filter G] [--limit N]`

- API: `GET /api/v2.0/projects/<project>/repositories` (paginated)
- Auto-detect: fills `<project>` if omitted
- Table columns: `NAME` (without project prefix), `ARTIFACT_COUNT`,
  `PULL_COUNT`, `UPDATED`
- Filter target: repository name

### `harbor-ls tags <project>/<repo> [--filter G] [--limit N]`

- API: `GET /api/v2.0/projects/<project>/repositories/<repo>/artifacts?with_tag=true&with_scan_overview=false`
  (paginated)
- Auto-detect: fills `<project>/<repo>` if argument is missing or only `<repo>`
- Table columns: `TAG`, `DIGEST` (12-char prefix), `PUSHED`, `SIZE`
- Multi-tag artifacts: emit one row per tag (same digest repeated)
- Untagged artifacts: shown as `<none>`
- Filter target: tag

### `harbor-ls scan <project>/<repo>:<tag>`

- API: `GET /api/v2.0/projects/<project>/repositories/<repo>/artifacts/<reference>?with_scan_overview=true`
  (`<reference>` = tag or digest)
- Output (table):
  ```
  PROJECT/REPO:TAG       STATUS       SCANNED              CRITICAL  HIGH  MEDIUM  LOW  UNKNOWN
  myproj/myrepo:v1.2.0   Success      2026-04-24 10:11Z         2     5       8    3        1
  ```
- Scanner selection: pick the lexicographically first key under
  `scan_overview` so output is stable across runs.
- Status pulled from `scan_overview.<scanner>.scan_status`
- Counts pulled from `scan_overview.<scanner>.summary.summary` (or
  `scan_overview.<scanner>.severity` map, whichever is present)
- Not yet scanned: `STATUS=Not Scanned`, all counts `-`
- `--filter` / `--limit`: not applicable (single artifact)
- `--json`: emits the raw `scan_overview` object

### Exit codes (all subcommands)

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | API error (network, 4xx other than auth, 5xx, malformed response) |
| 2 | Config or auth error (missing config, missing profile, 401, 403) |
| 3 | Project auto-detect failed |
| 4 | Invalid argument |

## Pagination

`_common.sh::harbor_get_paginated <path> [extra-query]`:

1. Issue `GET <path>?page=1&page_size=100&<extra-query>`.
2. Inspect response headers: `X-Total-Count` and `Link: ...; rel="next"`.
3. Concatenate JSON arrays across pages with `jq -s 'add'`.
4. Stop when no `next` link or accumulated count reaches `X-Total-Count`.
5. Hard cap: `MAX_PAGES=200` (= 20000 items at page_size 100). On hit, log a
   stderr warning `truncated at MAX_PAGES; results may be partial` and return
   what was collected.

Single-page responses short-circuit (no second request).

## Filter and Limit

- `--filter <glob>`: applied client-side after pagination, on the primary name
  field defined per subcommand. The glob is converted to a regex by first
  backslash-escaping every regex metacharacter (`. + ( ) [ ] { } ^ $ | \`),
  then substituting `*` → `.*` and `?` → `.`, then anchoring with `^...$`,
  then applied via `jq 'map(select(.<field> | test(<re>)))'`.
- `--limit <N>`: applied after filtering, via `jq '.[:N]'`.

## Output Rendering

`_common.sh::render` chooses based on `--json`:

- `--json` → `jq -c .` to stdout (one compact JSON line, or array).
- Default (table):
  1. The subcommand provides a column map (header → jq expression).
  2. Render TSV via `jq -r`.
  3. Pipe through `column -t -s $'\t'` for alignment.
  4. Prepend an uppercase header row.
- Empty result:
  - `--json` → `[]`
  - Table → header only, plus a `(no results)` note on stderr.

### Field formatting

- Timestamps: API returns ISO 8601 (`2026-04-20T10:11:23.456Z`). Tables show
  `YYYY-MM-DD HH:MMZ` (truncated via jq `sub`). JSON keeps the original.
- Sizes: API returns bytes. Tables show `numfmt --to=iec --suffix=B`
  (e.g. `1.2GiB`). If `numfmt` is missing, raw bytes; JSON always raw.
- Digests: 12-character prefix (`sha256:abcdef012345`) in tables; full digest
  in JSON.

## Error Handling

`set -euo pipefail` at the top of every script.

- HTTP error: invoke curl with `-w '%{http_code}'` and capture body separately.
  - 401, 403: `auth failed for profile <name> at <url>; check HARBOR_USER /
    HARBOR_SECRET`. Exit 2.
  - 404: `not found: <path>`. Exit 1.
  - Other 4xx, 5xx: emit status + URL + first 200 chars of the body. Exit 1.
- Network error (curl exit code != 0 from connect/DNS): `network error
  reaching <url>`. Exit 1.
- Detect failure: see Project Auto-Detection. Exit 3.
- Missing config / missing profile / missing keys: exit 2 with a message that
  names the missing variable.
- jq parse failure on a successful HTTP response: emit first 200 chars of the
  body and `unexpected response shape`. Exit 1.

### Logging

- Default: errors to stderr only.
- `--debug`: explicit stderr log lines (no `set -x` style trace) for:
  - Selected profile and source (flag / env / config default / sole)
  - Each URL hit (without secret)
  - Pagination page count
  - Project detection result (file path and matched line)
  - Table column map applied

## Testing

Mirrors `gitea-ops/tests/`:

- `tests/lib.sh` — assertions (`assert_eq`, `assert_contains`,
  `assert_exit_code`) plus a curl stub. The stub is a shell script earlier on
  `PATH` that responds from `$HARBOR_STUB_FIXTURES/<sha1-of-args>.json` and
  records each invocation in `$HARBOR_STUB_LOG`.
- Each test creates a `HOME=$tmpdir`, writes a fake config, populates fixture
  files, and runs `bin/harbor-ls` with the stub on PATH.
- No central runner: `bash tests/test_*.sh` runs each test directly (matching
  the gitea-ops convention).

### Test files

| File | Coverage |
|---|---|
| `test_config_profile.sh` | 4-step profile resolution; inline secret vs file; missing keys; sole-profile shortcut |
| `test_project_detect.sh` | Match in Dockerfile, compose, k8s yaml; walk-up to git root; `--no-detect`; host mismatch |
| `test_pagination.sh` | Follow `next` link; `X-Total-Count` termination; `MAX_PAGES` cap warning; single-page short-circuit |
| `test_harbor_ls_projects.sh` | Happy path (table), `--json`, `--filter`, `--limit`, empty result |
| `test_harbor_ls_repos.sh` | Explicit project, detect-fill, 404 project, `--filter` |
| `test_harbor_ls_tags.sh` | Multi-tag artifact split rows, untagged display, digest truncation, IEC size formatting |
| `test_harbor_ls_scan.sh` | Scanned summary, not-scanned status, scanner-key-agnostic pick |
| `test_auth_errors.sh` | 401 → exit 2, 403 → exit 2, 5xx → exit 1, network error |

## Distribution

- New directory `harbor-ops/` in this repo (`~/claude-skills`).
- README.md updated with a one-line entry under `## Skills`.
- Symlinked into `~/.claude/skills/harbor-ops` for Claude Code pickup.
- No separate Gitea release in v1.

## Open Questions

None at design time. Implementation plan to follow.
