# remotedev-ops Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained `remotedev-ops` skill that installs a transparent build-tool interception layer once per machine and configures/reverses it per repo, so ordinary build commands run on `devbox` with offline fallback.

**Architecture:** Sibling-skill shape (`SKILL.md` + `bin/` verb scripts over `ssh`/`rsync`/`git` + zero-dep `tests/`). The hardened interception runtime (`rd-exec`/`rd-shim`/`rd` + launcher wrappers) is embedded under `runtime/`; `remotedev-install` materializes it into a `PATH`-first shim dir and wires the shell rc; `remotedev-uninstall` reverses it. Per-repo verbs (`init`/`disable`/`status`/`verify`) write/parse/reverse the `.remotedev` contract the runtime consumes.

**Tech Stack:** bash, `ssh`, `rsync`, `git`, coreutils, `flock` (best-effort). No external project dependency.

---

## File Structure

```
remotedev-ops/
├── SKILL.md                         # Task 12
├── bin/
│   ├── _common.sh                   # Task 3  — shared helpers
│   ├── remotedev-install            # Task 4  — per-machine wiring
│   ├── remotedev-uninstall          # Task 5  — per-machine revert
│   ├── remotedev-init               # Tasks 6,7,8 — per-repo setup
│   ├── remotedev-disable            # Task 9  — per-repo revert
│   ├── remotedev-status             # Task 10 — read-only report
│   └── remotedev-verify             # Task 11 — standalone roundtrip
├── runtime/                         # Task 1  — embedded interception source
│   ├── rd-exec  ├─ rd-shim  ├─ rd
│   ├── gradlew.wrapper
│   └── mvnw.wrapper
└── tests/                           # Task 2 + per-verb tasks
    ├── lib.sh
    ├── fixtures/{ssh,rsync}
    └── test_*.sh
```

Source of `runtime/*` is the hardened, already-tested code at
`~/projects/remotedev` (`bin/rd-exec`, `bin/rd-shim`, `bin/rd`,
`templates/gradlew`, `templates/mvnw`). Tasks 1–2 copy it verbatim and
prove it still passes here; Tasks 3+ build the new skill scripts via TDD.

**`_common.sh` API (locked here; all later tasks use exactly these names):**

- `log MSG` / `warn MSG` / `die MSG` — stderr, `[remotedev] ` prefix; `die` exits 1.
- `rdo_home` — prints the skill root (dir containing `bin/`, `runtime/`).
- `repo_root` — prints `git rev-parse --show-toplevel` or `$PWD`.
- `is_git_repo` — return 0/1.
- `host_up HOST` — `ssh -o BatchMode=yes -o ConnectTimeout=4 HOST true`.
- `shim_dir` — prints `${REMOTEDEV_SHIM_DIR:-$HOME/.local/share/remotedev/shims}`.
- `rc_file` — prints `${REMOTEDEV_RC:-<rc from $SHELL>}` (zsh→`~/.zshrc`, else `~/.bashrc`).
- `rc_block_write FILE` — idempotently (re)write the delimited marker block.
- `rc_block_remove FILE` — remove the marker block if present.
- `git_hide REL` / `git_unhide REL` — skip-worktree if tracked, else `.git/info/exclude`.
- `shim_installed` — return 0 if `$(shim_dir)/cargo` exists.
- `read_cfg FILE` — reset defaults then `source FILE`; populates `REMOTEDEV_*`,`BUILD_CMD`,`TEST_CMD`,`RUN_CMD`.
- `INTERCEPT` — array constant: `cargo uv make cmake go npm pnpm yarn bun ninja meson dotnet`.

**rc marker block (exact):**

```
# >>> remotedev >>>
export REMOTEDEV_SHIM_DIR="<shim_dir>"
export PATH="$REMOTEDEV_SHIM_DIR:$PATH"
# <<< remotedev <<<
```

---

## Task 1: Scaffold + port the runtime

**Files:**
- Create: `remotedev-ops/runtime/rd-exec`, `runtime/rd-shim`, `runtime/rd`, `runtime/gradlew.wrapper`, `runtime/mvnw.wrapper`

- [ ] **Step 1: Create dirs and copy the hardened runtime verbatim**

```bash
cd ~/claude-skills    # work happens in the worktree checkout of this repo
mkdir -p remotedev-ops/runtime remotedev-ops/bin remotedev-ops/tests/fixtures
SRC=~/projects/remotedev
cp "$SRC/bin/rd-exec"        remotedev-ops/runtime/rd-exec
cp "$SRC/bin/rd-shim"        remotedev-ops/runtime/rd-shim
cp "$SRC/bin/rd"             remotedev-ops/runtime/rd
cp "$SRC/templates/gradlew"  remotedev-ops/runtime/gradlew.wrapper
cp "$SRC/templates/mvnw"     remotedev-ops/runtime/mvnw.wrapper
chmod +x remotedev-ops/runtime/rd-exec remotedev-ops/runtime/rd-shim remotedev-ops/runtime/rd
```

- [ ] **Step 2: Verify syntax of every copied script**

Run:
```bash
for f in remotedev-ops/runtime/rd-exec remotedev-ops/runtime/rd-shim remotedev-ops/runtime/rd remotedev-ops/runtime/gradlew.wrapper remotedev-ops/runtime/mvnw.wrapper; do bash -n "$f" && echo "ok $f"; done
```
Expected: five `ok ...` lines, no syntax errors.

- [ ] **Step 3: Sanity-check the slash-path fix is present in the copy**

Run:
```bash
grep -n 'A name with a slash is an explicit path' remotedev-ops/runtime/rd-exec
grep -n 'tflag=()' remotedev-ops/runtime/rd-exec
grep -n 'skipping artifact fetch' remotedev-ops/runtime/rd-exec
grep -n 'no concurrency lock' remotedev-ops/runtime/rd-exec
```
Expected: each grep prints a matching line (confirms the four hardening fixes are in the embedded copy).

- [ ] **Step 4: Commit**

```bash
git add remotedev-ops/runtime
git commit -m "feat(remotedev-ops): embed hardened interception runtime"
```

---

## Task 2: Port the test harness + runtime regression tests

**Files:**
- Create: `remotedev-ops/tests/lib.sh`, `tests/fixtures/ssh`, `tests/fixtures/rsync`, `tests/run.sh`, `tests/test_runtime_passthrough.sh`, `tests/test_runtime_remote_fakes.sh`

- [ ] **Step 1: Create `tests/lib.sh`** (adapted: `REPO` → skill root, fixtures under `tests/`)

```bash
cat > remotedev-ops/tests/lib.sh <<'EOF'
# tests/lib.sh — zero-dependency assertions for remotedev-ops.
# Each test runs in its own subshell via `run_test "name" body-fn`.

RDO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # skill root

_T_PASS=0
_T_FAIL=0

new_workspace() { mktemp -d "${TMPDIR:-/tmp}/rdo-test.XXXXXX"; }

_fail() { printf '       %s\n' "$1" >&2; exit 1; }

assert_eq()          { [ "$1" = "$2" ] || _fail "expected [$1], got [$2]"; }
assert_contains()    { case "$1" in *"$2"*) : ;; *) _fail "expected to contain [$2], got [$1]" ;; esac; }
assert_not_contains(){ case "$1" in *"$2"*) _fail "expected NOT to contain [$2], got [$1]" ;; esac; }
assert_file_has()    { grep -qF -- "$2" "$1" || _fail "[$1] missing [$2]"; }
assert_file_absent() { [ ! -e "$1" ] || _fail "[$1] should not exist"; }

# fixtures dir holding fake ssh/rsync; prepend to PATH for server-free tests.
fixtures_path() {
  chmod +x "$RDO/tests/fixtures/ssh" "$RDO/tests/fixtures/rsync"
  printf '%s' "$RDO/tests/fixtures"
}

run_test() {
  local name="$1"; shift
  if ( set -uo pipefail; "$@" ) 2> >(sed 's/^/  /' >&2); then
    _T_PASS=$((_T_PASS+1)); printf '  ok   %s\n' "$name"
  else
    _T_FAIL=$((_T_FAIL+1)); printf '  FAIL %s\n' "$name"
  fi
}

summary() { printf '\n%d passed, %d failed\n' "$_T_PASS" "$_T_FAIL"; [ "$_T_FAIL" -eq 0 ]; }
EOF
```

- [ ] **Step 2: Create the fake `ssh`/`rsync` fixtures verbatim**

```bash
cat > remotedev-ops/tests/fixtures/ssh <<'EOF'
#!/usr/bin/env bash
# Fake ssh: logs argv; behaves on the remote command (last arg) + env knobs:
#   RD_FAKE_LOG RD_FAKE_HOST_UP RD_FAKE_BUILD_RC RD_FAKE_SLEEP RD_FAKE_CRIT
set -u
[ -n "${RD_FAKE_LOG:-}" ] && printf 'ssh %s\n' "$*" >> "$RD_FAKE_LOG"
cmd="${!#}"
case "$cmd" in
  true)        exit "${RD_FAKE_HOST_UP:-0}" ;;
  "mkdir -p"*) exit 0 ;;
  *)
    if [ -n "${RD_FAKE_CRIT:-}" ]; then echo "ENTER $$" >> "$RD_FAKE_CRIT"; fi
    sleep "${RD_FAKE_SLEEP:-0}"
    if [ -n "${RD_FAKE_CRIT:-}" ]; then echo "EXIT $$" >> "$RD_FAKE_CRIT"; fi
    exit "${RD_FAKE_BUILD_RC:-0}" ;;
esac
EOF
cat > remotedev-ops/tests/fixtures/rsync <<'EOF'
#!/usr/bin/env bash
# Fake rsync: push (has --delete) succeeds; pull creates the dest file.
set -u
[ -n "${RD_FAKE_LOG:-}" ] && printf 'rsync %s\n' "$*" >> "$RD_FAKE_LOG"
is_push=0; for a in "$@"; do [ "$a" = "--delete" ] && is_push=1; done
[ "$is_push" -eq 1 ] && exit 0
dest="${!#}"; mkdir -p "$(dirname "$dest")"; echo "PULLED" > "$dest"; exit 0
EOF
chmod +x remotedev-ops/tests/fixtures/ssh remotedev-ops/tests/fixtures/rsync
```

- [ ] **Step 3: Create `tests/run.sh`** (discovers and runs every `tests/test_*.sh`)

```bash
cat > remotedev-ops/tests/run.sh <<'EOF'
#!/usr/bin/env bash
# tests/run.sh — run every tests/test_*.sh. Each prints its own tally;
# this aggregates exit codes.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0
for t in "$DIR"/test_*.sh; do
  echo "== ${t##*/} =="
  bash "$t" || rc=1
done
exit $rc
EOF
chmod +x remotedev-ops/tests/run.sh
```

- [ ] **Step 4: Write `tests/test_runtime_passthrough.sh`** (ported server-free runtime cases)

```bash
cat > remotedev-ops/tests/test_runtime_passthrough.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
RT="$RDO/runtime"

t_slash() {
  local ws; ws="$(new_workspace)"; cd "$ws"
  printf '#!/usr/bin/env bash\necho GR args=$*\n' > g.real; chmod +x g.real
  local out rc; out="$("$RT/rd-exec" ./g.real build 2>&1)"; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"; assert_contains "$out" "GR args=build"
}
run_test "runtime: passthrough runs a slash-path command" t_slash

t_pathcmd() {
  local ws; ws="$(new_workspace)"; cd "$ws"; mkdir rb
  printf '#!/usr/bin/env bash\necho MT args=$*\n' > rb/mytool; chmod +x rb/mytool
  local out rc; out="$(PATH="$ws/rb:$PATH" "$RT/rd-exec" mytool x 2>&1)"; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"; assert_contains "$out" "MT args=x"
}
run_test "runtime: passthrough runs a PATH command" t_pathcmd

t_offline() {
  local ws; ws="$(new_workspace)"; cd "$ws"
  echo 'REMOTEDEV_HOST="192.0.2.1"' > .remotedev
  printf '#!/usr/bin/env bash\necho LOCAL_BUILD\n' > b.sh; chmod +x b.sh
  local out rc; out="$("$RT/rd-exec" ./b.sh 2>&1)"; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"
  assert_contains "$out" "offline fallback"; assert_contains "$out" "LOCAL_BUILD"
}
run_test "runtime: offline fallback builds locally" t_offline

t_shimskip() {
  local ws; ws="$(new_workspace)"; cd "$ws"; mkdir shims rb
  ln -s "$RT/rd-shim" shims/mytool
  printf '#!/usr/bin/env bash\necho REAL args=$*\n' > rb/mytool; chmod +x rb/mytool
  local out rc
  out="$(REMOTEDEV_SHIM_DIR="$ws/shims" PATH="$ws/shims:$ws/rb:$PATH" "$ws/shims/mytool" b 2>&1)"; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"; assert_contains "$out" "REAL args=b"
}
run_test "runtime: shim skips itself, finds real binary" t_shimskip

summary
EOF
chmod +x remotedev-ops/tests/test_runtime_passthrough.sh
```

- [ ] **Step 5: Write `tests/test_runtime_remote_fakes.sh`** (ported `-t`/skip-pull/flock cases)

```bash
cat > remotedev-ops/tests/test_runtime_remote_fakes.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
RT="$RDO/runtime"

t_no_pty() {
  local ws fb; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  echo 'REMOTEDEV_HOST="fakehost"' > .remotedev; : > log
  PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1
  local execline; execline="$(grep ' && ' log | head -1)"
  rm -rf "$ws"
  assert_contains "$execline" "ssh "; assert_not_contains "$execline" " -t "
}
run_test "runtime: no -t when stdin not a tty" t_no_pty

t_no_pull_fail() {
  local ws fb rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  PATH="$fb:$PATH" RD_FAKE_BUILD_RC=7 "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1; rc=$?
  local p="present"; [ -e out/app ] || p="absent"
  rm -rf "$ws"; assert_eq 7 "$rc"; assert_eq "absent" "$p"
}
run_test "runtime: failed build skips pull, propagates rc" t_no_pull_fail

t_pull_ok() {
  local ws fb rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  PATH="$fb:$PATH" "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1; rc=$?
  local got=""; [ -e out/app ] && got="$(cat out/app)"
  rm -rf "$ws"; assert_eq 0 "$rc"; assert_eq "PULLED" "$got"
}
run_test "runtime: successful build pulls artifacts" t_pull_ok

t_lock() {
  local ws fb; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  echo 'REMOTEDEV_HOST="fakehost"' > .remotedev; : > crit
  PATH="$fb:$PATH" RD_FAKE_SLEEP=1 RD_FAKE_CRIT="$ws/crit" "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1 &
  local p1=$!
  PATH="$fb:$PATH" RD_FAKE_SLEEP=1 RD_FAKE_CRIT="$ws/crit" "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1 &
  local p2=$!
  wait "$p1"; wait "$p2"
  local lines; mapfile -t lines < crit; rm -rf "$ws"
  [ "${#lines[@]}" -eq 4 ] || _fail "expected 4 markers, got ${#lines[@]}"
  assert_eq "${lines[0]##* }" "${lines[1]##* }"
  assert_eq "${lines[2]##* }" "${lines[3]##* }"
}
run_test "runtime: concurrent runs serialize (flock)" t_lock

summary
EOF
chmod +x remotedev-ops/tests/test_runtime_remote_fakes.sh
```

- [ ] **Step 6: Run the runtime tests, verify all pass**

Run: `bash remotedev-ops/tests/run.sh`
Expected: both files report `... 0 failed` (4 passed + 4 passed); `run.sh` exit 0.

- [ ] **Step 7: Commit**

```bash
git add remotedev-ops/tests
git commit -m "test(remotedev-ops): port zero-dep harness + runtime regression tests"
```

---

## Task 3: `_common.sh` shared helpers

**Files:**
- Create: `remotedev-ops/bin/_common.sh`
- Test: `remotedev-ops/tests/test_common.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_common.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
C="$RDO/bin/_common.sh"

t_shim_dir_default() {
  local got; got="$(bash -c '. "$0"; shim_dir' "$C")"
  assert_contains "$got" "/.local/share/remotedev/shims"
}
run_test "shim_dir default path" t_shim_dir_default

t_shim_dir_override() {
  local got; got="$(REMOTEDEV_SHIM_DIR=/tmp/x bash -c '. "$0"; shim_dir' "$C")"
  assert_eq "/tmp/x" "$got"
}
run_test "shim_dir honours REMOTEDEV_SHIM_DIR" t_shim_dir_override

t_rc_file_override() {
  local got; got="$(REMOTEDEV_RC=/tmp/rc bash -c '. "$0"; rc_file' "$C")"
  assert_eq "/tmp/rc" "$got"
}
run_test "rc_file honours REMOTEDEV_RC" t_rc_file_override

t_rc_block_roundtrip() {
  local ws; ws="$(new_workspace)"; local rc="$ws/rc"
  echo 'export PATH=/usr/bin' > "$rc"
  REMOTEDEV_SHIM_DIR="$ws/shims" REMOTEDEV_RC="$rc" bash -c '. "$0"; rc_block_write "$(rc_file)"' "$C"
  REMOTEDEV_SHIM_DIR="$ws/shims" REMOTEDEV_RC="$rc" bash -c '. "$0"; rc_block_write "$(rc_file)"' "$C"
  local n; n="$(grep -c '>>> remotedev >>>' "$rc")"
  assert_eq "1" "$n"
  assert_file_has "$rc" "export REMOTEDEV_SHIM_DIR=\"$ws/shims\""
  REMOTEDEV_RC="$rc" bash -c '. "$0"; rc_block_remove "$(rc_file)"' "$C"
  n="$(grep -c '>>> remotedev >>>' "$rc" || true)"
  rm -rf "$ws"; assert_eq "0" "$n"
}
run_test "rc_block_write idempotent + rc_block_remove" t_rc_block_roundtrip

t_git_hide_tracked() {
  local ws; ws="$(new_workspace)"; cd "$ws"; git init -q
  echo hi > f; git add f; git commit -qm init
  bash -c '. "$0"; cd "'"$ws"'"; git_hide f' "$C"
  local flag; flag="$(git ls-files -v f | cut -c1)"
  rm -rf "$ws"; assert_eq "S" "$flag"
}
run_test "git_hide sets skip-worktree on tracked file" t_git_hide_tracked

t_git_unhide_exclude() {
  local ws; ws="$(new_workspace)"; cd "$ws"; git init -q
  echo data > only
  bash -c '. "$0"; cd "'"$ws"'"; git_hide only' "$RDO/bin/_common.sh"
  assert_file_has .git/info/exclude "only"
  bash -c '. "$0"; cd "'"$ws"'"; git_unhide only' "$RDO/bin/_common.sh"
  local n; n="$(grep -c '^only$' .git/info/exclude 2>/dev/null || true)"
  [ -e .git/info/exclude.tmp ] && _fail "exclude.tmp leaked"
  rm -rf "$ws"; assert_eq "0" "$n"
}
run_test "git_unhide removes a sole exclude entry" t_git_unhide_exclude

t_rc_block_no_trailing_newline() {
  local ws; ws="$(new_workspace)"; local rc="$ws/rc"
  printf 'export X=1' > "$rc"   # NO trailing newline
  REMOTEDEV_SHIM_DIR="$ws/s" REMOTEDEV_RC="$rc" bash -c '. "$0"; rc_block_write "$(rc_file)"' "$RDO/bin/_common.sh"
  REMOTEDEV_SHIM_DIR="$ws/s" REMOTEDEV_RC="$rc" bash -c '. "$0"; rc_block_write "$(rc_file)"' "$RDO/bin/_common.sh"
  assert_eq "1" "$(grep -c '>>> remotedev >>>' "$rc")"
  assert_file_has "$rc" "export X=1"
  grep -q '^# >>> remotedev >>>$' "$rc" || _fail "sentinel not on its own line"
  rm -rf "$ws"
}
run_test "rc_block_write tolerates no trailing newline" t_rc_block_no_trailing_newline

summary
EOF
chmod +x remotedev-ops/tests/test_common.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_common.sh`
Expected: FAIL lines (`_common.sh` does not exist → `source` errors → assertions fail).

- [ ] **Step 3: Write `bin/_common.sh`**

```bash
cat > remotedev-ops/bin/_common.sh <<'EOF'
# bin/_common.sh — shared helpers for remotedev-ops verb scripts.
# Sourced, never executed. No `set -e` here (callers own their mode).

log()  { printf '[remotedev] %s\n' "$*" >&2; }
warn() { printf '[remotedev] warning: %s\n' "$*" >&2; }
die()  { printf '[remotedev] error: %s\n' "$*" >&2; exit 1; }

rdo_home() { cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd; }

is_git_repo() { git rev-parse --show-toplevel >/dev/null 2>&1; }
repo_root()   { git rev-parse --show-toplevel 2>/dev/null || pwd; }

host_up() { ssh -o BatchMode=yes -o ConnectTimeout=4 "$1" true 2>/dev/null; }

shim_dir() { printf '%s' "${REMOTEDEV_SHIM_DIR:-$HOME/.local/share/remotedev/shims}"; }

rc_file() {
  if [ -n "${REMOTEDEV_RC:-}" ]; then printf '%s' "$REMOTEDEV_RC"; return; fi
  case "${SHELL:-}" in
    */zsh) printf '%s' "$HOME/.zshrc" ;;
    *)     printf '%s' "$HOME/.bashrc" ;;
  esac
}

RDO_BEG='# >>> remotedev >>>'
RDO_END='# <<< remotedev <<<'

rc_block_remove() {
  local f="$1"; [ -f "$f" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -v b="$RDO_BEG" -v e="$RDO_END" '
    $0==b{skip=1} skip==0{print} $0==e{skip=0}' "$f" > "$tmp"
  mv "$tmp" "$f"
}

rc_block_write() {
  local f="$1"; touch "$f"; rc_block_remove "$f"
  if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then printf '\n' >> "$f"; fi
  { printf '%s\n' "$RDO_BEG"
    printf 'export REMOTEDEV_SHIM_DIR="%s"\n' "$(shim_dir)"
    printf 'export PATH="$REMOTEDEV_SHIM_DIR:$PATH"\n'
    printf '%s\n' "$RDO_END"
  } >> "$f"
}

# git_hide/git_unhide operate on a path relative to the current repo root.
git_hide() {
  local rel="$1"
  if git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    git update-index --skip-worktree -- "$rel"
  else
    local ex; ex="$(git rev-parse --git-dir)/info/exclude"
    grep -qxF -- "$rel" "$ex" 2>/dev/null || printf '%s\n' "$rel" >> "$ex"
  fi
}
git_unhide() {
  local rel="$1"
  if git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    git update-index --no-skip-worktree -- "$rel" 2>/dev/null || true
  fi
  local ex; ex="$(git rev-parse --git-dir 2>/dev/null)/info/exclude"
  if [ -f "$ex" ]; then grep -vxF -- "$rel" "$ex" > "$ex.tmp" 2>/dev/null || true; mv "$ex.tmp" "$ex"; fi
  return 0
}

shim_installed() { [ -e "$(shim_dir)/cargo" ]; }

INTERCEPT=(cargo uv make cmake go npm pnpm yarn bun ninja meson dotnet)

read_cfg() {
  REMOTEDEV_HOST=""; REMOTEDEV_REMOTE_DIR=""
  REMOTEDEV_EXCLUDES=(.git target node_modules .venv build dist .gradle)
  REMOTEDEV_ARTIFACTS=(); BUILD_CMD=""; TEST_CMD=""; RUN_CMD=""
  # shellcheck disable=SC1090
  . "$1"
}
EOF
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_common.sh`
Expected: `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add remotedev-ops/bin/_common.sh remotedev-ops/tests/test_common.sh
git commit -m "feat(remotedev-ops): _common.sh shared helpers"
```

---

## Task 4: `remotedev-install` (per-machine wiring)

**Files:**
- Create: `remotedev-ops/bin/remotedev-install`
- Test: `remotedev-ops/tests/test_install.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_install.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-install"

t_install() {
  local ws; ws="$(new_workspace)"
  local sd="$ws/shims" rc="$ws/rc"
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$BIN" >/dev/null 2>&1
  # intercepted commands symlinked to rd-shim
  [ -L "$sd/cargo" ] || _fail "cargo shim missing"
  assert_eq "$RDO/runtime/rd-shim" "$(readlink "$sd/cargo")"
  [ -L "$sd/rd" ] || _fail "rd link missing"
  [ -L "$sd/rd-exec" ] || _fail "rd-exec link missing"
  # rc wired exactly once
  assert_eq "1" "$(grep -c '>>> remotedev >>>' "$rc")"
  assert_file_has "$rc" "export REMOTEDEV_SHIM_DIR=\"$sd\""
  rm -rf "$ws"
}
run_test "install links shims + wires rc" t_install

t_install_idempotent() {
  local ws; ws="$(new_workspace)"
  local sd="$ws/shims" rc="$ws/rc"
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$BIN" >/dev/null 2>&1
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$BIN" >/dev/null 2>&1
  assert_eq "1" "$(grep -c '>>> remotedev >>>' "$rc")"
  assert_eq "$RDO/runtime/rd-shim" "$(readlink "$sd/make")"
  rm -rf "$ws"
}
run_test "install is idempotent" t_install_idempotent

summary
EOF
chmod +x remotedev-ops/tests/test_install.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_install.sh`
Expected: FAIL (`remotedev-install` does not exist).

- [ ] **Step 3: Write `bin/remotedev-install`**

```bash
cat > remotedev-ops/bin/remotedev-install <<'EOF'
#!/usr/bin/env bash
# remotedev-install — per-machine: create the PATH-first shim dir and wire
# the shell rc. Idempotent. Run once per machine.
set -eo pipefail
. "$(dirname "$(readlink -f "$0")")/_common.sh"

RT="$(rdo_home)/runtime"
SD="$(shim_dir)"
RC="$(rc_file)"

mkdir -p "$SD"
for name in "${INTERCEPT[@]}"; do ln -sf "$RT/rd-shim" "$SD/$name"; done
ln -sf "$RT/rd-exec" "$SD/rd-exec"
ln -sf "$RT/rd"      "$SD/rd"

rc_block_write "$RC"

log "shim dir: $SD"
log "intercepting: ${INTERCEPT[*]}"
log "wired: $RC  (open a new shell or: source $RC)"
EOF
chmod +x remotedev-ops/bin/remotedev-install
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_install.sh`
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add remotedev-ops/bin/remotedev-install remotedev-ops/tests/test_install.sh
git commit -m "feat(remotedev-ops): remotedev-install per-machine wiring"
```

---

## Task 5: `remotedev-uninstall` (per-machine revert)

**Files:**
- Create: `remotedev-ops/bin/remotedev-uninstall`
- Test: `remotedev-ops/tests/test_uninstall.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_uninstall.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
INST="$RDO/bin/remotedev-install"
UNINST="$RDO/bin/remotedev-uninstall"

t_uninstall() {
  local ws; ws="$(new_workspace)"; local sd="$ws/shims" rc="$ws/rc"
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$INST" >/dev/null 2>&1
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$UNINST" >/dev/null 2>&1
  assert_file_absent "$sd/cargo"
  assert_eq "0" "$(grep -c '>>> remotedev >>>' "$rc" || true)"
  rm -rf "$ws"
}
run_test "uninstall removes shims + rc block" t_uninstall

t_uninstall_idempotent() {
  local ws; ws="$(new_workspace)"; local sd="$ws/shims" rc="$ws/rc"
  : > "$rc"
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$UNINST" >/dev/null 2>&1; local r=$?
  rm -rf "$ws"; assert_eq 0 "$r"
}
run_test "uninstall with nothing installed is a no-op" t_uninstall_idempotent

summary
EOF
chmod +x remotedev-ops/tests/test_uninstall.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_uninstall.sh`
Expected: FAIL (`remotedev-uninstall` does not exist).

- [ ] **Step 3: Write `bin/remotedev-uninstall`**

```bash
cat > remotedev-ops/bin/remotedev-uninstall <<'EOF'
#!/usr/bin/env bash
# remotedev-uninstall — per-machine revert: remove the shim links + rc
# block. Leaves any repo's .remotedev / swapped launchers alone (that is
# `remotedev-disable`). Idempotent.
set -eo pipefail
. "$(dirname "$(readlink -f "$0")")/_common.sh"

RT="$(rdo_home)/runtime"
SD="$(shim_dir)"
RC="$(rc_file)"

if [ -d "$SD" ]; then
  for name in "${INTERCEPT[@]}" rd rd-exec; do
    [ -L "$SD/$name" ] && rm -f "$SD/$name"
  done
  rmdir "$SD" 2>/dev/null || warn "shim dir not empty, left in place: $SD"
fi

rc_block_remove "$RC"
log "removed shim links and rc wiring (open a new shell to drop the stale PATH)"
EOF
chmod +x remotedev-ops/bin/remotedev-uninstall
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_uninstall.sh`
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add remotedev-ops/bin/remotedev-uninstall remotedev-ops/tests/test_uninstall.sh
git commit -m "feat(remotedev-ops): remotedev-uninstall per-machine revert"
```

---

## Task 6: `remotedev-init` — build detection + `.remotedev` render

**Files:**
- Create: `remotedev-ops/bin/remotedev-init`
- Test: `remotedev-ops/tests/test_init_detect.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_init_detect.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-init"
CONTRACT='REMOTEDEV_HOST REMOTEDEV_REMOTE_DIR REMOTEDEV_EXCLUDES REMOTEDEV_ARTIFACTS BUILD_CMD TEST_CMD RUN_CMD'

# host_up is stubbed reachable so this task only exercises detection/write.
init() { local d="$1"; shift; ( cd "$d" && PATH="$(fixtures_path):$PATH" RD_FAKE_LOG=/dev/null bash "$BIN" "$@" ); }

t_cargo() {
  local ws; ws="$(new_workspace)"; cd "$ws"; echo '[package]
name = "demo"' > Cargo.toml
  init "$ws" >/dev/null 2>&1
  assert_file_has .remotedev 'REMOTEDEV_HOST="devbox"'
  assert_file_has .remotedev 'BUILD_CMD="cargo build --release"'
  assert_file_has .remotedev 'TEST_CMD="cargo test"'
  assert_file_has .remotedev 'target/release/demo'
  rm -rf "$ws"
}
run_test "init detects Cargo and fills verbs" t_cargo

t_none() {
  local ws; ws="$(new_workspace)"; cd "$ws"
  init "$ws" >/dev/null 2>&1
  assert_file_has .remotedev 'REMOTEDEV_HOST="devbox"'
  assert_file_has .remotedev '# BUILD_CMD='
  rm -rf "$ws"
}
run_test "init with no build system writes commented verbs" t_none

t_host_arg() {
  local ws; ws="$(new_workspace)"; cd "$ws"
  init "$ws" myhost >/dev/null 2>&1
  assert_file_has .remotedev 'REMOTEDEV_HOST="myhost"'
  rm -rf "$ws"
}
run_test "init accepts HOST argument" t_host_arg

t_idempotent() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  init "$ws" >/dev/null 2>&1
  init "$ws" >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc"
  init "$ws" --force >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"
}
run_test "init refuses overwrite without --force" t_idempotent

t_contract() {
  local ws; ws="$(new_workspace)"; cd "$ws"; echo '[package]
name="x"' > Cargo.toml
  init "$ws" >/dev/null 2>&1
  # every VAR= assignment (ignoring comments) must be in the contract set
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    local var="${line%%=*}"
    case " $CONTRACT " in *" $var "*) : ;; *) _fail "non-contract var: $var" ;; esac
  done < .remotedev
  rm -rf "$ws"
}
run_test "init emits only contract variables" t_contract

summary
EOF
chmod +x remotedev-ops/tests/test_init_detect.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_init_detect.sh`
Expected: FAIL (`remotedev-init` does not exist).

- [ ] **Step 3: Write `bin/remotedev-init`** (detection + render + `--force`/exit-2; ssh probe and launcher swap are added in Tasks 7–8)

```bash
cat > remotedev-ops/bin/remotedev-init <<'EOF'
#!/usr/bin/env bash
# remotedev-init [HOST] [--force] — per-repo: detect build system, write
# .remotedev. (ssh probe: Task 7; launcher swap: Task 8.)
set -eo pipefail
. "$(dirname "$(readlink -f "$0")")/_common.sh"

HOST="devbox"; FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -*)      die "unknown option: $a" ;;
    *)       HOST="$a" ;;
  esac
done

ROOT="$(repo_root)"
is_git_repo || warn "not a git repo; git-hide steps will be skipped"
CFG="$ROOT/.remotedev"
if [ -e "$CFG" ] && [ "$FORCE" -eq 0 ]; then
  warn ".remotedev already exists (use --force to overwrite; see remotedev-status)"
  exit 2
fi

BUILD=""; TEST=""; RUN=""; ART=""
if [ -f "$ROOT/Cargo.toml" ]; then
  local_name="$(sed -n 's/^name *= *"\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
  BUILD="cargo build --release"; TEST="cargo test"; RUN="cargo run --release"
  [ -n "$local_name" ] && ART="target/release/$local_name" || ART="# target/release/<bin>"
elif [ -f "$ROOT/pom.xml" ]; then
  BUILD="./mvnw -q package"; TEST="./mvnw test"; ART="# target/*.jar"
elif [ -f "$ROOT/build.gradle" ] || [ -f "$ROOT/build.gradle.kts" ]; then
  BUILD="./gradlew build"; TEST="./gradlew test"; ART="# build/libs/*.jar"
elif [ -f "$ROOT/go.mod" ]; then
  BUILD="go build ./..."; TEST="go test ./..."; RUN="go run ."
elif [ -f "$ROOT/package.json" ]; then
  pm=npm
  [ -f "$ROOT/pnpm-lock.yaml" ] && pm=pnpm
  [ -f "$ROOT/yarn.lock" ] && pm=yarn
  [ -f "$ROOT/bun.lockb" ] && pm=bun
  BUILD="$pm run build"; TEST="$pm test"
elif [ -f "$ROOT/pyproject.toml" ] || [ -f "$ROOT/uv.lock" ]; then
  TEST="uv run pytest"
fi

emit() { # NAME VALUE  -> "NAME=..." or "# NAME=" when empty
  if [ -n "$2" ]; then printf '%s="%s"\n' "$1" "$2"; else printf '# %s=\n' "$1"; fi
}
{
  echo "# .remotedev — generated by remotedev-ops. Edit freely."
  printf 'REMOTEDEV_HOST="%s"\n' "$HOST"
  echo '# REMOTEDEV_REMOTE_DIR="work/myproject"'
  echo '# REMOTEDEV_EXCLUDES=(.git target node_modules .venv build dist .gradle)'
  if [ -n "$ART" ] && [ "${ART#\#}" = "$ART" ]; then
    printf 'REMOTEDEV_ARTIFACTS=(\n  %s\n)\n' "$ART"
  else
    printf 'REMOTEDEV_ARTIFACTS=(\n  %s\n)\n' "${ART:-# path/to/artifact}"
  fi
  emit BUILD_CMD "$BUILD"
  emit TEST_CMD  "$TEST"
  emit RUN_CMD   "$RUN"
} > "$CFG"

log "wrote $CFG (host=$HOST)"
EOF
chmod +x remotedev-ops/bin/remotedev-init
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_init_detect.sh`
Expected: `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add remotedev-ops/bin/remotedev-init remotedev-ops/tests/test_init_detect.sh
git commit -m "feat(remotedev-ops): remotedev-init build detection + .remotedev render"
```

---

## Task 7: `remotedev-init` — ssh probe + offline + shim warning

**Files:**
- Modify: `remotedev-ops/bin/remotedev-init` (append probe logic before final `log`)
- Test: `remotedev-ops/tests/test_init_probe.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_init_probe.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-init"

t_offline_still_writes() {
  local ws out rc; ws="$(new_workspace)"; cd "$ws"
  out="$(PATH="$(fixtures_path):$PATH" RD_FAKE_HOST_UP=1 bash "$BIN" 2>&1)"; rc=$?
  assert_eq 0 "$rc"
  assert_file_has .remotedev 'REMOTEDEV_HOST="devbox"'
  assert_contains "$out" "unreachable"
  rm -rf "$ws"
}
run_test "init writes config + warns when host unreachable" t_offline_still_writes

t_warns_no_shim() {
  local ws out; ws="$(new_workspace)"; cd "$ws"
  out="$(REMOTEDEV_SHIM_DIR="$ws/none" PATH="$(fixtures_path):$PATH" bash "$BIN" 2>&1)"
  assert_contains "$out" "remotedev-install"
  rm -rf "$ws"
}
run_test "init warns when shim not installed" t_warns_no_shim

summary
EOF
chmod +x remotedev-ops/tests/test_init_probe.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_init_probe.sh`
Expected: FAIL (no "unreachable"/"remotedev-install" output yet).

- [ ] **Step 3: Edit `bin/remotedev-init`** — replace the final `log "wrote ..."` line with the probe block

In `remotedev-ops/bin/remotedev-init`, replace this exact line:

```bash
log "wrote $CFG (host=$HOST)"
```

with:

```bash
log "wrote $CFG (host=$HOST)"

shim_installed || warn "shim not installed — run 'remotedev-install' once on this machine for builds to be intercepted"

if host_up "$HOST"; then
  log "host '$HOST' reachable"
else
  warn "host '$HOST' unreachable now — config written; offline builds fall back to local. Run 'remotedev-verify' once online."
fi
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_init_probe.sh`
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Re-run the detection test to confirm no regression**

Run: `bash remotedev-ops/tests/test_init_detect.sh`
Expected: `5 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add remotedev-ops/bin/remotedev-init remotedev-ops/tests/test_init_probe.sh
git commit -m "feat(remotedev-ops): remotedev-init ssh probe + offline/shim warnings"
```

---

## Task 8: `remotedev-init` — Gradle/Maven swap + git-hide

**Files:**
- Modify: `remotedev-ops/bin/remotedev-init` (append swap logic at end)
- Test: `remotedev-ops/tests/test_init_swap.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_init_swap.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-init"

mk_gradle_repo() {
  local ws; ws="$(new_workspace)"; cd "$ws"; git init -q
  printf '#!/bin/sh\necho REAL_GRADLEW\n' > gradlew; chmod +x gradlew
  git add gradlew; git commit -qm init; printf '%s' "$ws"
}

t_swap() {
  local ws; ws="$(mk_gradle_repo)"; cd "$ws"
  PATH="$(fixtures_path):$PATH" bash "$BIN" >/dev/null 2>&1
  [ -f gradlew.real ] || _fail "gradlew.real missing"
  assert_file_has gradlew.real "REAL_GRADLEW"
  assert_file_has gradlew "rd-exec ./gradlew.real"
  # gradlew hidden from git (skip-worktree); gradlew.real + .remotedev excluded
  assert_eq "S" "$(git ls-files -v gradlew | cut -c1)"
  assert_file_has "$(git rev-parse --git-dir)/info/exclude" "gradlew.real"
  assert_file_has "$(git rev-parse --git-dir)/info/exclude" ".remotedev"
  rm -rf "$ws"
}
run_test "init swaps gradlew and hides changes from git" t_swap

t_swap_idempotent() {
  local ws; ws="$(mk_gradle_repo)"; cd "$ws"
  PATH="$(fixtures_path):$PATH" bash "$BIN" >/dev/null 2>&1
  PATH="$(fixtures_path):$PATH" bash "$BIN" --force >/dev/null 2>&1
  assert_file_has gradlew.real "REAL_GRADLEW"      # not a wrapper-of-wrapper
  assert_file_has gradlew "rd-exec ./gradlew.real"
  rm -rf "$ws"
}
run_test "init swap is idempotent (no double-swap)" t_swap_idempotent

summary
EOF
chmod +x remotedev-ops/tests/test_init_swap.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_init_swap.sh`
Expected: FAIL (no swap performed).

- [ ] **Step 3: Edit `bin/remotedev-init`** — append the swap block at end of file

Append to `remotedev-ops/bin/remotedev-init`:

```bash

# --- Gradle/Maven repo-local launcher swap + git-hide --------------------
RT="$(rdo_home)/runtime"
swap_launcher() { # launcher  wrapper-src
  local l="$1" src="$2"
  [ -f "$ROOT/$l" ] || [ -f "$ROOT/$l.real" ] || return 0
  if [ -f "$ROOT/$l.real" ]; then
    log "$l already swapped — refreshing wrapper"
  else
    mv "$ROOT/$l" "$ROOT/$l.real"
  fi
  cp "$src" "$ROOT/$l"; chmod +x "$ROOT/$l"
  ( cd "$ROOT" && git_hide "$l" && git_hide "$l.real" ) 2>/dev/null || true
}
swap_launcher gradlew "$RT/gradlew.wrapper"
swap_launcher mvnw    "$RT/mvnw.wrapper"
( cd "$ROOT" && git_hide .remotedev ) 2>/dev/null || true
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_init_swap.sh`
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Re-run init detect + probe tests for regressions**

Run: `bash remotedev-ops/tests/test_init_detect.sh && bash remotedev-ops/tests/test_init_probe.sh`
Expected: `5 passed, 0 failed` then `2 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add remotedev-ops/bin/remotedev-init remotedev-ops/tests/test_init_swap.sh
git commit -m "feat(remotedev-ops): remotedev-init Gradle/Maven swap + git-hide"
```

---

## Task 9: `remotedev-disable` (per-repo revert)

**Files:**
- Create: `remotedev-ops/bin/remotedev-disable`
- Test: `remotedev-ops/tests/test_disable.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_disable.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
INIT="$RDO/bin/remotedev-init"
DIS="$RDO/bin/remotedev-disable"

setup_repo() {
  local ws; ws="$(new_workspace)"; cd "$ws"; git init -q
  printf '#!/bin/sh\necho REAL\n' > gradlew; chmod +x gradlew
  git add gradlew; git commit -qm init
  PATH="$(fixtures_path):$PATH" bash "$INIT" >/dev/null 2>&1
  printf '%s' "$ws"
}

t_disable_restores() {
  local ws; ws="$(setup_repo)"; cd "$ws"
  bash "$DIS" >/dev/null 2>&1
  assert_file_absent gradlew.real
  assert_file_has gradlew "REAL"
  assert_eq "" "$(git ls-files -v gradlew | cut -c1 | tr -d H)"   # not skip-worktree
  [ -f .remotedev ] || _fail ".remotedev should remain without --purge"
  rm -rf "$ws"
}
run_test "disable restores launcher, keeps .remotedev" t_disable_restores

t_disable_purge() {
  local ws; ws="$(setup_repo)"; cd "$ws"
  bash "$DIS" --purge >/dev/null 2>&1
  assert_file_absent .remotedev
  rm -rf "$ws"
}
run_test "disable --purge removes .remotedev" t_disable_purge

t_disable_noop() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"; git init -q
  bash "$DIS" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"
}
run_test "disable with nothing set up is a no-op" t_disable_noop

summary
EOF
chmod +x remotedev-ops/tests/test_disable.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_disable.sh`
Expected: FAIL (`remotedev-disable` does not exist).

- [ ] **Step 3: Write `bin/remotedev-disable`**

```bash
cat > remotedev-ops/bin/remotedev-disable <<'EOF'
#!/usr/bin/env bash
# remotedev-disable [--purge] — per-repo revert: restore launchers, clear
# git-hide; --purge also removes .remotedev. Idempotent.
set -eo pipefail
. "$(dirname "$(readlink -f "$0")")/_common.sh"

PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1
ROOT="$(repo_root)"; cd "$ROOT"

restore() { # launcher
  local l="$1"
  if [ -f "$l.real" ]; then
    mv -f "$l.real" "$l"
    git_unhide "$l"; git_unhide "$l.real"
    log "restored $l"
  fi
}
restore gradlew
restore mvnw
git_unhide .remotedev

if [ "$PURGE" -eq 1 ] && [ -f .remotedev ]; then
  rm -f .remotedev; log "removed .remotedev"
fi
EOF
chmod +x remotedev-ops/bin/remotedev-disable
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_disable.sh`
Expected: `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add remotedev-ops/bin/remotedev-disable remotedev-ops/tests/test_disable.sh
git commit -m "feat(remotedev-ops): remotedev-disable per-repo revert"
```

---

## Task 10: `remotedev-status` (read-only report)

**Files:**
- Create: `remotedev-ops/bin/remotedev-status`
- Test: `remotedev-ops/tests/test_status.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_status.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
INIT="$RDO/bin/remotedev-init"
ST="$RDO/bin/remotedev-status"

t_status_configured() {
  local ws out; ws="$(new_workspace)"; cd "$ws"; echo '[package]
name="x"' > Cargo.toml
  PATH="$(fixtures_path):$PATH" bash "$INIT" >/dev/null 2>&1
  out="$(REMOTEDEV_SHIM_DIR="$ws/none" PATH="$(fixtures_path):$PATH" bash "$ST" 2>&1)"
  assert_contains "$out" "host: devbox"
  assert_contains "$out" "shim installed: no"
  assert_contains "$out" ".remotedev: present"
  rm -rf "$ws"
}
run_test "status reports config + machine state" t_status_configured

t_status_unconfigured() {
  local ws out rc; ws="$(new_workspace)"; cd "$ws"
  out="$(bash "$ST" 2>&1)"; rc=$?
  assert_contains "$out" ".remotedev: absent"
  rm -rf "$ws"; assert_eq 0 "$rc"
}
run_test "status without config is not an error" t_status_unconfigured

summary
EOF
chmod +x remotedev-ops/tests/test_status.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_status.sh`
Expected: FAIL (`remotedev-status` does not exist).

- [ ] **Step 3: Write `bin/remotedev-status`**

```bash
cat > remotedev-ops/bin/remotedev-status <<'EOF'
#!/usr/bin/env bash
# remotedev-status — read-only: machine install state + repo config.
set -eo pipefail
. "$(dirname "$(readlink -f "$0")")/_common.sh"

SD="$(shim_dir)"
if shim_installed; then echo "shim installed: yes ($SD)"; else echo "shim installed: no"; fi
case ":$PATH:" in *":$SD:"*) echo "shim on PATH: yes" ;; *) echo "shim on PATH: no" ;; esac

ROOT="$(repo_root)"; CFG="$ROOT/.remotedev"
if [ -f "$CFG" ]; then
  echo ".remotedev: present ($CFG)"
  read_cfg "$CFG"
  echo "host: ${REMOTEDEV_HOST:-<unset>}"
  echo "build: ${BUILD_CMD:-<none>}"
  echo "test:  ${TEST_CMD:-<none>}"
  [ -f "$ROOT/gradlew.real" ] && echo "gradlew: swapped"
  [ -f "$ROOT/mvnw.real" ] && echo "mvnw: swapped"
  if [ -n "${REMOTEDEV_HOST:-}" ] && host_up "$REMOTEDEV_HOST"; then
    echo "reachable: yes"
  else
    echo "reachable: no"
  fi
else
  echo ".remotedev: absent"
fi
EOF
chmod +x remotedev-ops/bin/remotedev-status
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_status.sh`
Expected: `2 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add remotedev-ops/bin/remotedev-status remotedev-ops/tests/test_status.sh
git commit -m "feat(remotedev-ops): remotedev-status read-only report"
```

---

## Task 11: `remotedev-verify` (standalone roundtrip)

**Files:**
- Create: `remotedev-ops/bin/remotedev-verify`
- Test: `remotedev-ops/tests/test_verify.sh` (server-gated)

- [ ] **Step 1: Write the gated test**

```bash
cat > remotedev-ops/tests/test_verify.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
V="$RDO/bin/remotedev-verify"

t_no_cfg() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  bash "$V" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 2 "$rc"
}
run_test "verify without .remotedev exits 2" t_no_cfg

t_roundtrip() {
  [ -n "${REMOTEDEV_TEST_HOST:-}" ] || { echo "  (skipped: set REMOTEDEV_TEST_HOST)"; return 0; }
  local ws; ws="$(new_workspace)"; cd "$ws"
  printf 'REMOTEDEV_HOST="%s"\n' "$REMOTEDEV_TEST_HOST" > .remotedev
  bash "$V" >/dev/null 2>&1 || _fail "verify roundtrip failed against $REMOTEDEV_TEST_HOST"
  rm -rf "$ws"
}
run_test "verify roundtrip against real host (gated)" t_roundtrip

summary
EOF
chmod +x remotedev-ops/tests/test_verify.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_verify.sh`
Expected: FAIL on the first test (`remotedev-verify` does not exist); roundtrip skipped.

- [ ] **Step 3: Write `bin/remotedev-verify`**

```bash
cat > remotedev-ops/bin/remotedev-verify <<'EOF'
#!/usr/bin/env bash
# remotedev-verify — standalone end-to-end check of the configured host
# (no rd-exec): unique remote dir, rsync push, ssh exec, pull, assert,
# cleanup. Exit 2 if no .remotedev.
set -eo pipefail
. "$(dirname "$(readlink -f "$0")")/_common.sh"

ROOT="$(repo_root)"; CFG="$ROOT/.remotedev"
[ -f "$CFG" ] || { warn "no .remotedev here"; exit 2; }
read_cfg "$CFG"
[ -n "${REMOTEDEV_HOST:-}" ] || die ".remotedev has no REMOTEDEV_HOST"
H="$REMOTEDEV_HOST"

RDIR="remotedev/rd-verify-$$"
WS="$(mktemp -d)"
cleanup() { ssh "$H" "rm -rf $(printf '%q' "$RDIR")" 2>/dev/null || true; rm -rf "$WS"; }
trap cleanup EXIT

echo "marker-$$" > "$WS/src.txt"
ssh "$H" "mkdir -p $(printf '%q' "$RDIR")"
rsync -az "$WS"/ "$H:$RDIR"/
ssh "$H" "cd $(printf '%q' "$RDIR") && echo built-on=\$(hostname) > out.txt && cat src.txt >> out.txt"
rsync -az "$H:$RDIR/out.txt" "$WS/out.txt"

grep -q "built-on=" "$WS/out.txt" || die "verify failed: no remote marker"
grep -q "marker-$$" "$WS/out.txt" || die "verify failed: source not round-tripped"
log "verify OK against '$H' ($(sed -n 's/built-on=//p' "$WS/out.txt"))"
EOF
chmod +x remotedev-ops/bin/remotedev-verify
```

- [ ] **Step 4: Run the test, verify it passes (roundtrip auto-skips without a host)**

Run: `bash remotedev-ops/tests/test_verify.sh`
Expected: `2 passed, 0 failed` (roundtrip prints "skipped").

- [ ] **Step 5: Run the gated roundtrip against the real server**

Run: `REMOTEDEV_TEST_HOST=devbox bash remotedev-ops/tests/test_verify.sh`
Expected: `2 passed, 0 failed` with the roundtrip actually executing (requires the `devbox` ssh alias to resolve).

- [ ] **Step 6: Commit**

```bash
git add remotedev-ops/bin/remotedev-verify remotedev-ops/tests/test_verify.sh
git commit -m "feat(remotedev-ops): remotedev-verify standalone roundtrip"
```

---

## Task 12: `remotedev-gc` (reclaim devbox space)

**Files:**
- Create: `remotedev-ops/bin/remotedev-gc`
- Test: `remotedev-ops/tests/test_gc.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > remotedev-ops/tests/test_gc.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
G="$RDO/bin/remotedev-gc"

t_no_cfg() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  bash "$G" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 2 "$rc"
}
run_test "gc without .remotedev exits 2" t_no_cfg

t_delete_present() {
  local ws fb rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  mkdir -p out; echo x > out/app; : > log
  PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" bash "$G" >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc"
  assert_file_has log "rm -rf -- remotedev/$(basename "$ws")/out/app"
  rm -rf "$ws"
}
run_test "gc deletes remote artifact when local copy exists" t_delete_present

t_skip_absent() {
  local ws fb out; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  : > log
  out="$(PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" bash "$G" 2>&1)"
  grep -q 'rm -rf' log && _fail "must not delete unrecovered artifact"
  assert_contains "$out" "keeping remote"
  rm -rf "$ws"
}
run_test "gc keeps remote when local copy is missing" t_skip_absent

t_offline_noop() {
  local ws fb rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  mkdir -p out; echo x > out/app; : > log
  PATH="$fb:$PATH" RD_FAKE_HOST_UP=1 RD_FAKE_LOG="$ws/log" bash "$G" >/dev/null 2>&1; rc=$?
  grep -q 'rm -rf' log && _fail "offline gc must not delete"
  rm -rf "$ws"; assert_eq 0 "$rc"
}
run_test "gc is a no-op when host unreachable" t_offline_noop

t_dry_run() {
  local ws fb out; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  mkdir -p out; echo x > out/app; : > log
  out="$(PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" bash "$G" --dry-run 2>&1)"
  grep -q 'rm -rf' log && _fail "--dry-run must not delete"
  assert_contains "$out" "would delete"
  rm -rf "$ws"
}
run_test "gc --dry-run mutates nothing" t_dry_run

t_real_gated() {
  [ -n "${REMOTEDEV_TEST_HOST:-}" ] || { echo "  (skipped: set REMOTEDEV_TEST_HOST)"; return 0; }
  local ws H RD; ws="$(new_workspace)"; cd "$ws"; H="$REMOTEDEV_TEST_HOST"
  RD="remotedev/rdo-gc-$$"
  printf 'REMOTEDEV_HOST="%s"\nREMOTEDEV_REMOTE_DIR="%s"\nREMOTEDEV_ARTIFACTS=(out/app)\n' "$H" "$RD" > .remotedev
  ssh "$H" "mkdir -p $(printf '%q' "$RD/out")" && ssh "$H" "echo remote > $(printf '%q' "$RD/out/app")"
  mkdir -p out; echo local > out/app          # local copy present → safe to gc
  bash "$G" >/dev/null 2>&1 || _fail "gc failed"
  if ssh "$H" "test -e $(printf '%q' "$RD/out/app")"; then
    ssh "$H" "rm -rf $(printf '%q' "$RD")"; _fail "remote artifact not deleted"
  fi
  ssh "$H" "rm -rf $(printf '%q' "$RD")"; rm -rf "$ws"
}
run_test "gc deletes on the real host (gated)" t_real_gated

summary
EOF
chmod +x remotedev-ops/tests/test_gc.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run: `bash remotedev-ops/tests/test_gc.sh`
Expected: FAIL (`remotedev-gc` does not exist); gated test prints "skipped".

- [ ] **Step 3: Write `bin/remotedev-gc`**

```bash
cat > remotedev-ops/bin/remotedev-gc <<'EOF'
#!/usr/bin/env bash
# remotedev-gc [--dry-run] — reclaim devbox space: delete only remote
# artifacts already copied back to this local repo. Never deletes
# unrecovered files, the source mirror, or build caches. Per repo.
set -eo pipefail
. "$(dirname "$(readlink -f "$0")")/_common.sh"

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

ROOT="$(repo_root)"; CFG="$ROOT/.remotedev"
[ -f "$CFG" ] || die "no .remotedev here"
read_cfg "$CFG"
[ -n "${REMOTEDEV_HOST:-}" ] || die ".remotedev has no REMOTEDEV_HOST"
H="$REMOTEDEV_HOST"
RD="${REMOTEDEV_REMOTE_DIR:-remotedev/$(basename "$ROOT")}"

if ! host_up "$H"; then
  warn "host '$H' unreachable — nothing to do"
  exit 0
fi

freed=0; skipped=0
for a in "${REMOTEDEV_ARTIFACTS[@]}"; do
  [ -n "$a" ] || continue
  if [ -e "$ROOT/$a" ]; then
    if [ "$DRY" -eq 1 ]; then
      log "would delete: $H:$RD/$a"
    else
      ssh "$H" "rm -rf -- $(printf '%q' "$RD/$a")"
      log "freed: $H:$RD/$a"
    fi
    freed=$((freed+1))
  else
    warn "not retrieved locally, keeping remote: $a"
    skipped=$((skipped+1))
  fi
done
log "gc done: freed=$freed skipped=$skipped"
EOF
chmod +x remotedev-ops/bin/remotedev-gc
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `bash remotedev-ops/tests/test_gc.sh`
Expected: `6 passed, 0 failed` (gated test prints "skipped").

- [ ] **Step 5: Run the gated real-host check**

Run: `REMOTEDEV_TEST_HOST=devbox bash remotedev-ops/tests/test_gc.sh`
Expected: `6 passed, 0 failed` with the gated test actually deleting on `devbox`.

- [ ] **Step 6: Commit**

```bash
git add remotedev-ops/bin/remotedev-gc remotedev-ops/tests/test_gc.sh
git commit -m "feat(remotedev-ops): remotedev-gc reclaim devbox space"
```

---

## Task 13: SKILL.md, README entry, full suite, finalize

**Files:**
- Create: `remotedev-ops/SKILL.md`
- Modify: `README.md` (repo root — add the skill to the list)

- [ ] **Step 1: Write `remotedev-ops/SKILL.md`**

```bash
cat > remotedev-ops/SKILL.md <<'EOF'
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
- Tests: `tests/run.sh` (zero-dep, server-free). The `verify` roundtrip is
  gated behind `REMOTEDEV_TEST_HOST`.
EOF
```

- [ ] **Step 2: Add the skill to the repo `README.md` skills list**

In `README.md`, find the line:

```
- [paperboy-ops](paperboy-ops/SKILL.md) — paperboy(영수증 프린터 HTTP 서비스)와 상호작용. 라이브 OpenAPI로 엔드포인트 탐색 후 generic 클라이언트로 호출.
```

Add immediately after it:

```
- [remotedev-ops](remotedev-ops/SKILL.md) — 로컬 repo를 devbox에서 원격 빌드하도록 세팅/해제. PATH shim 머신당 1회 설치 + repo당 .remotedev 구성. 오프라인 시 로컬 fallback. remotedev-gc로 회수 완료 산출물 정리(devbox 공간 회수).
```

- [ ] **Step 3: Run the entire suite**

Run: `bash remotedev-ops/tests/run.sh`
Expected: every `test_*.sh` reports `0 failed`; `run.sh` exits 0. (The
`verify` roundtrip auto-skips without `REMOTEDEV_TEST_HOST`.)

- [ ] **Step 4: Syntax-check every script**

Run:
```bash
for f in remotedev-ops/bin/* remotedev-ops/runtime/rd-exec remotedev-ops/runtime/rd-shim remotedev-ops/runtime/rd; do bash -n "$f" && echo "ok $f"; done
```
Expected: an `ok` line for each, no syntax errors.

- [ ] **Step 5: Smoke-test the symlink install path used by the skill loader**

Run:
```bash
ln -sfn ~/claude-skills/remotedev-ops ~/.claude/skills/remotedev-ops
~/.claude/skills/remotedev-ops/bin/remotedev-status >/dev/null 2>&1 && echo "resolves via symlink"
```
Expected: `resolves via symlink` (confirms `readlink -f` based path
resolution works through the install symlink).

- [ ] **Step 6: Commit**

```bash
git add remotedev-ops/SKILL.md README.md
git commit -m "feat(remotedev-ops): SKILL.md + register skill in README"
```

---

## Self-Review

**Spec coverage:**
- `remotedev-install` / `-uninstall` (per-machine) → Tasks 4, 5. ✓
- `remotedev-init` detection table, contract, `--force`/exit-2, offline,
  shim warning, Gradle/Maven swap + git-hide → Tasks 6, 7, 8. ✓
- `remotedev-disable [--purge]` → Task 9. ✓
- `remotedev-status` → Task 10. ✓
- `remotedev-verify` standalone + gated → Task 11. ✓
- `remotedev-gc` (delete only locally-retrieved artifacts; offline no-op;
  `--dry-run`; exit 2 no cfg) + server-gated real deletion → Task 12. ✓
- Embedded `runtime/` (4 hardening fixes) + ported regression tests →
  Tasks 1, 2. ✓
- `_common.sh` API (all helpers in the locked list) → Task 3. ✓
- Config Contract enforcement test → Task 6 (`t_contract`). ✓
- rc-block idempotency, fake HOME/rc + temp SHIM_DIR sandboxing → Tasks 3,
  4, 5. ✓
- SKILL.md + sibling-pattern layout + symlink install → Task 13. ✓
- Error-handling rows (not-git, already-swapped, no-build-system,
  uninstall-non-empty, gc offline/skip/dry-run) → covered in Tasks 5, 6, 8,
  12 tests/impl. ✓

**Placeholder scan:** No TBD/TODO; every code step contains complete script
content; every test step contains real assertions; modify-steps quote the
exact line to replace. ✓

**Type/name consistency:** `_common.sh` names (`shim_dir`, `rc_file`,
`rc_block_write/remove`, `git_hide/unhide`, `shim_installed`, `read_cfg`,
`repo_root`, `host_up`, `rdo_home`, `INTERCEPT`) are defined in Task 3 and
used with identical names/signatures in Tasks 4–12. Env override knobs
(`REMOTEDEV_SHIM_DIR`, `REMOTEDEV_RC`) are consistent across install/
uninstall/tests. Runtime path `runtime/rd-shim` consistent between
install impl and its test. ✓

No gaps found.
