# remotedev-ops — Design Spec

Date: 2026-05-16
Status: Approved (pending implementation plan)

## Purpose

A self-contained skill that sets up and manages **remote builds on the dev
server (`devbox`)** for a local repo. Invoking it from a repo writes a
`.remotedev` config, detects the build system, fills sensible build/test/run
verbs and artifact paths, swaps repo-local Gradle/Maven launchers, and hides
those changes from git — so that the existing **remotedev** project's PATH
shim transparently builds that repo on `devbox`.

Mirrors the shape of the sibling `gitea-ops` / `harbor-ops` skills: a small
set of bash scripts wrapping standard tools (`ssh`, `rsync`, `git`), with a
zero-dependency test suite. Installed via symlink into `~/.claude/skills/`.

Out of scope:

- The remote-build interception mechanism itself. That is the **remotedev**
  project (`~/projects/remotedev`: `rd-exec`/`rd-shim`/`rd`, the PATH shim).
  This skill only produces the `.remotedev` config and launcher swaps it
  consumes. Converting that structural interception into a skill is
  explicitly rejected (it would lose offline/script/human/nested-call
  coverage — see remotedev DESIGN.md D2).
- Running builds. `rd build` etc. remain the remotedev project's job.
- Interactive prompting during `init`. Detection is deterministic and
  non-interactive; ambiguous values are written as comments to edit later.
- Multi-host orchestration. One host per repo (default `devbox`).

## Scope of v1

| Subcommand | Purpose |
|---|---|
| `remotedev-init [HOST]` | Detect build system, write `.remotedev`, probe ssh, swap+git-hide Gradle/Maven launchers |
| `remotedev-status` | Read-only summary: config, launcher-swap state, ssh reachability, shim-on-PATH |
| `remotedev-verify` | Standalone `rsync` push → `ssh` exec → pull round-trip against the configured host |
| `remotedev-disable [--purge]` | Reverse launcher swap, clear git-hide; `--purge` also removes `.remotedev` |

Default `HOST` is `devbox` (matches `~/projects/remotedev/.remotedev.example`).
`remotedev-init` accepts `--force` to overwrite an existing `.remotedev`.

## Repo Layout

```
remotedev-ops/
├── SKILL.md
├── bin/
│   ├── _common.sh        # repo-root resolve, .remotedev read/parse,
│   │                     # ssh reachability probe, logging, git-hide helpers
│   ├── remotedev-init
│   ├── remotedev-status
│   ├── remotedev-verify
│   └── remotedev-disable
└── tests/
    ├── lib.sh            # zero-dep assertions + fake ssh/rsync (mirror
    │                     # gitea-ops/tests/lib.sh and the remotedev harness)
    ├── test_init_cargo.sh
    ├── test_init_idempotent.sh
    ├── test_init_gradle_swap.sh
    ├── test_init_offline.sh
    ├── test_init_no_buildsystem.sh
    ├── test_init_contract.sh
    ├── test_status.sh
    └── test_disable.sh
```

Installed like the siblings:
`ln -s ~/claude-skills/remotedev-ops ~/.claude/skills/remotedev-ops`.

## Components & Behavior

### `_common.sh`

Shared helpers, sourced by every verb script:

- `repo_root` — `git rev-parse --show-toplevel`, else `$PWD` (warn: git-hide
  steps will be skipped).
- `host_up HOST` — `ssh -o BatchMode=yes -o ConnectTimeout=4 HOST true`
  (same probe as remotedev `rd-exec`).
- `read_cfg` — source `.remotedev` into known vars for `status`/`verify`.
- `git_hide PATH` / `git_unhide PATH` — `git update-index --skip-worktree`
  on tracked files; `.git/info/exclude` entry for untracked ones; both
  idempotent and individually reversible.
- `log` / `warn` / `die` — stderr, `[remotedev] ` prefix.

### `remotedev-init [HOST] [--force]`

Data flow: `cwd → repo_root → detect markers → render .remotedev → ssh
probe → (Gradle/Maven) swap + git-hide → print summary + next steps`.

1. Resolve root. If `.remotedev` exists and no `--force`: print current
   config hint, exit 2 (idempotent, non-destructive).
2. Detect build system by marker file and fill verbs/artifacts:

   | Marker | BUILD / TEST / RUN | Artifact |
   |---|---|---|
   | `Cargo.toml` | `cargo build --release` / `cargo test` / `cargo run --release` | `target/release/<name>` (name from `Cargo.toml`; comment if not parseable) |
   | `pom.xml` | `./mvnw -q package` / `./mvnw test` / — | `target/*.jar` (commented — glob) |
   | `build.gradle[.kts]` | `./gradlew build` / `./gradlew test` / — | `build/libs/*.jar` (commented) |
   | `go.mod` | `go build ./...` / `go test ./...` / `go run .` | — |
   | `package.json` | `<pm> run build` / `<pm> test` / — (`pm` from lockfile: pnpm/yarn/bun/npm) | — |
   | `pyproject.toml`/`uv.lock` | — / `uv run pytest` / — | — |
   | none | all three commented placeholders | — |

   Certain values are written uncommented; genuinely ambiguous ones
   (jar globs, binary name) as comments. "Fill defaults", non-interactive.
3. Write `.remotedev` from an internal heredoc template conforming to the
   **Config Contract** below, with `REMOTEDEV_HOST="$HOST"`.
4. `host_up`. If down: keep the written `.remotedev` (offline-first),
   `warn` + suggest `remotedev-verify` once online, continue (exit 0).
5. If `gradlew`/`mvnw` present: swap each — `mv gradlew gradlew.real`,
   copy the wrapper from the remotedev project's `templates/`
   (`~/projects/remotedev/templates/gradlew`; if that path is absent, emit
   the wrapper from an embedded copy so the skill stays self-contained),
   `chmod +x`. Then `git_hide gradlew.real`, `git_hide gradlew`, and
   `git_hide .remotedev`. If `gradlew.real` already exists: treat as
   already-swapped, skip (idempotent). If `gradlew` missing but
   `gradlew.real` present: restore the wrapper only.
6. Print summary (host, detected system, verbs, artifacts, swap state) and
   next steps.

### `remotedev-status`

Read-only. Prints: `.remotedev` presence + parsed host/remote-dir/verbs/
artifacts; launcher-swap state (`gradlew.real`/`mvnw.real` present, wrapper
in place); `host_up` result (up/down); whether the remotedev shim dir is on
`PATH` (best-effort: `REMOTEDEV_SHIM_DIR` set and on `PATH`). No mutation.
Exit 0 always (it is a report); absence of config is stated, not an error.

### `remotedev-verify`

Standalone end-to-end check against the configured host — does **not** call
`rd-exec` (self-contained). Reuses the remotedev `test/remote-smoke.sh`
logic inline: unique remote dir `remotedev/rd-verify-$$`, `rsync` push of a
marker, `ssh` exec writing a result, pull it back, assert it came from the
remote host; `trap` removes the remote dir on exit. Non-zero exit + printed
diagnostics on failure. Requires `.remotedev` (else die, exit 2).

### `remotedev-disable [--purge]`

Reverse of `init`, idempotent: for each launcher, if `*.real` exists →
`mv *.real <launcher>`, `git_unhide` both. `git_unhide .remotedev`. With
`--purge` also `rm .remotedev`. If nothing set up: no-op message, exit 0.

## Config Contract

The boundary between this skill and the remotedev runtime is the `.remotedev`
file format. Canonical reference: `~/projects/remotedev/.remotedev.example`.
v1 variables:

- `REMOTEDEV_HOST` (required)
- `REMOTEDEV_REMOTE_DIR` (optional)
- `REMOTEDEV_EXCLUDES` (optional array)
- `REMOTEDEV_ARTIFACTS` (optional array)
- `BUILD_CMD` / `TEST_CMD` / `RUN_CMD` (optional)

`remotedev-init` MUST emit only these. `test_init_contract.sh` asserts every
assignment in a generated `.remotedev` is one of the above, catching drift if
the runtime's format changes. SKILL.md notes the canonical reference path.

## Error Handling

| Case | Behavior |
|---|---|
| `.remotedev` exists, no `--force` | exit 2, hint `status`/`--force` |
| Not a git repo | root=cwd, skip git-hide, warn, continue |
| Host unreachable at `init` | write config anyway, warn, exit 0 |
| `gradlew.real` already present | skip swap (idempotent) |
| `gradlew` gone, `gradlew.real` present | restore wrapper only |
| launcher not tracked by git | `.git/info/exclude` only (no skip-worktree) |
| No build system detected | generic commented `.remotedev`, exit 0 + note |
| `disable` with nothing set up | no-op, exit 0 |
| `verify` failure | trap-cleanup remote dir, non-zero exit + diagnostics |
| remotedev `templates/` absent | emit embedded wrapper (stay self-contained) |

## Testing

Zero-dependency bash, mirroring `gitea-ops/tests/` and the remotedev harness
(fake `ssh`/`rsync` on `PATH`, temp git repos). No server required for the
suite; `verify` is covered by a server-gated case (`REMOTEDEV_TEST_HOST`).

- `test_init_cargo` — Cargo repo → `.remotedev` has cargo verbs +
  `REMOTEDEV_HOST=devbox`.
- `test_init_idempotent` — second `init` exits 2; `--force` overwrites.
- `test_init_gradle_swap` — fake `gradlew` + `git init` → swapped,
  `gradlew.real` exists, `gradlew` is the wrapper, `git status` clean for
  `gradlew` (skip-worktree), `gradlew.real`/`.remotedev` excluded.
- `test_init_offline` — `host_up` fails (fake ssh) → `.remotedev` still
  written, warning emitted, exit 0.
- `test_init_no_buildsystem` — bare dir → generic commented template.
- `test_init_contract` — generated `.remotedev` assignments ⊆ contract.
- `test_status` — reflects config + swap + reachability accurately.
- `test_disable` — restores launcher, clears skip-worktree/exclude,
  idempotent; `--purge` removes `.remotedev`.

## Dependencies

`ssh`, `rsync`, `git`, coreutils. No dependency on the remotedev project
being installed for `init`/`status`/`disable`/`verify` (all use only the
above). The remote-build *runtime* (PATH shim) is provided separately by the
remotedev project; SKILL.md links it for context only.
