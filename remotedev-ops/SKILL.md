---
name: remotedev-ops
description: Use when the user wants a local repo to build on the dev server (devbox) instead of this machine, wants to turn remote builds on or off for a repo or machine, asks why a remote build failed or fell back to local, or wants to free devbox disk space.
---

# remotedev-ops

Transparent remote builds. After setup, an ordinary `cargo build` / `make` /
`./gradlew build` — run by anyone, including offline — builds on `devbox`
and pulls artifacts back; unreachable host falls back to a local build. The
interception runtime is embedded under `runtime/`; this skill installs,
configures, inspects, and reverses it. Deps: `ssh`, `rsync`, `git`,
coreutils, `flock` (best-effort).

## Commands

Scripts are not on PATH. Call them by the full path shown below.

| When the user wants to… | Run |
|---|---|
| Enable remote builds on this machine (once) | `${CLAUDE_SKILL_DIR}/bin/remotedev-install` |
| Set this repo up for remote builds | `${CLAUDE_SKILL_DIR}/bin/remotedev-init [HOST] [--force]` (HOST default `devbox`) |
| See what's configured | `${CLAUDE_SKILL_DIR}/bin/remotedev-status` |
| Confirm the server pipeline works | `${CLAUDE_SKILL_DIR}/bin/remotedev-verify` |
| Check the build artifact will run locally | `${CLAUDE_SKILL_DIR}/bin/remotedev-doctor [--brief]` |
| Reclaim devbox disk space | `${CLAUDE_SKILL_DIR}/bin/remotedev-gc [--dry-run]` |
| Turn this repo back to local | `${CLAUDE_SKILL_DIR}/bin/remotedev-disable [--purge]` |
| Remove the machine-wide layer | `${CLAUDE_SKILL_DIR}/bin/remotedev-uninstall` |

## Workflow

1. First time on a machine: `remotedev-install`, then start a new shell (or
   `source` the rc file it reports) so the shim dir is on `PATH`.
2. In a repo: `remotedev-init`. It detects the build system and writes
   `.remotedev` (edit it to fix any commented-out artifact globs / verbs),
   swaps `./gradlew`/`./mvnw` if present, and hides those changes from git.
3. `remotedev-status` to confirm; `remotedev-verify` once online.
   `remotedev-doctor` flags arch/glibc skew that could make a devbox-built
   native artifact unrunnable locally (init runs it once automatically).
4. Builds now run on the host transparently. Offline → local fallback.
5. Periodically run `remotedev-gc` (e.g. via the user's scheduler) to free
   devbox space — it deletes only artifacts already pulled back; preview
   with `--dry-run`.
6. Reverse per repo with `remotedev-disable` (`--purge` also deletes
   `.remotedev`); remove machine-wide with `remotedev-uninstall`.

## Notes

- `init` is non-interactive: certain verbs filled, ambiguous ones (jar
  globs, binary name) written as comments to edit.
- Re-running any verb is safe (idempotent). `init` refuses to overwrite an
  existing `.remotedev` without `--force`.
- Tests: `${CLAUDE_SKILL_DIR}/tests/run.sh` (zero-dep, server-free). The `verify` / `gc`
  roundtrips are gated behind `REMOTEDEV_TEST_HOST`.
