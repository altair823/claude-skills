---
name: remotedev-ops
description: Use when the user wants a local repo to build on the dev server (devbox) instead of the laptop — set up / tear down transparent remote builds, or reclaim devbox disk space. `remotedev-install` wires a PATH-first shim once per machine; `remotedev-init` configures a repo (detect build system, write .remotedev, swap Gradle/Maven launchers, hide from git); `remotedev-status` / `remotedev-verify` inspect; `remotedev-gc` deletes remote artifacts already pulled back; `remotedev-disable` / `remotedev-uninstall` fully reverse. Offline-safe: no host → local build. Auto-detects repo root and build system.
---

# remotedev-ops

Transparent remote builds. After setup, an ordinary `cargo build` / `make` /
`./gradlew build` — run by anyone, including offline — builds on `devbox`
and pulls artifacts back; unreachable host falls back to a local build. The
interception runtime is embedded under `runtime/`; this skill installs,
configures, inspects, and reverses it. Deps: `ssh`, `rsync`, `git`,
coreutils, `flock` (best-effort).

## Commands

Run scripts by path from this skill's `bin/`.

| When the user wants to… | Run |
|---|---|
| Enable remote builds on this machine (once) | `bin/remotedev-install` |
| Set this repo up for remote builds | `bin/remotedev-init [HOST] [--force]` (HOST default `devbox`) |
| See what's configured | `bin/remotedev-status` |
| Confirm the server pipeline works | `bin/remotedev-verify` |
| Reclaim devbox disk space | `bin/remotedev-gc [--dry-run]` |
| Turn this repo back to local | `bin/remotedev-disable [--purge]` |
| Remove the machine-wide layer | `bin/remotedev-uninstall` |

## Workflow

1. First time on a machine: `remotedev-install`, then start a new shell (or
   `source` the rc file it reports) so the shim dir is on `PATH`.
2. In a repo: `remotedev-init`. It detects the build system and writes
   `.remotedev` (edit it to fix any commented-out artifact globs / verbs),
   swaps `./gradlew`/`./mvnw` if present, and hides those changes from git.
3. `remotedev-status` to confirm; `remotedev-verify` once online.
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
- Tests: `tests/run.sh` (zero-dep, server-free). The `verify` / `gc`
  roundtrips are gated behind `REMOTEDEV_TEST_HOST`.
