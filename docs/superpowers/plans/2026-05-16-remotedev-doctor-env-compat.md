# remotedev-doctor (env-compat) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `remotedev-doctor` verb that compares local vs devbox CPU arch + glibc and flags when a devbox-built native artifact may not run locally, plus a one-time advisory call from `remotedev-init`.

**Architecture:** New self-contained `bin/remotedev-doctor` (sources `_common.sh`, single ssh probe, exit-code-signalled verdict). `remotedev-init` gains one advisory `|| true` line. The embedded runtime (`rd-exec`/`rd-shim`/`rd`) is untouched. Tests are zero-dependency bash with the existing fake `ssh` fixture extended for the probe.

**Tech Stack:** bash, `ssh`, `uname`, `getconf`/`ldd`. No new external dependency.

---

## File Structure

```
remotedev-ops/
├── bin/
│   ├── remotedev-doctor      # Task 2 — new verb
│   └── remotedev-init        # Task 3 — +1 advisory line at EOF
├── tests/
│   ├── fixtures/ssh          # Task 1 — +probe branch (RD_FAKE_UNAME/RD_FAKE_GLIBC)
│   └── test_doctor.sh        # Task 2 — new
└── SKILL.md                  # Task 4 — add verb row/notes
README.md                     # Task 4 — (no change needed; bullet already generic) verify only
```

`remotedev-doctor` reads test-only overrides `REMOTEDEV_FAKE_LOCAL_ARCH` /
`REMOTEDEV_FAKE_LOCAL_GLIBC` for the local probe; unset in normal use.

**Locked interfaces (used across tasks):**
- Probe command sent to the host (exact, single arg):
  `uname -m; getconf GNU_LIBC_VERSION 2>/dev/null || ldd --version 2>/dev/null | head -1`
- Fake `ssh` probe branch matches a last-arg beginning `uname -m` and prints
  `${RD_FAKE_UNAME:-x86_64}` then `glibc ${RD_FAKE_GLIBC:-2.39}`.
- Exit codes: `0` compatible / offline-skip, `1` warning (glibc devbox>local, or incomplete probe), `2` critical (arch mismatch) and no-`.remotedev`.

---

## Task 1: Extend the fake ssh fixture for the env probe

**Files:**
- Modify: `remotedev-ops/tests/fixtures/ssh`

- [ ] **Step 1: Show current fixture**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
cat -n remotedev-ops/tests/fixtures/ssh
```
Expected: a `case "$cmd" in` with `true)`, `"mkdir -p"*)`, `*)` branches.

- [ ] **Step 2: Add the probe branch**

Use the Edit tool on `remotedev-ops/tests/fixtures/ssh`. Replace exactly:
```
  "mkdir -p"*) exit 0 ;;
```
with:
```
  "mkdir -p"*) exit 0 ;;
  "uname -m"*)
    printf '%s\nglibc %s\n' "${RD_FAKE_UNAME:-x86_64}" "${RD_FAKE_GLIBC:-2.39}"
    exit 0 ;;
```
Also update the header comment line listing knobs. Replace exactly:
```
#   RD_FAKE_LOG RD_FAKE_HOST_UP RD_FAKE_BUILD_RC RD_FAKE_SLEEP RD_FAKE_CRIT
```
with:
```
#   RD_FAKE_LOG RD_FAKE_HOST_UP RD_FAKE_BUILD_RC RD_FAKE_SLEEP RD_FAKE_CRIT
#   RD_FAKE_UNAME RD_FAKE_GLIBC  (env-compat probe response)
```

- [ ] **Step 3: Verify the whole existing suite still passes (no regression)**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
bash -n remotedev-ops/tests/fixtures/ssh && echo "syntax ok"
bash remotedev-ops/tests/run.sh >/tmp/t1 2>&1; echo "suite=$?"; grep -E '^== |passed' /tmp/t1 | paste - -
```
Expected: `syntax ok`; every test file `0 failed`; `suite=0`. (The new branch only adds behavior for a command no existing test sends, so nothing regresses.)

- [ ] **Step 4: Commit**

```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
git add remotedev-ops/tests/fixtures/ssh
git commit -m "test(remotedev-ops): fake ssh answers the env-compat probe"
```

---

## Task 2: `remotedev-doctor` verb (TDD)

**Files:**
- Create: `remotedev-ops/bin/remotedev-doctor`
- Test: `remotedev-ops/tests/test_doctor.sh`

- [ ] **Step 1: Write the failing test**

```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
cat > remotedev-ops/tests/test_doctor.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
D="$RDO/bin/remotedev-doctor"

mkcfg() { printf 'REMOTEDEV_HOST="fakehost"\n' > .remotedev; }

t_no_cfg() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  bash "$D" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 2 "$rc"
}
run_test "doctor without .remotedev exits 2" t_no_cfg

t_offline() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" RD_FAKE_HOST_UP=1 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 0 "$rc"; assert_contains "$out" "offline"
}
run_test "doctor offline → note + exit 0" t_offline

t_compatible() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=2.39 \
         RD_FAKE_UNAME=x86_64 RD_FAKE_GLIBC=2.35 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 0 "$rc"; assert_contains "$out" "COMPATIBLE"
}
run_test "doctor arch== & devbox glibc<=local → COMPATIBLE exit 0" t_compatible

t_arch_mismatch() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=2.39 \
         RD_FAKE_UNAME=aarch64 RD_FAKE_GLIBC=2.39 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 2 "$rc"; assert_contains "$out" "CRITICAL"
  assert_contains "$out" "aarch64"
}
run_test "doctor arch mismatch → CRITICAL exit 2" t_arch_mismatch

t_glibc_warn() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=2.31 \
         RD_FAKE_UNAME=x86_64 RD_FAKE_GLIBC=2.39 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 1 "$rc"; assert_contains "$out" "WARNING"
  assert_contains "$out" "GLIBC"
}
run_test "doctor devbox glibc>local → WARNING exit 1" t_glibc_warn

t_local_glibc_unknown() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=unknown \
         RD_FAKE_UNAME=x86_64 RD_FAKE_GLIBC=2.39 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 0 "$rc"; assert_contains "$out" "COMPATIBLE"
}
run_test "doctor unknown local glibc → skip glibc compare, exit 0" t_local_glibc_unknown

t_brief() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=2.39 \
         RD_FAKE_UNAME=aarch64 RD_FAKE_GLIBC=2.39 bash "$D" --brief 2>&1)"; rc=$?
  local lines; lines="$(printf '%s\n' "$out" | grep -c .)"
  rm -rf "$ws"
  assert_eq 2 "$rc"                       # same verdict/exit as full mode
  [ "$lines" -le 2 ] || _fail "--brief should be 1-2 lines, got $lines"
}
run_test "doctor --brief → ≤2 lines, same exit code" t_brief

t_real_gated() {
  [ -n "${REMOTEDEV_TEST_HOST:-}" ] || { echo "  (skipped: set REMOTEDEV_TEST_HOST)"; return 0; }
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  printf 'REMOTEDEV_HOST="%s"\n' "$REMOTEDEV_TEST_HOST" > .remotedev
  bash "$D" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ] || _fail "expected COMPATIBLE (exit 0) vs real $REMOTEDEV_TEST_HOST, got $rc"
}
run_test "doctor vs real host → COMPATIBLE (gated)" t_real_gated

summary
EOF
chmod +x remotedev-ops/tests/test_doctor.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
bash remotedev-ops/tests/test_doctor.sh; echo "exit=$?"
```
Expected: FAIL (no `remotedev-doctor` yet); gated test prints "(skipped...)". If it does not fail, STOP / report BLOCKED.

- [ ] **Step 3: Write `remotedev-ops/bin/remotedev-doctor`**

```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
cat > remotedev-ops/bin/remotedev-doctor <<'EOF'
#!/usr/bin/env bash
# remotedev-doctor [--brief] — compare local vs devbox CPU arch + glibc and
# flag when a devbox-built native artifact may not run locally. Advisory:
# never mutates anything. Exit 0 compatible/offline, 1 warning/incomplete,
# 2 critical(arch)/no-.remotedev.
set -eo pipefail
. "$(dirname "$(readlink -f "$0")")/_common.sh"

BRIEF=0; [ "${1:-}" = "--brief" ] && BRIEF=1

ROOT="$(repo_root)"; CFG="$ROOT/.remotedev"
[ -f "$CFG" ] || { warn "no .remotedev here"; exit 2; }
read_cfg "$CFG"
[ -n "${REMOTEDEV_HOST:-}" ] || die ".remotedev has no REMOTEDEV_HOST"
H="$REMOTEDEV_HOST"

if ! host_up "$H"; then
  log "offline — compatibility not checked; re-run 'remotedev-doctor' when online"
  exit 0
fi

# first MAJOR.MINOR found, else "unknown"
glibc_ver() {
  local v; v="$(grep -oE '[0-9]+\.[0-9]+' | head -1)"
  [ -n "$v" ] && printf '%s' "$v" || printf 'unknown'
}

arch_local="${REMOTEDEV_FAKE_LOCAL_ARCH:-$(uname -m)}"
if [ -n "${REMOTEDEV_FAKE_LOCAL_GLIBC:-}" ]; then
  glibc_local="$REMOTEDEV_FAKE_LOCAL_GLIBC"
else
  glibc_local="$( { getconf GNU_LIBC_VERSION 2>/dev/null || ldd --version 2>/dev/null | head -1; } | glibc_ver )"
fi

probe="$(ssh "$H" 'uname -m; getconf GNU_LIBC_VERSION 2>/dev/null || ldd --version 2>/dev/null | head -1' 2>/dev/null)" || {
  warn "remote probe failed on '$H' — compatibility incomplete"
  exit 1
}
arch_remote="$(printf '%s\n' "$probe" | sed -n 1p)"
glibc_remote="$(printf '%s\n' "$probe" | sed -n '2,$p' | glibc_ver)"

# true if $1 > $2 as MAJOR.MINOR; false if either is "unknown"
ver_gt() {
  [ "$1" = unknown ] && return 1
  [ "$2" = unknown ] && return 1
  local a1="${1%%.*}" a2="${1#*.}" b1="${2%%.*}" b2="${2#*.}"
  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  [ "$a2" -gt "$b2" ]
}

verdict=COMPATIBLE; rc=0
if [ "$arch_local" != "$arch_remote" ]; then
  verdict=CRITICAL; rc=2
elif ver_gt "$glibc_remote" "$glibc_local"; then
  verdict=WARNING; rc=1
fi

if [ "$BRIEF" -eq 1 ]; then
  case "$verdict" in
    COMPATIBLE) log "env-compat: OK (arch $arch_local; glibc local $glibc_local / devbox $glibc_remote)" ;;
    WARNING)    warn "env-compat: devbox glibc $glibc_remote > local $glibc_local — dynamically-linked native binaries may fail locally (GLIBC_x.y not found); use a static/musl target or build locally" ;;
    CRITICAL)   warn "env-compat: arch differs (local $arch_local vs devbox $arch_remote) — native artifacts built on devbox cannot run locally; build this repo locally or target $arch_local" ;;
  esac
  exit "$rc"
fi

printf '                 %-12s %s\n' "local" "devbox"
printf '  arch           %-12s %s\n' "$arch_local" "$arch_remote"
printf '  glibc          %-12s %s\n' "$glibc_local" "$glibc_remote"
case "$verdict" in
  COMPATIBLE)
    echo "  verdict: COMPATIBLE" ;;
  WARNING)
    echo "  verdict: WARNING — devbox glibc newer than local"
    echo "  -> dynamically-linked native binaries may fail locally with 'GLIBC_x.y not found'"
    echo "  -> fix: build with a static/musl target, or build this repo locally" ;;
  CRITICAL)
    echo "  verdict: CRITICAL — CPU architecture differs"
    echo "  -> a native artifact built on devbox cannot exec locally"
    echo "  -> fix: build this repo locally, or target $arch_local" ;;
esac
echo "  note: matters for natively-compiled artifacts (Rust/C/C++/cgo); usually moot for JVM / pure-Python"
exit "$rc"
EOF
chmod +x remotedev-ops/bin/remotedev-doctor
```

- [ ] **Step 4: Run the test, verify it passes**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
bash remotedev-ops/tests/test_doctor.sh; echo "exit=$?"
```
Expected: `7 passed, 0 failed`, exit 0 (gated test prints "(skipped...)").

- [ ] **Step 5: Gated real-host check against devbox**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
REMOTEDEV_TEST_HOST=devbox bash remotedev-ops/tests/test_doctor.sh; echo "exit=$?"
ssh devbox 'ls -d remotedev/* 2>/dev/null | head' ; echo "(doctor is read-only — nothing created remotely)"
```
Expected: `8 passed, 0 failed`, exit 0; the gated test runs against real `devbox` and yields COMPATIBLE (same x86_64 arch; devbox glibc not newer than local — if devbox glibc is actually newer, exit 1 is the correct true result: in that case report DONE_WITH_CONCERNS with the printed local/devbox glibc values rather than altering the test).

- [ ] **Step 6: Syntax + commit**

```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
bash -n remotedev-ops/bin/remotedev-doctor && echo "syntax ok"
git add remotedev-ops/bin/remotedev-doctor remotedev-ops/tests/test_doctor.sh
git commit -m "feat(remotedev-ops): remotedev-doctor env-compatibility check"
```

---

## Task 3: Wire the one-time advisory call into `remotedev-init`

**Files:**
- Modify: `remotedev-ops/bin/remotedev-init` (append at EOF)
- Test: `remotedev-ops/tests/test_init_doctor.sh`

- [ ] **Step 1: Write the failing test**

```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
cat > remotedev-ops/tests/test_init_doctor.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-init"

t_init_runs_doctor_and_stays_zero() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  echo '[package]
name="x"' > Cargo.toml
  # arch mismatch would make doctor exit 2; init must STILL exit 0 and show the advisory
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 RD_FAKE_UNAME=aarch64 \
         bash "$BIN" 2>&1)"; rc=$?
  assert_eq 0 "$rc"
  assert_file_has .remotedev 'REMOTEDEV_HOST="devbox"'
  assert_contains "$out" "env-compat"
  rm -rf "$ws"
}
run_test "init runs doctor advisory and still exits 0" t_init_runs_doctor_and_stays_zero

summary
EOF
chmod +x remotedev-ops/tests/test_init_doctor.sh
```

- [ ] **Step 2: Run it, verify it fails**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
bash remotedev-ops/tests/test_init_doctor.sh; echo "exit=$?"
```
Expected: FAIL on `assert_contains "$out" "env-compat"` (init does not call doctor yet). If it does not fail, STOP / report BLOCKED.

- [ ] **Step 3: Append the advisory call to `remotedev-init`**

Append to the END of `remotedev-ops/bin/remotedev-init` (use `cat >>`; do not alter existing lines):
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
cat >> remotedev-ops/bin/remotedev-init <<'EOF'

# --- advisory env-compatibility check (never blocks setup) --------------
"$(dirname "$(readlink -f "$0")")/remotedev-doctor" --brief 2>&1 || true
EOF
```

- [ ] **Step 4: Run the test, verify it passes**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
bash remotedev-ops/tests/test_init_doctor.sh; echo "exit=$?"
```
Expected: `1 passed, 0 failed`, exit 0.

- [ ] **Step 5: Regression — existing init tests stay green**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
for t in test_init_detect test_init_probe test_init_swap; do bash remotedev-ops/tests/$t.sh >/tmp/r 2>&1 && echo "$t OK" || { echo "$t FAIL"; cat /tmp/r; }; done
```
Expected: `test_init_detect OK`, `test_init_probe OK`, `test_init_swap OK` (the `|| true` guarantees init's exit 0 regardless of doctor's verdict; the fake `ssh` already answers the probe from Task 1).

- [ ] **Step 6: Syntax + commit**

```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
bash -n remotedev-ops/bin/remotedev-init && echo "syntax ok"
git add remotedev-ops/bin/remotedev-init remotedev-ops/tests/test_init_doctor.sh
git commit -m "feat(remotedev-ops): remotedev-init runs doctor --brief advisory"
```

---

## Task 4: SKILL.md + full suite + finalize

**Files:**
- Modify: `remotedev-ops/SKILL.md`

- [ ] **Step 1: Add the doctor row + a note to SKILL.md**

In `remotedev-ops/SKILL.md`, the Commands table has a row:
```
| Confirm the server pipeline works | `bin/remotedev-verify` |
```
Use the Edit tool to insert immediately AFTER that line:
```
| Check the build artifact will run locally | `bin/remotedev-doctor [--brief]` |
```
Then, in the frontmatter `description:` value, replace exactly:
```
`remotedev-status` / `remotedev-verify` inspect;
```
with:
```
`remotedev-status` / `remotedev-verify` / `remotedev-doctor` inspect;
```
And in the `## Workflow` section, replace exactly:
```
3. `remotedev-status` to confirm; `remotedev-verify` once online.
```
with:
```
3. `remotedev-status` to confirm; `remotedev-verify` once online.
   `remotedev-doctor` flags arch/glibc skew that could make a devbox-built
   native artifact unrunnable locally (init runs it once automatically).
```

- [ ] **Step 2: Run the ENTIRE suite**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
bash remotedev-ops/tests/run.sh; echo "run.sh exit=$?"
```
Expected: every `test_*.sh` reports `0 failed` (incl. `test_doctor.sh` and `test_init_doctor.sh`); `run.sh exit=0`. Paste full output.

- [ ] **Step 3: Gated full check against devbox**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
REMOTEDEV_TEST_HOST=devbox bash remotedev-ops/tests/test_doctor.sh 2>&1 | tail -2
REMOTEDEV_TEST_HOST=devbox bash remotedev-ops/tests/test_verify.sh 2>&1 | tail -1
REMOTEDEV_TEST_HOST=devbox bash remotedev-ops/tests/test_gc.sh 2>&1 | tail -1
ssh devbox 'ls -d remotedev/rd-verify-* remotedev/rdo-gc-* 2>/dev/null && echo LEFTOVER || echo "remote clean"'
```
Expected: doctor gated `8 passed, 0 failed`; verify/gc still green; `remote clean`.

- [ ] **Step 4: Syntax-check every script**

Run:
```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
for f in remotedev-ops/bin/* remotedev-ops/runtime/rd-exec remotedev-ops/runtime/rd-shim remotedev-ops/runtime/rd; do bash -n "$f" && echo "ok $f"; done
```
Expected: an `ok` line for each, no errors.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/superpowers/worktrees/claude-skills/remotedev-ops-skill
git add remotedev-ops/SKILL.md
git commit -m "docs(remotedev-ops): document remotedev-doctor verb"
```

---

## Self-Review

**Spec coverage:**
- `remotedev-doctor [--brief]`, arch+glibc compare, verdict + exit codes 0/1/2 → Task 2. ✓
- no-`.remotedev` exit 2; offline exit 0; remote-probe-fail exit 1; local glibc unknown → skip glibc compare → Task 2 tests (`t_no_cfg`, `t_offline`, `t_local_glibc_unknown`) + impl. ✓
- arch mismatch CRITICAL exit 2; glibc devbox>local WARNING exit 1; `--brief` same verdict, ≤2 lines → Task 2 tests. ✓
- single ssh probe round-trip → Task 2 impl (one `ssh "$H" '...'`). ✓
- test-only local override env `REMOTEDEV_FAKE_LOCAL_ARCH/GLIBC` → Task 2 impl + used by tests. ✓
- fake ssh fixture answers probe via `RD_FAKE_UNAME/RD_FAKE_GLIBC` → Task 1. ✓
- init one-time advisory `--brief`, init always exit 0, defensive `|| true`, regression of existing init tests → Task 3. ✓
- runtime untouched → no task modifies `runtime/`. ✓
- docs (SKILL.md verb row/notes), full suite, gated, syntax → Task 4. ✓
- server-gated real-host doctor (COMPATIBLE/exit 0) → Task 2 `t_real_gated` + Task 4 Step 3. ✓

**Placeholder scan:** No TBD/TODO; every code step has complete content; modify-steps quote the exact line to replace/append; test steps contain real assertions. ✓

**Type/name consistency:** Exit codes (0/1/2) consistent across spec, impl, and every test. The probe command string is identical in `remotedev-doctor` (Task 2) and the fixture branch trigger (`"uname -m"*`, Task 1). Override env names `REMOTEDEV_FAKE_LOCAL_ARCH`/`REMOTEDEV_FAKE_LOCAL_GLIBC` and fixture knobs `RD_FAKE_UNAME`/`RD_FAKE_GLIBC` are spelled identically in fixture, impl, and tests. `glibc_ver`/`ver_gt` defined and used only within Task 2. ✓

No gaps found.
