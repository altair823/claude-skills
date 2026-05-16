# bitwarden-ops Session Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user run `bw-unlock` AFTER Claude Code is already running and have every `bw-*` command pick up the session — via a durable `$HOME/.cache/bitwarden-ops/session` file (0600) fallback, with env-wins precedence, no daemon, no `bw` backend swap.

**Architecture:** `bin/_common.sh` gains a source-time session-file fallback: if `BW_SESSION` is empty and `<cache>/session` is a non-empty file, it `export`s it for the current process — so all `bin/*` scripts (which source `_common.sh`) benefit with zero per-script changes. Two new user-facing commands: `bw-unlock` (user-run; `bw unlock` prompts the master password on the user's tty, then the raw session is written 0600 to the cache file) and `bw-lock` (Claude- or user-run; `bw lock` + remove the file). Reader and writer both resolve the same deterministic path from `$HOME` (or the `BITWARDEN_OPS_CACHE_DIR` test seam), so no env inheritance is needed.

**Tech Stack:** bash 5, `bw` (Bitwarden CLI), `jq`. Existing dependency-free pure-bash test harness with a PATH stub for `bw`.

**Conventions locked for all tasks** (use these exact names — do not rename):
- Skill root: `bitwarden-ops/`. Existing sourced lib: `bin/_common.sh` (functions `die`, `require_cmd`, `require_session`, `parse_ref`, `mask`).
- New helper function in `_common.sh`: `bwo_cache_dir` — echoes the cache dir, or echoes nothing (empty) when neither `BITWARDEN_OPS_CACHE_DIR` nor `HOME` is set (fail-closed: caller must NOT fall back to any other path).
- Cache path: `<cache>/session` where `<cache> = ${BITWARDEN_OPS_CACHE_DIR:-$HOME/.cache/bitwarden-ops}`. File mode 0600, dir mode 0700.
- Env vars: `BW_SESSION` (vault session — env wins over file), `BITWARDEN_OPS_CACHE_DIR` (test seam for the cache dir; harness only, never set in production), `BITWARDEN_OPS_TEST_SESSION_FILE` (test seam for `bw-unlock`'s session acquisition; harness only), `BW_EXIT` (one-shot exit code for `die`).
- New scripts: `bin/bw-unlock` (user-run), `bin/bw-lock` (user- or Claude-run). Both executable (chmod +x); `_common.sh` stays non-executable (sourced).
- Exit codes unchanged: `0` ok, `1` usage/fail, `3` locked vault (no session via env OR file).

---

## File Structure

| Path | Change | Responsibility |
|---|---|---|
| `bitwarden-ops/bin/_common.sh` | modify | Add `bwo_cache_dir` helper + source-time session-file fallback (env-wins). Tweak `require_session` message to mention `bw-unlock`. |
| `bitwarden-ops/bin/bw-unlock` | create | User-run: acquire session (`bw unlock` on user tty; test seam) → write `<cache>/session` 0600 atomically. |
| `bitwarden-ops/bin/bw-lock` | create | `bw lock` + remove the session file. Idempotent. Claude-callable (no secret input). |
| `bitwarden-ops/tests/lib.sh` | modify | Isolate every test from the developer's real `~/.cache` by exporting a per-run empty `BITWARDEN_OPS_CACHE_DIR`. |
| `bitwarden-ops/tests/stubs/bw` | modify | Add a `lock)` case (no-op success) so `bw-lock` works offline. |
| `bitwarden-ops/tests/test_session_file.sh` | create | env-wins, file-fallback (functional via bw-get+stub), both-absent exit 3, empty-file exit 3, mask still hides. |
| `bitwarden-ops/tests/test_unlock.sh` | create | writes 0600 file / dir 0700 / replaces existing / empty-session reject / fail-closed when cache unresolvable. |
| `bitwarden-ops/tests/test_lock.sh` | create | removes file + calls `bw lock` / idempotent when no file. |
| `bitwarden-ops/SKILL.md` | modify | Session-setup section, hard rules, "When to use" — document the file fallback + `bw-unlock`/`bw-lock`. |
| `docs/superpowers/specs/2026-05-16-bitwarden-ops-design.md` | modify | Amend §4 (session model), §5 (command list), §9 (non-goals) to reflect the fallback. |

---

## Task 1: `_common.sh` session-file fallback + test isolation

**Files:**
- Modify: `bitwarden-ops/bin/_common.sh`
- Modify: `bitwarden-ops/tests/lib.sh`
- Test: `bitwarden-ops/tests/test_session_file.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_session_file.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

# Throwaway probe: source _common.sh, print the resolved BW_SESSION.
cat > bin/_sprobe <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
echo "${BW_SESSION:-<unset>}"
EOF
chmod +x bin/_sprobe
trap 'rm -f bin/_sprobe' EXIT

CDIR="$(mktemp -d)"
export BITWARDEN_OPS_CACHE_DIR="$CDIR/c"      # not created yet → no session file
export BW_STUB_DB="$(mktemp)"
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"i","name":"x","login":{"username":"u","password":"pw-secret"},"notes":null,"fields":[]}]
JSON
trap 'rm -rf "$CDIR" "$BW_STUB_DB" "$BW_STUB_DB.synced"; rm -f bin/_sprobe' EXIT

# 1) both absent → locked (exit 3) and probe shows unset
assert_eq "<unset>" "$(env -u BW_SESSION bash bin/_sprobe)" "no env, no file → unset"
assert_status 3 'env -u BW_SESSION bash bin/bw-get "bw://x"' "no env, no file → exit 3"

# 2) file present → adopted (probe) and functional (bw-get via stub)
mkdir -p "$CDIR/c"; chmod 700 "$CDIR/c"
printf 'file-sess' > "$CDIR/c/session"; chmod 600 "$CDIR/c/session"
assert_eq "file-sess" "$(env -u BW_SESSION bash bin/_sprobe)" "file adopted when env unset"
assert_eq "pw-secret" "$(env -u BW_SESSION bash bin/bw-get 'bw://x')" "file fallback is functional"

# 3) env-wins: env set + file present → env value used, file ignored
assert_eq "env-sess" "$(BW_SESSION=env-sess bash bin/_sprobe)" "env wins over file"

# 4) empty file treated as absent → locked
: > "$CDIR/c/session"
assert_eq "<unset>" "$(env -u BW_SESSION bash bin/_sprobe)" "empty session file → unset"
assert_status 3 'env -u BW_SESSION bash bin/bw-get "bw://x"' "empty file → exit 3"

# 5) mask still hides a leaked session value
printf 'BW_SESSION=supersecretvalue plain\n' | \
  (cd "$PWD" && bash -c '. bin/_common.sh; mask') > "$CDIR/m" 2>/dev/null || true
assert_not_contains "$(cat "$CDIR/m")" "supersecretvalue" "mask still hides session"

finish
echo "PASS test_session_file"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_session_file.sh`
Expected: FAIL — `bwo_cache_dir`/fallback not implemented (file-fallback assertions fail; probe shows `<unset>` when a file exists), non-zero exit.

- [ ] **Step 3: Modify `bitwarden-ops/tests/lib.sh` — isolate the cache dir**

The new source-time fallback in `_common.sh` would otherwise read the developer's *real* `~/.cache/bitwarden-ops/session` (if they ran `bw-unlock` for real), breaking every existing locked-vault test. Force an isolated, empty cache dir for the whole suite. After the existing `export PATH=...` line near the top of `tests/lib.sh`, add:

```bash
# Session-file fallback (see _common.sh) must never pick up the developer's real
# ~/.cache/bitwarden-ops/session during tests. Pin every test to an isolated,
# non-existent cache dir; individual tests override BITWARDEN_OPS_CACHE_DIR as needed.
export BITWARDEN_OPS_CACHE_DIR="$(mktemp -d)/cache"
```

- [ ] **Step 4: Modify `bitwarden-ops/bin/_common.sh`**

(a) After the `die()` function (after current line 6), add the cache-dir helper:

```bash
# Resolve the runtime cache dir. Test seam: BITWARDEN_OPS_CACHE_DIR.
# Echoes nothing (empty) when neither the seam nor HOME is set — callers MUST
# treat empty as "no fallback location" and fail closed (never write/read
# a secret to an arbitrary path).
bwo_cache_dir() {
  if [[ -n "${BITWARDEN_OPS_CACHE_DIR:-}" ]]; then
    echo "$BITWARDEN_OPS_CACHE_DIR"
  elif [[ -n "${HOME:-}" ]]; then
    echo "$HOME/.cache/bitwarden-ops"
  fi
}
```

(b) Replace the `require_session()` body message (current lines 16-19) to mention `bw-unlock`:

```bash
# Refuse before doing anything if the vault is locked (no session via env OR file).
require_session() {
  [[ -n "${BW_SESSION:-}" ]] || BW_EXIT=3 die \
    "locked vault: 세션 없음 — 사용자가 본인 터미널에서 'bw-unlock' 실행 (또는 export BW_SESSION=\"\$(bw unlock --raw)\")"
}
```

(c) At the END of the file (after `mask()`), append the source-time fallback:

```bash

# Session-file fallback (design: 2026-05-16-bitwarden-ops-session-persistence).
# env-wins: only when BW_SESSION is empty do we adopt a non-empty session file.
# Runs at source time so every bin/* script (incl. bw-status, which reads
# BW_SESSION directly) benefits with no per-script change. `-s` treats an
# empty file as absent. $(<file) is used (no pipeline under pipefail).
if [[ -z "${BW_SESSION:-}" ]]; then
  _bwo_cd="$(bwo_cache_dir)"
  if [[ -n "$_bwo_cd" && -s "$_bwo_cd/session" ]]; then
    export BW_SESSION="$(<"$_bwo_cd/session")"
  fi
  unset _bwo_cd
fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_session_file.sh`
Expected: every `ok:`, then `PASS test_session_file`, exit 0.

- [ ] **Step 6: Run the full suite (regression — existing 8 tests must stay green)**

Run: `cd bitwarden-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`, exit 0 (the `tests/lib.sh` isolation keeps `env -u BW_SESSION` tests at exit 3 because the pinned cache dir has no session file).

- [ ] **Step 7: Commit**

```bash
git add bitwarden-ops/bin/_common.sh bitwarden-ops/tests/lib.sh bitwarden-ops/tests/test_session_file.sh
git commit -m "feat(bitwarden-ops): session-file fallback in _common.sh (env-wins)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `bin/bw-unlock`

**Files:**
- Create: `bitwarden-ops/bin/bw-unlock`
- Test: `bitwarden-ops/tests/test_unlock.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_unlock.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

CDIR="$(mktemp -d)/c"
export BITWARDEN_OPS_CACHE_DIR="$CDIR"
FAKE="$(mktemp)"
export BITWARDEN_OPS_TEST_SESSION_FILE="$FAKE"
trap 'rm -rf "$(dirname "$CDIR")" "$FAKE"' EXIT

# 1) writes the session file with correct perms
printf 'sess-AAA' > "$FAKE"
out="$(bash bin/bw-unlock)"
assert_contains "$out" "$CDIR/session" "announces stored path"
assert_eq "sess-AAA" "$(cat "$CDIR/session")" "session written"
assert_eq "600" "$(stat -c '%a' "$CDIR/session")" "session file is 0600"
assert_eq "700" "$(stat -c '%a' "$CDIR")" "cache dir is 0700"

# 2) re-unlock replaces
printf 'sess-BBB' > "$FAKE"
bash bin/bw-unlock >/dev/null
assert_eq "sess-BBB" "$(cat "$CDIR/session")" "re-unlock replaces session"

# 3) empty session is rejected (no file clobber)
printf 'sess-BBB' > "$CDIR/session"
: > "$FAKE"
assert_status 1 'bash bin/bw-unlock' "empty session rejected"
assert_eq "sess-BBB" "$(cat "$CDIR/session")" "existing session untouched on empty"

# 4) fail-closed when cache dir unresolvable (no seam, no HOME)
printf 'x' > "$FAKE"
assert_status 1 'env -u HOME -u BITWARDEN_OPS_CACHE_DIR bash bin/bw-unlock' "no cache dir → fail closed"

finish
echo "PASS test_unlock"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_unlock.sh`
Expected: FAIL — `bin/bw-unlock` missing.

- [ ] **Step 3: Create `bitwarden-ops/bin/bw-unlock`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
require_cmd bw

cd="$(bwo_cache_dir)"
[[ -n "$cd" ]] || die "캐시 경로 해석 불가 (HOME 미설정·BITWARDEN_OPS_CACHE_DIR 미지정) — 세션을 임의 위치에 쓰지 않음"

# Acquire the session. Production: `bw unlock --raw` prompts the master password
# on the user's terminal (never Claude). Test seam: BITWARDEN_OPS_TEST_SESSION_FILE
# (harness only; never set in production) supplies a fake session, bypassing bw.
_acquire_session() {
  if [[ -n "${BITWARDEN_OPS_TEST_SESSION_FILE:-}" ]]; then
    cat "$BITWARDEN_OPS_TEST_SESSION_FILE"; return
  fi
  bw unlock --raw
}
session="$(_acquire_session)" || die "bw unlock 실패 — 마스터 비밀번호 확인 후 재시도"
[[ -n "$session" ]] || die "빈 세션은 저장하지 않음"

mkdir -p "$cd"
chmod 700 "$cd" 2>/dev/null || true
# mktemp creates the file 0600; write, then atomic same-dir rename. The session
# value is never world-readable and never on durable disk outside <cache>.
tmp="$(mktemp "$cd/.session.XXXXXX")"
printf '%s' "$session" > "$tmp"
mv -f "$tmp" "$cd/session"
echo "세션 저장됨: $cd/session (이 호스트에서 bw-lock 전까지 Claude 가 사용)"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_unlock.sh`
Expected: every `ok:`, then `PASS test_unlock`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x bitwarden-ops/bin/bw-unlock
git add bitwarden-ops/bin/bw-unlock bitwarden-ops/tests/test_unlock.sh
git commit -m "feat(bitwarden-ops): bw-unlock — user-run, writes 0600 session file

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `bin/bw-lock` + stub `lock`

**Files:**
- Create: `bitwarden-ops/bin/bw-lock`
- Modify: `bitwarden-ops/tests/stubs/bw`
- Test: `bitwarden-ops/tests/test_lock.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_lock.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

CDIR="$(mktemp -d)/c"
export BITWARDEN_OPS_CACHE_DIR="$CDIR"
trap 'rm -rf "$(dirname "$CDIR")"' EXIT

# 1) removes an existing session file and reports
mkdir -p "$CDIR"; chmod 700 "$CDIR"
printf 'sess' > "$CDIR/session"; chmod 600 "$CDIR/session"
out="$(bash bin/bw-lock)"
assert_contains "$out" "세션 잠금" "announces lock"
[[ ! -e "$CDIR/session" ]] && echo "  ok: session file removed" \
  || { echo "  FAIL: session file remained"; exit 1; }

# 2) idempotent: no file present → still succeeds
assert_status 0 'bash bin/bw-lock' "idempotent when no session file"

# 3) bw lock was invoked (stub prints a marker)
assert_contains "$(bash bin/bw-lock 2>&1)" "Vault locked" "bw lock invoked"

finish
echo "PASS test_lock"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_lock.sh`
Expected: FAIL — `bin/bw-lock` missing and stub has no `lock` case.

- [ ] **Step 3: Modify `bitwarden-ops/tests/stubs/bw` — add a `lock` case**

In the `case "$cmd" in` block, add this line immediately after the `sync)` line:

```bash
  lock) echo "Vault locked." ;;
```

- [ ] **Step 4: Create `bitwarden-ops/bin/bw-lock`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
require_cmd bw

# Lock the vault server-side. Idempotent — already-locked is not an error here.
bw lock >/dev/null 2>&1 || true

# Remove the cached session file (best-effort shred). No secret input → safe for
# Claude to invoke. Absent file is fine (idempotent).
cd="$(bwo_cache_dir)"
if [[ -n "$cd" && -e "$cd/session" ]]; then
  if command -v shred >/dev/null 2>&1; then
    shred -u "$cd/session" 2>/dev/null || rm -f "$cd/session"
  else
    rm -f "$cd/session"
  fi
fi
echo "세션 잠금: vault locked, 세션 파일 제거"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_lock.sh`
Expected: every `ok:`, then `PASS test_lock`, exit 0.

- [ ] **Step 6: Commit**

```bash
chmod +x bitwarden-ops/bin/bw-lock
git add bitwarden-ops/bin/bw-lock bitwarden-ops/tests/stubs/bw bitwarden-ops/tests/test_lock.sh
git commit -m "feat(bitwarden-ops): bw-lock — bw lock + remove session file (idempotent)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Documentation — SKILL.md + amend original design doc

**Files:**
- Modify: `bitwarden-ops/SKILL.md`
- Modify: `docs/superpowers/specs/2026-05-16-bitwarden-ops-design.md`
- Test: `bitwarden-ops/tests/test_docs.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_docs.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

S=SKILL.md
grep -q 'bw-unlock' "$S"            || { echo "FAIL: SKILL.md missing bw-unlock"; exit 1; }
grep -q 'bw-lock' "$S"              || { echo "FAIL: SKILL.md missing bw-lock"; exit 1; }
grep -q 'cache/bitwarden-ops' "$S"  || { echo "FAIL: SKILL.md missing cache path"; exit 1; }
grep -qiE 'env.*win|BW_SESSION.*우선|precedence' "$S" || { echo "FAIL: SKILL.md missing env-wins note"; exit 1; }
! grep -nE 'TODO|TBD' "$S"          || { echo "FAIL: SKILL.md has TODO/TBD"; exit 1; }
# Every bin/ tool the docs name must exist.
for t in bw-get bw-exec bw-ls bw-put bw-status bw-unlock bw-lock; do
  [[ -x "bin/$t" ]] || { echo "FAIL: bin/$t missing or not executable"; exit 1; }
done
echo "PASS test_docs"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_docs.sh`
Expected: FAIL — SKILL.md does not yet mention `bw-unlock`/`bw-lock`/cache path.

- [ ] **Step 3: Update `bitwarden-ops/SKILL.md`**

Replace the "## Session setup" section (the block starting `## Session setup (the user does this once per session)` through the line `No \`BW_SESSION\` ⇒ every command refuses to start (exit 3, "locked vault").`) with:

```markdown
## Session setup (the user does this once per session)
Either is fine — **env wins** when both are present:

```sh
# A) classic: export in the shell BEFORE launching Claude Code
export BW_SESSION="$(bw unlock --raw)"   # the user types the master password — never Claude

# B) any time (even after Claude is already running): run in YOUR terminal
"$BW/bin/bw-unlock"                       # bw prompts the master password on your tty
```
(B) writes the raw session to `$HOME/.cache/bitwarden-ops/session` (0600, durable,
outside any repo). Every `bw-*` command reads it when `BW_SESSION` is unset, so the
user can unlock at any point and Claude picks it up. `bw-lock` ends the session
(`bw lock` + removes the file). No `BW_SESSION` and no session file ⇒ every command
refuses to start (exit 3, "locked vault").
```

In the "## When to use" section, add these two lines after the `bw-status` line:

```markdown
- "Unlock so Claude can use the vault" → tell the user to run `"$BW/bin/bw-unlock"`
  in their own terminal (bw prompts their master password; Claude never sees it)
- "Lock / end the session" → `"$BW/bin/bw-lock"` (Claude may run this)
```

In "## Hard rules (non-negotiable)", replace hard rule 3 with:

```markdown
3. **Locked-vault default.** No `BW_SESSION` env AND no `$HOME/.cache/bitwarden-ops/session`
   ⇒ refuse (exit 3). Tell the user to run `bw-unlock` themselves; never handle the
   master password. The session file is a durable 0600 file (the live vault session
   key, not a stored credential); it is the one accepted at-rest secret, kept outside
   any repo. `bw-lock` ends it.
```

- [ ] **Step 4: Amend `docs/superpowers/specs/2026-05-16-bitwarden-ops-design.md`**

In **§4 (세션 모델)**, append this paragraph at the end of the section:

```markdown

> **보강(2026-05-16, 세션 영속):** `BW_SESSION` 미설정 시 `$HOME/.cache/bitwarden-ops/session`
> (0600, durable, repo 밖) 를 폴백으로 사용한다(env-wins). 사용자는 Claude 가 이미 떠 있어도
> `bw-unlock` 으로 unlock 할 수 있고, `bw-lock` 으로 종료한다. 상세: 별도 설계 문서
> `2026-05-16-bitwarden-ops-session-persistence-design.md`.
```

In **§5 (명령)**, add two rows describing `bw-unlock` (user-run; `bw unlock` on user tty → writes 0600 cache file) and `bw-lock` (Claude/user; `bw lock` + remove file, idempotent), matching the table/format already used in that section.

In **§9 (비목표)**, append:

```markdown
- 세션 영속의 자가 max-age/TTL, tmpfs/`$XDG_RUNTIME_DIR`, 암호화/키링/TPM, 데몬(`bw serve`),
  백엔드 교체(`rbw`). 같은-UID 공격자 방어는 범위 밖(OS 계정 보안). 위협 B(영속·백업 잔존)는
  사용자가 의도적으로 수용. (근거: `2026-05-16-bitwarden-ops-session-persistence-design.md` §5·§7)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_docs.sh`
Expected: `PASS test_docs`, exit 0. (Requires Tasks 2-3 done so `bin/bw-unlock`/`bin/bw-lock` exist and are executable.)

- [ ] **Step 6: Commit**

```bash
git add bitwarden-ops/SKILL.md docs/superpowers/specs/2026-05-16-bitwarden-ops-design.md bitwarden-ops/tests/test_docs.sh
git commit -m "docs(bitwarden-ops): document session-file fallback + bw-unlock/bw-lock

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Full-suite gate + executable bits

**Files:**
- Modify: none (verification + chmod + final commit)

- [ ] **Step 1: Ensure new bin/ scripts are executable**

```bash
chmod +x bitwarden-ops/bin/bw-unlock bitwarden-ops/bin/bw-lock
```
(`_common.sh` stays non-executable — sourced.)

- [ ] **Step 2: Run the full suite**

Run: `cd bitwarden-ops && bash tests/run.sh`
Expected: every `== tests/test_*.sh` then `PASS ...`; the 8 pre-existing tests PLUS `test_session_file`, `test_unlock`, `test_lock`, `test_docs`; final line `ALL TESTS PASSED`, exit 0.

- [ ] **Step 3: Clean-checkout order-independence check**

Run (from repo root):
```bash
T=$(mktemp -d); rsync -a bitwarden-ops/ "$T/"; ( cd "$T" && bash tests/run.sh ); echo "rc=$?"; rm -rf "$T"
```
Expected: `ALL TESTS PASSED`, rc=0 (every test pins its own `BITWARDEN_OPS_CACHE_DIR`; no dependence on the developer's real `~/.cache` or repo state).

- [ ] **Step 4: Secret-hygiene + env-wins spot re-check**

```bash
cd bitwarden-ops
C=$(mktemp -d)/c; export BITWARDEN_OPS_CACHE_DIR="$C"; export PATH="$PWD/tests/stubs:$PATH"
export BW_STUB_DB=$(mktemp); echo '[{"id":"i","name":"x","login":{"password":"ZZSECRET"},"notes":null,"fields":[]}]' > "$BW_STUB_DB"
mkdir -p "$C"; chmod 700 "$C"; printf 'filesess' > "$C/session"; chmod 600 "$C/session"
# file fallback works, and the session value is NOT echoed by bw-get
env -u BW_SESSION bash bin/bw-get bw://x 2>/tmp/e >/tmp/o
grep -q pw 2>/dev/null /tmp/o; grep -q 'filesess' /tmp/o /tmp/e && echo SESSION-LEAK || echo no-session-leak
# env-wins: bogus file + valid env → still works
printf 'GARBAGE' > "$C/session"
BW_SESSION=x bash bin/bw-get bw://x  # expect ZZSECRET
rm -f /tmp/o /tmp/e "$BW_STUB_DB"; rm -rf "$(dirname "$C")"
```
Expected: `no-session-leak`; the env-wins call prints `ZZSECRET` (bogus file ignored because env is set).

- [ ] **Step 5: Commit (only if chmod produced a change; otherwise report clean)**

```bash
git add -A bitwarden-ops
git commit -m "chore(bitwarden-ops): executable bits + full-suite green (session persistence)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```
If `chmod +x` was already captured in Tasks 2-3 commits and nothing is staged, do NOT fabricate a change — report the tree is already clean/green with `git status --porcelain` (empty) and the final suite result. That is a valid completion for a gate task.

---

## Self-Review

**1. Spec coverage** (`2026-05-16-bitwarden-ops-session-persistence-design.md`)

| Spec section | Covered by |
|---|---|
| §1 목적 (unlock after Claude running) | Task 1 (source-time fallback), Task 2 (`bw-unlock`) |
| §2 메커니즘 (`$HOME/.cache`, `BITWARDEN_OPS_CACHE_DIR` seam, env-wins, empty=absent) | Task 1 (`bwo_cache_dir`, fallback block, test_session_file env-wins/empty/both-absent) |
| §3.1 `bw-unlock` (user-run, tty master pw, 0600 atomic, replace, empty-reject, fail-closed) | Task 2 (all 4 test cases) |
| §3.2 `bw-lock` (bw lock + rm, idempotent, Claude-callable) | Task 3 |
| §4 `_common.sh` exports at source so bin/* unchanged; `require_session` message | Task 1 Step 4(b)(c); regression Step 6 proves bw-status/bw-get unchanged still work |
| §5 보안 (durable 0600, repo 밖, mask) | Task 1 (mask regression test), Task 2 (0600/0700 asserts), Task 5 Step 4 (no-session-leak) |
| §6 에러 처리 (stale→exit3, empty→absent, no HOME→fail-closed, lock idempotent) | Task 1 (empty/both-absent), Task 2 (fail-closed), Task 3 (idempotent) |
| §7 비목표 | No max-age/tmpfs/encryption/daemon/rbw code anywhere; §9 doc amendment (Task 4) records it |
| §8 테스트 | Tasks 1-3 test files enumerate exactly §8's cases; Task 5 full + clean-checkout |
| §9 자기완결 | No other-skill references introduced; deps still bash/bw/jq; pure-bash stub |

No gaps identified.

**2. Placeholder scan** — every step has full runnable code/commands and explicit expected output. No "TBD"/"add error handling"/"similar to Task N". The §5 design-doc table edit (Task 4 Step 4 "§5 add two rows ... matching the table/format already used") references the existing doc's own format rather than reproducing an unseen table — the editor must open that section; this is an edit-in-place instruction, not a code placeholder.

**3. Type/name consistency** — `bwo_cache_dir` defined in Task 1, consumed identically in Task 2 (`cd="$(bwo_cache_dir)"`) and Task 3. `BITWARDEN_OPS_CACHE_DIR` (seam) and `BITWARDEN_OPS_TEST_SESSION_FILE` (bw-unlock seam) used consistently across `_common.sh`, `tests/lib.sh`, and the test files. Session file path `<cache>/session` identical in fallback (Task 1), writer (Task 2), remover (Task 3). `require_session`/`die`/`require_cmd`/`mask` reused unchanged. Exit codes 1/3 consistent with the existing skill.

Fixed inline: none required.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-16-bitwarden-ops-session-persistence.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review (spec then code quality) between tasks.

**2. Inline Execution** — execute in this session via executing-plans with checkpoints.

Which approach?
