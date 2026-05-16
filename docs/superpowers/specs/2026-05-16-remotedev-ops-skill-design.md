# remotedev-ops — Design Spec

Date: 2026-05-16
Status: Approved (pending implementation plan)

## Purpose

A single self-contained skill that delivers **remote builds on the dev
server (`devbox`)** end to end: it installs a transparent build-tool
interception layer once per machine, and per repo writes the config and
swaps repo-local launchers so that running an ordinary build command
(`cargo build`, `make`, `./gradlew build`, …) transparently builds on
`devbox`, with offline fallback to a local build.

There is **no separate runtime project**. The interception code lives in
this skill as embedded source under `runtime/`; the skill materializes it
into a shim directory and wires it onto `PATH`. After setup it runs
autonomously — without Claude, in a bare terminal, online or offline.
Mirrors the sibling `gitea-ops` / `harbor-ops` shape: small bash scripts
over standard tools (`ssh`, `rsync`, `git`), zero-dependency test suite,
installed by symlink into `~/.claude/skills/`.

Why an interception layer at all (not "just a skill that builds"): builds
are invoked by humans in terminals, by shell scripts, by nested tools
(`cmake`→`make`→`cargo`), and offline — none of which invoke a skill. A
`PATH`-first shim makes remote-vs-local **structural, not a convention**
(see Background). The skill's job is to install, configure, verify, and
fully reverse that layer.

Out of scope:

- Running builds interactively from the skill. Builds run through the
  installed shim, not a skill verb.
- Interactive prompting during setup. Detection is deterministic; ambiguous
  values are written as editable comments.
- Multi-host orchestration. One host per repo (default `devbox`).
- Mutagen / continuous sync. Possible later acceleration; v1 is `ssh`+`rsync`.

## Background

The interception model and its rationale come from prior `remotedev`
project work (its DESIGN.md D2): abstract the finite set of *build verbs*,
not the infinite set of tools; intercept the small set of top-level
entrypoints structurally via a `PATH`-first shim dir, so any caller —
human, script, AI, nested build tool — gets remote behavior without knowing
remotedev exists; offline / unreachable host falls back to a local build as
a first-class path. The runtime in `runtime/` is the hardened result of
that work (four fixes already implemented and tested: slash-path local
fallback, tty-aware `ssh -t`, skip artifact pull on remote-build failure,
per-repo `flock` around the remote critical section). This skill absorbs
that code and its installer; the standalone project is no longer required.

## Scope of v1

| Subcommand | Granularity | Purpose |
|---|---|---|
| `remotedev-install` | per machine | Create shim dir, symlink intercepted commands, wire shell rc `PATH` |
| `remotedev-uninstall` | per machine | Remove shim dir + the rc wiring block |
| `remotedev-init [HOST] [--force]` | per repo | Detect build system, write `.remotedev`, probe ssh, swap+git-hide Gradle/Maven launchers |
| `remotedev-disable [--purge]` | per repo | Reverse launcher swap + git-hide; `--purge` also removes `.remotedev` |
| `remotedev-status` | read-only | Machine install state + repo config/swap/reachability |
| `remotedev-verify` | read-mostly | Standalone `rsync` push → `ssh` exec → pull round-trip vs configured host |

Default `HOST` is `devbox`. `init` accepts `--force` to overwrite an
existing `.remotedev`. All verbs are idempotent.

## Repo Layout

```
remotedev-ops/
├── SKILL.md
├── bin/
│   ├── _common.sh          # repo-root resolve, .remotedev parse, ssh probe,
│   │                       # logging, git-hide helpers, rc-block edit, shim
│   │                       # presence/PATH detection
│   ├── remotedev-install
│   ├── remotedev-uninstall
│   ├── remotedev-init
│   ├── remotedev-disable
│   ├── remotedev-status
│   └── remotedev-verify
├── runtime/                # embedded interception source (materialized by install)
│   ├── rd-exec             # hardened core: nearest .remotedev → reachable?
│   │                       #   rsync push / ssh exec / artifact pull, else local
│   │                       #   fallback; slash-path direct exec; tty-aware -t;
│   │                       #   skip pull on failure; per-repo flock
│   ├── rd-shim             # argv[0] multiplexer → rd-exec <name> …
│   ├── rd                  # build|test|run|<cmd> verb front-end
│   ├── gradlew.wrapper     # repo-local launcher wrapper (→ rd-exec ./gradlew.real)
│   └── mvnw.wrapper        # repo-local launcher wrapper (→ rd-exec ./mvnw.real)
└── tests/
    ├── lib.sh              # zero-dep assertions + fake ssh/rsync + fake rc/HOME
    ├── test_install_idempotent.sh
    ├── test_install_path_wiring.sh
    ├── test_uninstall.sh
    ├── test_init_cargo.sh
    ├── test_init_idempotent.sh
    ├── test_init_gradle_swap.sh
    ├── test_init_offline.sh
    ├── test_init_no_buildsystem.sh
    ├── test_init_contract.sh
    ├── test_runtime_passthrough.sh   # ported remotedev offline/slash/shim cases
    ├── test_runtime_remote_fakes.sh  # ported -t/skip-pull/flock cases
    ├── test_status.sh
    └── test_disable.sh
```

Installed like the siblings:
`ln -s ~/claude-skills/remotedev-ops ~/.claude/skills/remotedev-ops`.

## Components & Behavior

### `_common.sh`

Sourced by every verb script:

- `repo_root` — `git rev-parse --show-toplevel`, else `$PWD` (warn:
  git-hide steps skipped).
- `host_up HOST` — `ssh -o BatchMode=yes -o ConnectTimeout=4 HOST true`.
- `read_cfg` — source `.remotedev` into known vars.
- `git_hide PATH` / `git_unhide PATH` — `git update-index --skip-worktree`
  for tracked files; `.git/info/exclude` entry for untracked; idempotent,
  individually reversible.
- `rc_file` — pick the shell rc from `$SHELL` (zsh→`~/.zshrc`,
  bash→`~/.bashrc`); overridable via `REMOTEDEV_RC` (used by tests).
- `rc_block_write` / `rc_block_remove` — insert/remove a single delimited
  marker block (`# >>> remotedev >>>` … `# <<< remotedev <<<`) idempotently.
- `shim_dir` — `${REMOTEDEV_SHIM_DIR:-$HOME/.local/share/remotedev/shims}`.
- `shim_installed` / `shim_on_path` — presence + `PATH`-precedence checks.
- `log` / `warn` / `die` — stderr, `[remotedev] ` prefix.

### `remotedev-install` (per machine, idempotent)

1. `SHIM=$(shim_dir)`; `mkdir -p "$SHIM"`.
2. For each intercepted entrypoint
   (`cargo uv make cmake go npm pnpm yarn bun ninja meson dotnet`):
   `ln -sf <runtime>/rd-shim "$SHIM/<name>"`. Also link `rd-exec`, `rd`.
   `<runtime>` is this skill's `runtime/` dir (resolved from the script's
   own path). Compilers (`gcc`/`clang`) are intentionally not intercepted —
   driven by make/cmake.
3. `rc_block_write` into `rc_file`: `export REMOTEDEV_SHIM_DIR=…` and
   `export PATH="$REMOTEDEV_SHIM_DIR:$PATH"`. Single marker block; re-runs
   replace it in place (idempotent, no duplicate lines).
4. Verify: print whether `$SHIM` resolves first for `cargo` in a fresh
   `PATH` (best-effort), and remind the user to start a new shell / re-source
   rc for the current one.

### `remotedev-uninstall` (per machine, idempotent)

Remove the shim symlinks and `$SHIM` (only if it contains nothing but our
links), and `rc_block_remove` from `rc_file`. Does **not** touch any repo's
`.remotedev` or swapped launchers (that is `disable`'s job). No-op + exit 0
if nothing installed.

### `remotedev-init [HOST] [--force]` (per repo)

Data flow: `cwd → repo_root → detect markers → render .remotedev → ssh
probe → (Gradle/Maven) swap + git-hide → summary + next steps`.

1. Resolve root. `.remotedev` exists and no `--force` → hint + exit 2.
2. If `! shim_installed` → warn that builds won't be intercepted until
   `remotedev-install` is run; continue (config is still valid; offline
   fallback in `rd-exec` keeps commands working).
3. Detect build system by marker and fill verbs/artifacts:

   | Marker | BUILD / TEST / RUN | Artifact |
   |---|---|---|
   | `Cargo.toml` | `cargo build --release` / `cargo test` / `cargo run --release` | `target/release/<name>` (name from `Cargo.toml`; comment if unparseable) |
   | `pom.xml` | `./mvnw -q package` / `./mvnw test` / — | `target/*.jar` (commented — glob) |
   | `build.gradle[.kts]` | `./gradlew build` / `./gradlew test` / — | `build/libs/*.jar` (commented) |
   | `go.mod` | `go build ./...` / `go test ./...` / `go run .` | — |
   | `package.json` | `<pm> run build` / `<pm> test` / — (`pm` from lockfile: pnpm/yarn/bun/npm) | — |
   | `pyproject.toml`/`uv.lock` | — / `uv run pytest` / — | — |
   | none | all three commented placeholders | — |

   Certain values uncommented; genuinely ambiguous ones (jar globs, binary
   name) as comments. Deterministic, non-interactive.
4. Write `.remotedev` from the internal heredoc template (the Config
   Contract), `REMOTEDEV_HOST="$HOST"`.
5. `host_up`. Down → keep config (offline-first), warn + suggest
   `remotedev-verify` once online, exit 0.
6. If `gradlew`/`mvnw` present: per launcher — `mv gradlew gradlew.real`,
   write the wrapper from `runtime/gradlew.wrapper`, `chmod +x`, then
   `git_hide gradlew.real`, `git_hide gradlew`, `git_hide .remotedev`.
   `gradlew.real` already present → already-swapped, skip (idempotent).
   `gradlew` gone but `gradlew.real` present → restore wrapper only.
7. Print summary (host, detected system, verbs, artifacts, swap state,
   shim-installed?) + next steps.

### `remotedev-disable [--purge]` (per repo, idempotent)

Per launcher: if `*.real` exists → `mv *.real <launcher>`, `git_unhide`
both. `git_unhide .remotedev`. `--purge` also `rm .remotedev`. Nothing set
up → no-op, exit 0.

### `remotedev-status` (read-only)

Prints, without mutation:
- Machine: shim dir present? on `PATH`? rc block present?
- Repo: `.remotedev` parsed (host/remote-dir/verbs/artifacts); launcher
  swap state; `host_up` result.
Absence is stated, not an error. Exit 0.

### `remotedev-verify` (standalone)

End-to-end check against the configured host without invoking `rd-exec`:
unique remote dir `remotedev/rd-verify-$$`, `rsync` push a marker, `ssh`
exec writes a result, pull it, assert it came from the remote host; `trap`
removes the remote dir on exit. Non-zero exit + diagnostics on failure.
Requires `.remotedev` (else die, exit 2).

## Config Contract

The `.remotedev` format is owned entirely by this skill (no cross-repo
dependency). v1 variables:

- `REMOTEDEV_HOST` (required)
- `REMOTEDEV_REMOTE_DIR` (optional)
- `REMOTEDEV_EXCLUDES` (optional array; default
  `.git target node_modules .venv build dist .gradle`)
- `REMOTEDEV_ARTIFACTS` (optional array)
- `BUILD_CMD` / `TEST_CMD` / `RUN_CMD` (optional)

`remotedev-init` MUST emit only these and `runtime/rd-exec` MUST consume
only these; `test_init_contract.sh` asserts every assignment in a generated
`.remotedev` is in this set, catching drift between the writer and the
embedded runtime.

## Error Handling

| Case | Behavior |
|---|---|
| `.remotedev` exists, no `--force` | exit 2, hint `status`/`--force` |
| Not a git repo (`init`) | root=cwd, skip git-hide, warn, continue |
| Host unreachable at `init` | write config anyway, warn, exit 0 |
| Shim not installed at `init` | warn, continue (config valid; offline fallback works) |
| `gradlew.real` already present | skip swap (idempotent) |
| `gradlew` gone, `gradlew.real` present | restore wrapper only |
| Launcher not git-tracked | `.git/info/exclude` only (no skip-worktree) |
| No build system detected | generic commented `.remotedev`, exit 0 + note |
| `install` re-run | rc marker block replaced in place, links refreshed (no dupes) |
| `uninstall`/`disable` with nothing set up | no-op, exit 0 |
| `uninstall` with non-ours files in shim dir | remove only our links, keep dir, warn |
| `verify` failure | trap-cleanup remote dir, non-zero exit + diagnostics |

## Testing

Zero-dependency bash, mirroring `gitea-ops/tests/` and the prior remotedev
harness: fake `ssh`/`rsync` on `PATH`; fake `HOME`/rc + temp `SHIM_DIR`
(via `REMOTEDEV_RC` / `REMOTEDEV_SHIM_DIR`) so install/uninstall are tested
without touching the real environment; temp git repos for swap/contract.
No server needed; `verify` is server-gated (`REMOTEDEV_TEST_HOST`).

- `test_install_idempotent` — double `install`: one rc marker block, links
  present, no duplicate exports.
- `test_install_path_wiring` — rc block exports `REMOTEDEV_SHIM_DIR` +
  `PATH`; sourcing a fake rc puts shim dir first.
- `test_uninstall` — removes links + rc block; idempotent; leaves a
  configured repo's `.remotedev` intact.
- `test_init_cargo` / `_idempotent` / `_gradle_swap` / `_offline` /
  `_no_buildsystem` / `_contract` — as in Components/Contract above.
- `test_runtime_passthrough` / `test_runtime_remote_fakes` — ported
  remotedev cases (slash-path local fallback, pure passthrough, shim
  self-skip, offline fallback, tty-aware `-t` absent, skip-pull-on-failure,
  per-repo flock serialization) run against `runtime/`.
- `test_status` — reflects machine + repo state accurately.
- `test_disable` — restores launcher, clears skip-worktree/exclude,
  idempotent; `--purge` removes `.remotedev`.

## Dependencies

`ssh`, `rsync`, `git`, coreutils, `flock` (best-effort: absent → no
concurrency lock, per the embedded runtime's design). No dependency on any
external project. The previously standalone `~/projects/remotedev` is
superseded; its hardened code is the source of `runtime/`. Whether to
formally archive that repo is out of scope for this skill.
