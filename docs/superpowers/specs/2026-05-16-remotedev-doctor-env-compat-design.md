# remotedev-doctor — env-compatibility check — Design Spec

Date: 2026-05-16
Status: Approved (pending implementation plan)

## Purpose

devbox builds the artifact; the laptop runs it. If the two environments
diverge — different CPU architecture, or devbox's glibc newer than the
laptop's — a natively-compiled artifact built on devbox can be
**unrunnable locally** (`exec format error`, or `version 'GLIBC_2.x' not
found`). Add a pre-build compatibility check so this is surfaced *before*
relying on remote builds, not discovered at run time.

Delivered as a new verb `remotedev-doctor` (reusable, scriptable via exit
code) plus a one-time advisory call from `remotedev-init` at the end of
setup. The embedded interception runtime (`rd-exec`/`rd-shim`/`rd`) is
**not** modified — keeping the hardened ported runtime stable and the
check on the skill-verb layer, consistent with the sibling pattern.

Out of scope:

- Per-build enforcement in `rd-exec` (would mean an ssh round-trip on every
  build and editing the hardened runtime). The check is advisory, run at
  init and on demand.
- Deep shared-library/symbol analysis of the produced binary (that is
  post-build and artifact-specific). v1 compares only CPU arch + glibc.
- Detecting whether the project actually produces a native artifact.
  Native-ness detection is unreliable (a Python/Node project may have
  native deps; a Go build may be static). `doctor` always reports the
  facts and notes that they matter for natively-compiled artifacts and are
  usually moot for JVM/pure-Python.
- Auto-remediation (switching to musl/static targets, forcing local
  builds). `doctor` advises; the user acts.

## Scope of v1

| Verb | Purpose |
|---|---|
| `remotedev-doctor [--brief]` | Compare local vs devbox CPU arch + glibc, report compatibility, signal via exit code |

`remotedev-init` calls `remotedev-doctor --brief` once at the end of setup
(advisory; never changes init's own exit status).

## Components & Behavior

### `remotedev-doctor [--brief]`

Sources `_common.sh`. Steps:

1. `ROOT=$(repo_root)`; require `$ROOT/.remotedev` else `warn "no
   .remotedev here"`, exit 2 (same convention as `verify`/`gc`).
2. `read_cfg`; `REMOTEDEV_HOST` required else `die` (exit 1).
3. `host_up "$HOST"` false → print "offline — compatibility not checked;
   re-run `remotedev-doctor` when online", **exit 0** (offline-first:
   "couldn't check" ≠ "incompatible").
4. **Local probe:** `arch_local=$(uname -m)`;
   `glibc_local` from `getconf GNU_LIBC_VERSION` (e.g. `glibc 2.39`),
   falling back to parsing `ldd --version | head -1`; if both fail →
   `glibc_local=unknown`.
5. **Remote probe:** a single ssh call collecting the same two values:
   `ssh "$HOST" 'uname -m; getconf GNU_LIBC_VERSION 2>/dev/null || ldd
   --version 2>/dev/null | head -1'`. One round-trip, independent of
   `rd-exec`'s `host_up`.
6. **Verdict:**
   - `arch_local != arch_remote` → **CRITICAL**: a native artifact built
     on devbox cannot exec locally. Advise: build this repo locally, or
     target the local arch / a portable runtime.
   - arch equal, both glibc known, `glibc_remote > glibc_local` →
     **WARNING**: a dynamically-linked native binary may fail locally with
     `GLIBC_x.y not found`. Advise: static/musl target, or local build.
     Note: irrelevant for static binaries (Go w/o cgo, Rust musl).
   - arch equal, `glibc_remote <= glibc_local` (or glibc unknown on a
     side) → **COMPATIBLE** (glibc `unknown` is reported as a soft note,
     not a failure).
7. **Output:** a small table of local vs remote (arch, glibc), the verdict
   line, and remediation when not compatible. Always include a one-line
   note: this matters for natively-compiled artifacts (Rust/C/C++/cgo) and
   is usually moot for JVM / pure-Python. `--brief` prints only a 1–2 line
   summary (verdict + the divergent value); same verdict/exit code as full
   mode.
8. **Exit codes:** `0` compatible OR offline-skip; `1` warning (glibc
   devbox-newer, or incomplete probe); `2` critical (arch mismatch) — also
   `2` for the no-`.remotedev` precondition (consistent with verify/gc).

glibc version comparison: extract the `MAJOR.MINOR` numeric (from `glibc
X.Y` or the `ldd (… ) X.Y` line) and compare numerically (major, then
minor). Any side `unknown` ⇒ skip the glibc comparison (soft note), do not
emit a warning solely for unknown.

### `remotedev-init` integration

After the launcher swap + git-hide and the existing `host_up` reachability
message, call `remotedev-doctor --brief` defensively
(`remotedev-doctor --brief || true` — never let it change init's outcome).
`remotedev-init` still **always exits 0** on the setup path; the doctor
output is advisory. If the host is unreachable or `.remotedev` was just
written but the host is down, `doctor` self-skips (exit 0, offline note).

## Error Handling

| Case | Behavior |
|---|---|
| no `.remotedev` | `warn` + exit 2 |
| `.remotedev` has no `REMOTEDEV_HOST` | `die` (exit 1) |
| host unreachable | offline note, exit 0 (not a failure) |
| local glibc undetectable | `glibc_local=unknown`, skip glibc compare, arch still judged, no glibc warning from "unknown" alone |
| remote probe ssh fails mid-call | `warn`, exit 1 (incomplete), print partial facts |
| arch mismatch | CRITICAL message + remediation, exit 2 |
| glibc devbox > local (arch equal) | WARNING + static/musl note, exit 1 |
| arch equal, glibc devbox ≤ local | COMPATIBLE, exit 0 |
| called from init, any verdict | init prints doctor output, init exit stays 0 |
| `remotedev-doctor` missing/unrunnable when init calls it | init unaffected (`|| true`), exit 0 |

## Testing

`tests/test_doctor.sh`, zero-dep, fake `ssh` on PATH. Extend the fake `ssh`
fixture with env knobs `RD_FAKE_UNAME` / `RD_FAKE_GLIBC` so the remote
probe is simulated (the probe command is the `uname -m; getconf …` string;
the fixture returns the configured values for it, keeps existing
host_up/build behavior otherwise). Cases:

- no `.remotedev` → exit 2.
- host down (`RD_FAKE_HOST_UP=1`) → offline note, exit 0.
- arch equal + remote glibc ≤ local → COMPATIBLE, exit 0.
- arch mismatch (local `uname -m` vs `RD_FAKE_UNAME=aarch64`) → CRITICAL,
  exit 2.
- remote glibc > local (arch equal) → WARNING + static/musl note, exit 1.
- local glibc undetectable (simulate by forcing the local probe path to
  yield unknown, e.g. `REMOTEDEV_FAKE_LOCAL_GLIBC=unknown` test hook) →
  glibc compare skipped, arch judged, no crash, exit 0 when arch equal.
- `--brief` → 1–2 line summary, exit code identical to full mode for the
  same inputs.
- init regression: `remotedev-init` invokes doctor and still exits 0;
  existing `test_init_detect/probe/swap` stay green.
- server-gated: `REMOTEDEV_TEST_HOST=devbox remotedev-doctor` against the
  real devbox (x86_64, glibc) → COMPATIBLE, exit 0; remote clean (no
  artifacts created — doctor only reads).

To keep the local probe testable without faking the whole host, the local
glibc/arch lookup reads optional override env vars
(`REMOTEDEV_FAKE_LOCAL_ARCH`, `REMOTEDEV_FAKE_LOCAL_GLIBC`) used **only by
tests**; unset in normal use → real `uname`/`getconf`.

## Dependencies

`ssh`, `uname`, `getconf`/`ldd` (coreutils/libc — present on any glibc
Linux). No new external dependency; no change to the embedded runtime or
any other verb except the one-line advisory call added to
`remotedev-init`.
