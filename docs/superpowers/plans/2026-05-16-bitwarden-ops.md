# bitwarden-ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained CLI skill that resolves (reads) and registers (writes) Bitwarden personal-vault credentials so Claude Code can use them in any project, with the invariant that no secret value ever reaches Claude's context, argv, disk, or logs.

**Architecture:** No daemon. Thin bash wrappers in `bin/` source a shared `_common.sh` (die, require_cmd, locked-vault gate, `bw://` ref parser, mask). Reads stream values to stdout or a child process env only; writes read the secret from the controlling terminal (`/dev/tty`) and so are user-run, not Claude-run. A deterministic file-backed `bw` stub drives an offline pure-bash test harness.

**Tech Stack:** bash 5, `bw` (Bitwarden CLI), `jq`. Tests are a dependency-free pure-bash harness with a PATH stub for `bw`.

**Conventions locked for all tasks** (use these exact names — do not rename):
- Skill root: `bitwarden-ops/`. Sourced library: `bin/_common.sh`. Scripts: `bin/{bw-get,bw-exec,bw-ls,bw-put,bw-status}`.
- `_common.sh` functions: `die`, `require_cmd`, `require_session`, `parse_ref`, `mask`. After `parse_ref <ref>`: vars `REF_ITEM`, `REF_FIELD`, `REF_KIND` (`password|field|notes`).
- Env vars: `BW_SESSION` (vault session, user-supplied), `BW_EXIT` (one-shot exit code for `die`), `BITWARDEN_OPS_TEST_SECRET_FILE` (test-only seam for `bw-put`'s tty read), `BW_STUB_DB` / `BW_STUB_STATUS` (stub state, tests only).
- Exit codes: `0` ok, `1` generic/usage error, `3` locked vault (no `BW_SESSION`).
- Ref grammar: `bw://<item>` → password; `bw://<item>/<field>` → custom field; `bw://<item>/notes` → notes.

---

## File Structure

| Path | Responsibility |
|---|---|
| `bitwarden-ops/SKILL.md` | Skill frontmatter + when-to-use + hard rules + session setup. |
| `bitwarden-ops/bin/_common.sh` | Sourced helpers: `die`, `require_cmd`, `require_session`, `parse_ref`, `mask`. |
| `bitwarden-ops/bin/bw-get` | Resolve a `bw://` ref → stdout (read; pipe / ssh-agent use). |
| `bitwarden-ops/bin/bw-exec` | Resolve `NAME=bw://ref...` into child env, exec cmd (read; CLI-wrapper use). |
| `bitwarden-ops/bin/bw-ls` | List item / field names only — never values (metadata). |
| `bitwarden-ops/bin/bw-put` | Upsert value at a ref; secret read from `/dev/tty`; overwrite guard; sync-first. |
| `bitwarden-ops/bin/bw-status` | Vault lock + session + sync-staleness status (metadata). |
| `bitwarden-ops/tests/run.sh` | Test runner: cd skill root, prepend `tests/stubs` to PATH, run `test_*.sh`. |
| `bitwarden-ops/tests/lib.sh` | Assertion helpers + PATH stub setup. |
| `bitwarden-ops/tests/stubs/bw` | Deterministic file-backed fake Bitwarden CLI. |
| `bitwarden-ops/tests/test_*.sh` | Per-component tests. |

---

## Task 1: Skeleton + SKILL.md

**Files:**
- Create: `bitwarden-ops/SKILL.md`
- Create (dir markers): `bitwarden-ops/bin/`, `bitwarden-ops/tests/stubs/`
- Test: `bitwarden-ops/tests/test_skeleton.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_skeleton.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for d in bin tests/stubs; do
  [[ -d "$d" ]] || { echo "FAIL: missing dir $d"; exit 1; }
done
[[ -f SKILL.md ]] || { echo "FAIL: missing SKILL.md"; exit 1; }
# Frontmatter: name + description present.
head -1 SKILL.md | grep -qx -- '---' || { echo "FAIL: SKILL.md no frontmatter"; exit 1; }
grep -q '^name: bitwarden-ops$' SKILL.md || { echo "FAIL: name missing"; exit 1; }
grep -q '^description: ' SKILL.md || { echo "FAIL: description missing"; exit 1; }
# Hard invariant must be stated in the skill body.
grep -qi 'BW_SESSION' SKILL.md || { echo "FAIL: session model not documented"; exit 1; }
echo "PASS test_skeleton"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_skeleton.sh`
Expected: FAIL — missing dir / SKILL.md, non-zero exit.

- [ ] **Step 3: Create directories**

```bash
mkdir -p bitwarden-ops/bin bitwarden-ops/tests/stubs
```

- [ ] **Step 4: Create `bitwarden-ops/SKILL.md`**

```markdown
---
name: bitwarden-ops
description: Use when the user wants to read or register Bitwarden personal-vault credentials from any project — resolve a secret into a command (`bw-exec`), pipe it to a consumer like ssh-agent (`bw-get`), list what is stored without exposing values (`bw-ls`), register a not-yet-stored credential (`bw-put`, user-run), or check vault/session status (`bw-status`). Secret values never enter Claude's context, argv, disk, or logs. Self-contained; depends only on the `bw` CLI + `jq`.
---

# bitwarden-ops

Self-contained Bitwarden personal-vault (`bw`) credential toolkit. Reads resolve a
`bw://` reference to stdout or into a child process env; writes read the secret from
the controlling terminal and are therefore run by the user, not Claude. Deps: `bash`,
`bw` (Bitwarden CLI), `jq`.

## Resolve this skill's tools first
Tools are in `bin/` beside this SKILL.md. Set `BW` to this skill's base directory once,
then call every tool as `"$BW/bin/<tool>"` (works from any cwd; nothing on PATH):
```sh
BW="<absolute path of the directory containing this SKILL.md>"
"$BW/bin/bw-status"
```

## Session setup (the user does this once per session)
```sh
export BW_SESSION="$(bw unlock --raw)"   # the user types the master password — never Claude
```
No `BW_SESSION` ⇒ every command refuses to start (exit 3, "locked vault").

## Reference grammar
- `bw://<item>` → the item's password
- `bw://<item>/<field>` → custom field `<field>`
- `bw://<item>/notes` → the item's notes
- `--ssh` (bw-get) → SSH private key stored in notes (stdout only, for ssh-agent)

## When to use
- "Run X with a vault token" → `"$BW/bin/bw-exec" TOKEN=bw://item/api -- <cmd>`
- "Pipe a vault key (ssh-agent etc.)" → `"$BW/bin/bw-get" --ssh bw://ssh-host | ssh-add -`
- "What's stored (no values)?" → `"$BW/bin/bw-ls" [search]`
- "Register a credential I haven't stored" → tell the user to run
  `"$BW/bin/bw-put" bw://item/field` themselves; they paste the secret at the prompt
- "Vault/session status" → `"$BW/bin/bw-status"`

## Hard rules (non-negotiable)
1. **Master password: user only.** Only the user runs `bw unlock`. Claude never
   prompts for, receives, stores, or echoes it.
2. **Secret values never leak.** Reads → stdout / child env only. Writes → the
   user's terminal only. Never in Claude's output, argv, disk, or logs.
3. **Locked-vault default.** No `BW_SESSION` ⇒ refuse (exit 3). Ask the user to
   `bw unlock`; never handle the master password.
4. **bw-put is user-run.** It reads the secret from `/dev/tty`. Claude constructs
   the `bw://` target + `--type` and gives the user the exact command line to run
   themselves — Claude does not invoke `bw-put`.
5. **Overwrite needs eyes.** `bw-put` refuses to overwrite an existing non-empty
   value unless `--replace` is given. No deletion is supported at all.
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_skeleton.sh`
Expected: `PASS test_skeleton`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add bitwarden-ops/SKILL.md bitwarden-ops/tests/test_skeleton.sh
git commit -m "feat(bitwarden-ops): skeleton + SKILL.md"
```

---

## Task 2: Test harness + `bw` stub

**Files:**
- Create: `bitwarden-ops/tests/lib.sh`, `bitwarden-ops/tests/run.sh`, `bitwarden-ops/tests/stubs/bw`
- Test: `bitwarden-ops/tests/test_harness.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_harness.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

assert_eq "a" "a" "assert_eq works"
assert_contains "hello world" "world" "assert_contains works"
assert_status 0 'true' "assert_status 0 works"
assert_status 3 'exit 3' "assert_status 3 works"

# bw stub: deterministic, file-backed, on PATH via lib.sh.
export BW_STUB_DB="$(mktemp)"; echo '[]' > "$BW_STUB_DB"
assert_eq "unlocked" "$(bw status | jq -r .status)" "stub status unlocked"
bw sync >/dev/null; assert_eq "0" "$([[ -f "$BW_STUB_DB.synced" ]]; echo $?)" "stub sync marks synced"
rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"

finish
echo "PASS test_harness"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_harness.sh`
Expected: FAIL — `tests/lib.sh` missing, `source` errors, non-zero exit.

- [ ] **Step 3: Create `bitwarden-ops/tests/lib.sh`**

```bash
# shellcheck shell=bash
# Assertion helpers. Source this in test_*.sh files.
# Tests are offline and stub-driven: prepend tests/stubs so it shadows the real
# bw. Every test_*.sh cd's to the skill root before sourcing this, so $PWD is
# the skill root here. (tests/run.sh also sets this; harmless to repeat.)
export PATH="$PWD/tests/stubs:$PATH"
_FAILS=0

assert_eq() { # expected actual msg
  if [[ "$1" == "$2" ]]; then echo "  ok: $3";
  else echo "  FAIL: $3 — expected [$1] got [$2]"; _FAILS=$((_FAILS+1)); fi
}
assert_contains() { # haystack needle msg
  if [[ "$1" == *"$2"* ]]; then echo "  ok: $3";
  else echo "  FAIL: $3 — [$1] does not contain [$2]"; _FAILS=$((_FAILS+1)); fi
}
assert_not_contains() { # haystack needle msg
  if [[ "$1" != *"$2"* ]]; then echo "  ok: $3";
  else echo "  FAIL: $3 — [$1] unexpectedly contains [$2]"; _FAILS=$((_FAILS+1)); fi
}
# assert_status: command MUST be ONE single-quoted string.
assert_status() { # expected_code cmd msg
  local exp="$1" cmd="$2" msg="$3" rc=0
  ( eval "$cmd" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$exp" ]]; then echo "  ok: $msg";
  else echo "  FAIL: $msg — expected exit $exp got $rc"; _FAILS=$((_FAILS+1)); fi
}
finish() { [[ $_FAILS -eq 0 ]] || { echo "  ($_FAILS failed)"; exit 1; }; }
```

- [ ] **Step 4: Create `bitwarden-ops/tests/run.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/tests/stubs:$PATH"
rc=0
for t in tests/test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
[[ $rc -eq 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $rc
```

- [ ] **Step 5: Create `bitwarden-ops/tests/stubs/bw`**

```bash
#!/usr/bin/env bash
# Deterministic fake Bitwarden CLI. State = $BW_STUB_DB (JSON array of items).
# Models only the surface bitwarden-ops uses: status, sync, list items,
# get {item|password|notes|template}, encode, create item, edit item.
set -euo pipefail
DB="${BW_STUB_DB:?BW_STUB_DB not set}"
[[ -f "$DB" ]] || echo '[]' > "$DB"
cmd="${1:-}"; shift || true
# Drop `--session VALUE` wherever it appears.
args=(); while [[ $# -gt 0 ]]; do
  case "$1" in --session) shift 2 || shift;; *) args+=("$1"); shift;; esac
done
set -- ${args[@]+"${args[@]}"}

case "$cmd" in
  status) echo "{\"status\":\"${BW_STUB_STATUS:-unlocked}\"}" ;;
  sync) : > "$DB.synced"; echo "Syncing complete." ;;
  list)
    [[ "${1:-}" == items ]] || { echo "[]"; exit 0; }
    q=""; [[ "${2:-}" == --search ]] && q="${3:-}"
    jq --arg q "$q" '[.[]|select($q=="" or (.name|contains($q)))]' "$DB" ;;
  get)
    sub="${1:-}"; name="${2:-}"
    case "$sub" in
      template)
        echo '{"organizationId":null,"folderId":null,"type":1,"name":"","notes":null,"favorite":false,"fields":[],"login":{"username":null,"password":null},"secureNote":null}' ;;
      item)     jq -e --arg n "$name" '.[]|select(.name==$n or .id==$n)' "$DB" 2>/dev/null || { echo "Not found." >&2; exit 1; } ;;
      password) jq -er --arg n "$name" '.[]|select(.name==$n)|.login.password // empty' "$DB" 2>/dev/null || { echo "Not found." >&2; exit 1; } ;;
      notes)    jq -er --arg n "$name" '.[]|select(.name==$n)|.notes // empty' "$DB" 2>/dev/null || { echo "Not found." >&2; exit 1; } ;;
      *) echo "bw-stub: unknown get '$sub'" >&2; exit 1 ;;
    esac ;;
  encode) base64 -w0 ;;
  create)
    [[ "${1:-}" == item ]] || { echo "bw-stub: create '${1:-}'?" >&2; exit 1; }
    obj="$(base64 -d)"
    id="stub-$(jq -r '.name' <<<"$obj")-$RANDOM"
    obj="$(jq --arg id "$id" '.id=$id' <<<"$obj")"
    tmp="$(mktemp)"; jq --argjson o "$obj" '. + [$o]' "$DB" > "$tmp" && mv "$tmp" "$DB"
    jq -n --argjson o "$obj" '$o' ;;
  edit)
    [[ "${1:-}" == item ]] || { echo "bw-stub: edit '${1:-}'?" >&2; exit 1; }
    id="${2:?bw-stub: edit item needs id}"; obj="$(base64 -d)"
    tmp="$(mktemp)"; jq --arg id "$id" --argjson o "$obj" 'map(if .id==$id then $o else . end)' "$DB" > "$tmp" && mv "$tmp" "$DB"
    echo "edited" ;;
  *) echo "bw-stub: unknown cmd '$cmd'" >&2; exit 1 ;;
esac
```

- [ ] **Step 6: Make executables runnable + run test to verify it passes**

```bash
chmod +x bitwarden-ops/tests/stubs/bw bitwarden-ops/tests/run.sh
bash bitwarden-ops/tests/test_harness.sh
```
Expected: each `ok:` line, then `PASS test_harness`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add bitwarden-ops/tests/lib.sh bitwarden-ops/tests/run.sh bitwarden-ops/tests/stubs/bw bitwarden-ops/tests/test_harness.sh
git commit -m "feat(bitwarden-ops): pure-bash test harness + bw stub"
```

---

## Task 3: `bin/_common.sh`

**Files:**
- Create: `bitwarden-ops/bin/_common.sh`
- Test: `bitwarden-ops/tests/test_common.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_common.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

cat > bin/_probe <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
case "$1" in
  parse) parse_ref "$2"; echo "$REF_ITEM|$REF_FIELD|$REF_KIND" ;;
  session) require_session; echo "session-ok" ;;
  mask) printf 'BW_SESSION=abc123 plain\n' | mask ;;
esac
EOF
chmod +x bin/_probe
trap 'rm -f bin/_probe' EXIT

assert_eq "i||password" "$(BW_SESSION=x bash bin/_probe parse 'bw://i')" "ref item-only → password"
assert_eq "i|api|field" "$(BW_SESSION=x bash bin/_probe parse 'bw://i/api')" "ref item/field → field"
assert_eq "i|notes|notes" "$(BW_SESSION=x bash bin/_probe parse 'bw://i/notes')" "ref notes → notes"
assert_status 1 'BW_SESSION=x bash bin/_probe parse plainstring' "non-bw:// ref rejected"
assert_status 3 'env -u BW_SESSION bash bin/_probe session' "locked vault → exit 3"
assert_eq "session-ok" "$(BW_SESSION=x bash bin/_probe session)" "BW_SESSION set → ok"
assert_not_contains "$(BW_SESSION=x bash bin/_probe mask)" "abc123" "mask hides BW_SESSION value"

finish
echo "PASS test_common"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_common.sh`
Expected: FAIL — `bin/_common.sh` missing, `source` errors.

- [ ] **Step 3: Create `bitwarden-ops/bin/_common.sh`**

```bash
# shellcheck shell=bash
# Shared helpers for bitwarden-ops. Sourced by every bin/ script, not executed.
# Requires: bw, jq. Single rule: a secret value never reaches Claude/argv/disk/log.
set -euo pipefail

die() { echo "bitwarden-ops: $*" >&2; exit "${BW_EXIT:-1}"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "필수 명령 없음: $c"
  done
}

# Refuse before doing anything if the vault is locked (no session).
require_session() {
  [[ -n "${BW_SESSION:-}" ]] || BW_EXIT=3 die \
    "locked vault: BW_SESSION 미설정 — 사용자가 'export BW_SESSION=\"\$(bw unlock --raw)\"' 필요"
}

# parse_ref <bw://item[/field]> → sets REF_ITEM, REF_FIELD, REF_KIND.
parse_ref() {
  local ref="${1:-}" p
  [[ "$ref" == bw://* ]] || die "참조는 bw:// 로 시작해야 함: $ref"
  p="${ref#bw://}"
  if [[ "$p" == */* ]]; then
    REF_ITEM="${p%%/*}"; REF_FIELD="${p#*/}"
  else
    REF_ITEM="$p"; REF_FIELD=""
  fi
  [[ -n "$REF_ITEM" ]] || die "참조에 item 이 비어 있음: $ref"
  if [[ -z "$REF_FIELD" ]]; then REF_KIND=password
  elif [[ "$REF_FIELD" == notes ]]; then REF_KIND=notes
  else REF_KIND=field; fi
}

# Last-line-of-defense masker for accidental stream contamination.
mask() {
  sed -E \
    -e 's/(BW_SESSION=)[^[:space:]]+/\1***MASKED***/g' \
    -e 's/[A-Za-z0-9+\/]{40,}={0,2}/***MASKED-BLOB***/g'
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_common.sh`
Expected: every `ok:`, then `PASS test_common`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bitwarden-ops/bin/_common.sh bitwarden-ops/tests/test_common.sh
git commit -m "feat(bitwarden-ops): _common.sh — die, session gate, ref parser, mask"
```

---

## Task 4: `bin/bw-status`

**Files:**
- Create: `bitwarden-ops/bin/bw-status`
- Test: `bitwarden-ops/tests/test_status.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_status.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"; echo '[]' > "$BW_STUB_DB"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT

out="$(BW_SESSION=x bash bin/bw-status)"
assert_contains "$out" "session=set" "status shows session set"
assert_contains "$out" "vault=unlocked" "status shows unlocked"
assert_status 0 'BW_SESSION=x bash bin/bw-status' "unlocked+session → exit 0"

assert_status 3 'env -u BW_SESSION bash bin/bw-status' "no session → exit 3"
out2="$(env -u BW_SESSION bash bin/bw-status 2>&1 || true)"
assert_contains "$out2" "session=unset" "status shows session unset"

finish
echo "PASS test_status"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_status.sh`
Expected: FAIL — `bin/bw-status` missing.

- [ ] **Step 3: Create `bitwarden-ops/bin/bw-status`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
require_cmd bw jq

json=0; [[ "${1:-}" == "--json" ]] && json=1

sess="unset"; [[ -n "${BW_SESSION:-}" ]] && sess="set"
if [[ "$sess" == "set" ]]; then
  vault="$(bw status --session "$BW_SESSION" 2>/dev/null | jq -r '.status // "unknown"')" || vault="unknown"
else
  vault="locked"
fi

if [[ $json -eq 1 ]]; then
  jq -n --arg s "$sess" --arg v "$vault" '{session:$s,vault:$v}'
else
  echo "session=$sess"
  echo "vault=$vault"
fi

# Locked vault / no session is a non-zero (3) preflight signal.
[[ "$sess" == "set" && "$vault" == "unlocked" ]] || { BW_EXIT=3 die "locked vault 또는 BW_SESSION 미설정"; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_status.sh`
Expected: every `ok:`, then `PASS test_status`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bitwarden-ops/bin/bw-status bitwarden-ops/tests/test_status.sh
git commit -m "feat(bitwarden-ops): bw-status — session/vault preflight"
```

---

## Task 5: `bin/bw-get`

**Files:**
- Create: `bitwarden-ops/bin/bw-get`
- Test: `bitwarden-ops/tests/test_get.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_get.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"id1","name":"site","login":{"username":"u","password":"pw-secret"},
  "notes":"-----BEGIN OPENSSH PRIVATE KEY-----\nKEYBODY\n-----END OPENSSH PRIVATE KEY-----",
  "fields":[{"name":"api","value":"tok-123","type":1}]}]
JSON

assert_eq "pw-secret" "$(BW_SESSION=x bash bin/bw-get 'bw://site')" "password ref"
assert_eq "tok-123"   "$(BW_SESSION=x bash bin/bw-get 'bw://site/api')" "field ref"
assert_contains "$(BW_SESSION=x bash bin/bw-get 'bw://site/notes')" "BEGIN OPENSSH" "notes ref"
assert_contains "$(BW_SESSION=x bash bin/bw-get --ssh 'bw://site')" "KEYBODY" "--ssh returns notes key"
assert_status 1 'BW_SESSION=x bash bin/bw-get "bw://nope"' "missing item → error"
assert_status 1 'BW_SESSION=x bash bin/bw-get "bw://site/nofield"' "missing field → error"
assert_status 3 'env -u BW_SESSION bash bin/bw-get "bw://site"' "locked vault → exit 3"

finish
echo "PASS test_get"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_get.sh`
Expected: FAIL — `bin/bw-get` missing.

- [ ] **Step 3: Create `bitwarden-ops/bin/bw-get`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
require_cmd bw jq

ssh=0
[[ "${1:-}" == "--ssh" ]] && { ssh=1; shift; }
ref="${1:-}"
[[ -n "$ref" ]] || die "usage: bw-get [--ssh] bw://<item>[/<field>]"
require_session
parse_ref "$ref"

if [[ $ssh -eq 1 ]]; then
  bw get notes "$REF_ITEM" --session "$BW_SESSION" 2>/dev/null \
    || die "bw: ssh 키(notes) 해결 실패 — item 없음?: $REF_ITEM"
  exit 0
fi

case "$REF_KIND" in
  password)
    bw get password "$REF_ITEM" --session "$BW_SESSION" 2>/dev/null \
      || die "bw: 해결 실패 — item 없음?: $ref" ;;
  notes)
    bw get notes "$REF_ITEM" --session "$BW_SESSION" 2>/dev/null \
      || die "bw: notes 해결 실패 — item 없음?: $REF_ITEM" ;;
  field)
    item="$(bw get item "$REF_ITEM" --session "$BW_SESSION" 2>/dev/null)" \
      || die "bw: item 없음: $REF_ITEM"
    jq -er --arg f "$REF_FIELD" '.fields[]? | select(.name==$f) | .value' <<<"$item" \
      || die "bw: 필드 없음: '$REF_FIELD' (item '$REF_ITEM' 에)" ;;
esac
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_get.sh`
Expected: every `ok:`, then `PASS test_get`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bitwarden-ops/bin/bw-get bitwarden-ops/tests/test_get.sh
git commit -m "feat(bitwarden-ops): bw-get — ref → stdout, --ssh"
```

---

## Task 6: `bin/bw-exec`

**Files:**
- Create: `bitwarden-ops/bin/bw-exec`
- Test: `bitwarden-ops/tests/test_exec.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_exec.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"id1","name":"site","login":{"username":"u","password":"pw-secret"},
  "notes":null,"fields":[{"name":"api","value":"tok-123","type":1}]}]
JSON

# Value reaches the child via env only.
assert_eq "tok-123" "$(BW_SESSION=x bash bin/bw-exec API=bw://site/api -- printenv API)" "env injected"
out="$(BW_SESSION=x bash bin/bw-exec API=bw://site/api -- sh -c 'echo done')"
assert_eq "done" "$out" "cmd runs"

# Secret must NOT be in the child's own argv.
argv="$(BW_SESSION=x bash bin/bw-exec API=bw://site/api -- sh -c 'echo "$@"' _ )"
assert_not_contains "$argv" "tok-123" "secret absent from child argv"

assert_status 1 'BW_SESSION=x bash bin/bw-exec API=bw://site/api echo hi' "missing -- → usage error"
assert_status 1 'BW_SESSION=x bash bin/bw-exec -- echo hi' "no mapping → error"
assert_status 3 'env -u BW_SESSION bash bin/bw-exec API=bw://site/api -- true' "locked vault → exit 3"

finish
echo "PASS test_exec"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_exec.sh`
Expected: FAIL — `bin/bw-exec` missing.

- [ ] **Step 3: Create `bitwarden-ops/bin/bw-exec`**

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(dirname "$0")"
. "$HERE/_common.sh"
require_cmd bw jq

maps=()
while [[ $# -gt 0 && "$1" != "--" ]]; do maps+=("$1"); shift; done
[[ "${1:-}" == "--" ]] || die "usage: bw-exec NAME=bw://ref... -- <cmd> [args...]"
shift
[[ ${#maps[@]} -ge 1 ]] || die "최소 하나의 NAME=bw://ref 필요"
[[ $# -ge 1 ]] || die "-- 뒤에 실행할 명령 필요"
require_session

for m in "${maps[@]}"; do
  name="${m%%=*}"; ref="${m#*=}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "잘못된 env 이름: $name"
  [[ "$m" == *=* && "$ref" == bw://* ]] || die "형식은 NAME=bw://ref 이어야 함: $m"
  # bw-get streams the value; capture into the env only — never into argv.
  val="$("$HERE/bw-get" "$ref")" || exit $?
  export "$name=$val"
done

exec "$@"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_exec.sh`
Expected: every `ok:`, then `PASS test_exec`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bitwarden-ops/bin/bw-exec bitwarden-ops/tests/test_exec.sh
git commit -m "feat(bitwarden-ops): bw-exec — env injection, secret out of argv"
```

---

## Task 7: `bin/bw-ls`

**Files:**
- Create: `bitwarden-ops/bin/bw-ls`
- Test: `bitwarden-ops/tests/test_ls.sh`

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_ls.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"i1","name":"site-a","login":{"password":"SECRETA"},"notes":null,
  "fields":[{"name":"api","value":"FIELDSECRET","type":1}]},
 {"id":"i2","name":"db-b","login":{"password":"SECRETB"},"notes":null,"fields":[]}]
JSON

out="$(BW_SESSION=x bash bin/bw-ls)"
assert_contains "$out" "site-a" "lists item name"
assert_contains "$out" "db-b" "lists second item"
assert_contains "$out" "api" "lists field name"
assert_not_contains "$out" "SECRETA" "no password value in output"
assert_not_contains "$out" "FIELDSECRET" "no field value in output"

out2="$(BW_SESSION=x bash bin/bw-ls site)"
assert_contains "$out2" "site-a" "search match shown"
assert_not_contains "$out2" "db-b" "search filters out non-match"

assert_status 3 'env -u BW_SESSION bash bin/bw-ls' "locked vault → exit 3"

finish
echo "PASS test_ls"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_ls.sh`
Expected: FAIL — `bin/bw-ls` missing.

- [ ] **Step 3: Create `bitwarden-ops/bin/bw-ls`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
require_cmd bw jq

search="${1:-}"
require_session

if [[ -n "$search" ]]; then
  items="$(bw list items --search "$search" --session "$BW_SESSION" 2>/dev/null)" || items="[]"
else
  items="$(bw list items --session "$BW_SESSION" 2>/dev/null)" || items="[]"
fi

# Names only. Never .value / .login.password / .notes.
jq -r '.[] | .name, (.fields[]? | "  ." + .name)' <<<"$items"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_ls.sh`
Expected: every `ok:`, then `PASS test_ls`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bitwarden-ops/bin/bw-ls bitwarden-ops/tests/test_ls.sh
git commit -m "feat(bitwarden-ops): bw-ls — names only, never values"
```

---

## Task 8: `bin/bw-put`

**Files:**
- Create: `bitwarden-ops/bin/bw-put`
- Test: `bitwarden-ops/tests/test_put.sh`

`bw-put` reads the secret from `/dev/tty` in production. The single tty-read line
is isolated in `_read_secret`, overridable ONLY via `BITWARDEN_OPS_TEST_SECRET_FILE`
(set by the test harness, never in production). Tests exercise create / overwrite
guard / `--replace` / empty-rejection / sync-first through that seam without
weakening the production `/dev/tty` path.

- [ ] **Step 1: Write the failing test**

Create `bitwarden-ops/tests/test_put.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"; echo '[]' > "$BW_STUB_DB"
SECRET="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced" "$SECRET"' EXIT
export BITWARDEN_OPS_TEST_SECRET_FILE="$SECRET"

# 1) Create new password item.
printf 'new-pw' > "$SECRET"
out="$(BW_SESSION=x bash bin/bw-put 'bw://acct')"
assert_contains "$out" "created: bw://acct" "create announces"
assert_eq "0" "$([[ -f "$BW_STUB_DB.synced" ]]; echo $?)" "sync ran before write"
assert_eq "new-pw" "$(BW_SESSION=x bash bin/bw-get 'bw://acct')" "value round-trips"

# 2) Overwrite without --replace is refused.
printf 'changed' > "$SECRET"
assert_status 1 "BW_SESSION=x bash bin/bw-put 'bw://acct'" "overwrite needs --replace"
assert_eq "new-pw" "$(BW_SESSION=x bash bin/bw-get 'bw://acct')" "value unchanged after refusal"

# 3) Overwrite with --replace succeeds.
out3="$(BW_SESSION=x bash bin/bw-put 'bw://acct' --replace)"
assert_contains "$out3" "updated: bw://acct" "replace announces update"
assert_eq "changed" "$(BW_SESSION=x bash bin/bw-get 'bw://acct')" "value replaced"

# 4) Field create on new item, then notes.
printf 'tokv' > "$SECRET"
BW_SESSION=x bash bin/bw-put 'bw://svc/api' >/dev/null
assert_eq "tokv" "$(BW_SESSION=x bash bin/bw-get 'bw://svc/api')" "new field round-trips"

# 5) Empty value rejected.
: > "$SECRET"
assert_status 1 "BW_SESSION=x bash bin/bw-put 'bw://acct' --replace" "empty value rejected"

# 6) Locked vault.
assert_status 3 "env -u BW_SESSION bash bin/bw-put 'bw://acct'" "locked vault → exit 3"

finish
echo "PASS test_put"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash bitwarden-ops/tests/test_put.sh`
Expected: FAIL — `bin/bw-put` missing.

- [ ] **Step 3: Create `bitwarden-ops/bin/bw-put`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
require_cmd bw jq

ref=""; type=""; replace=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)    type="${2:?--type 값 필요}"; shift 2 ;;
    --replace) replace=1; shift ;;
    bw://*)    ref="$1"; shift ;;
    *) die "usage: bw-put bw://<item>[/<field>] [--type password|field|note] [--replace]" ;;
  esac
done
[[ -n "$ref" ]] || die "usage: bw-put bw://<item>[/<field>] [--type password|field|note] [--replace]"
require_session
parse_ref "$ref"

# Default type from the ref shape unless explicitly given.
if [[ -z "$type" ]]; then
  case "$REF_KIND" in password) type=password ;; notes) type=note ;; field) type=field ;; esac
fi
case "$type" in password|field|note) ;; *) die "잘못된 --type: $type" ;; esac

# Sync first so a stale local cache cannot clobber server state.
bw sync --session "$BW_SESSION" >/dev/null 2>&1 \
  || die "bw sync 실패 — 네트워크 확인 후 재시도 (stale 캐시 쓰기 방지)"

item_json="$(bw get item "$REF_ITEM" --session "$BW_SESSION" 2>/dev/null || true)"
cur=""
if [[ -n "$item_json" ]]; then
  case "$type" in
    password) cur="$(jq -r '.login.password // ""' <<<"$item_json")" ;;
    note)     cur="$(jq -r '.notes // ""' <<<"$item_json")" ;;
    field)    cur="$(jq -r --arg f "$REF_FIELD" '(.fields[]?|select(.name==$f)|.value)//""' <<<"$item_json")" ;;
  esac
fi
if [[ -n "$cur" && $replace -ne 1 ]]; then
  die "이미 값이 존재: $ref — 덮어쓰려면 --replace (기존 secret 손실 방지)"
fi

# The ONLY secret-input path. Production: controlling terminal. Test: a file the
# harness wrote (BITWARDEN_OPS_TEST_SECRET_FILE) — never set in production.
_read_secret() {
  if [[ -n "${BITWARDEN_OPS_TEST_SECRET_FILE:-}" ]]; then
    cat "$BITWARDEN_OPS_TEST_SECRET_FILE"; return
  fi
  local s
  printf 'secret for %s (입력 숨김): ' "$ref" > /dev/tty
  IFS= read -rs s < /dev/tty
  printf '\n' > /dev/tty
  printf '%s' "$s"
}
secret="$(_read_secret)"
[[ -n "$secret" ]] || die "빈 값은 등록하지 않음 — 재시도"

if [[ -z "$item_json" ]]; then
  tpl="$(bw get template item --session "$BW_SESSION")"
  case "$type" in
    password) obj="$(jq -n --argjson t "$tpl" --arg n "$REF_ITEM" --arg v "$secret" \
                 '$t + {type:1,name:$n,login:{username:null,password:$v}}')" ;;
    note)     obj="$(jq -n --argjson t "$tpl" --arg n "$REF_ITEM" --arg v "$secret" \
                 '$t + {type:2,name:$n,notes:$v,secureNote:{type:0}}')" ;;
    field)    obj="$(jq -n --argjson t "$tpl" --arg n "$REF_ITEM" --arg f "$REF_FIELD" --arg v "$secret" \
                 '$t + {type:1,name:$n,login:{username:null,password:null},fields:[{name:$f,value:$v,type:1}]}')" ;;
  esac
  printf '%s' "$obj" | bw encode | bw create item --session "$BW_SESSION" >/dev/null \
    || die "bw create 실패: $ref"
  echo "created: $ref"
else
  id="$(jq -r '.id' <<<"$item_json")"
  case "$type" in
    password) new="$(jq --arg v "$secret" '.login.password=$v' <<<"$item_json")" ;;
    note)     new="$(jq --arg v "$secret" '.notes=$v' <<<"$item_json")" ;;
    field)    new="$(jq --arg f "$REF_FIELD" --arg v "$secret" \
                 'if any(.fields[]?; .name==$f)
                  then (.fields |= map(if .name==$f then .value=$v else . end))
                  else .fields=((.fields // []) + [{name:$f,value:$v,type:1}]) end' <<<"$item_json")" ;;
  esac
  printf '%s' "$new" | bw encode | bw edit item "$id" --session "$BW_SESSION" >/dev/null \
    || die "bw edit 실패: $ref"
  echo "updated: $ref"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash bitwarden-ops/tests/test_put.sh`
Expected: every `ok:`, then `PASS test_put`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bitwarden-ops/bin/bw-put bitwarden-ops/tests/test_put.sh
git commit -m "feat(bitwarden-ops): bw-put — tty-input upsert, overwrite guard, sync-first"
```

---

## Task 9: Full-suite gate + executable bits + SKILL.md cross-check

**Files:**
- Modify: none (verification + chmod + final commit)
- Test: `bitwarden-ops/tests/run.sh` (all)

- [ ] **Step 1: Ensure all bin/ + stub are executable**

```bash
chmod +x bitwarden-ops/bin/bw-get bitwarden-ops/bin/bw-exec bitwarden-ops/bin/bw-ls \
         bitwarden-ops/bin/bw-put bitwarden-ops/bin/bw-status \
         bitwarden-ops/tests/stubs/bw bitwarden-ops/tests/run.sh
```
(`_common.sh` is sourced, not executed — no +x needed, mirrors existing skills.)

- [ ] **Step 2: Run the full suite**

Run: `cd bitwarden-ops && bash tests/run.sh`
Expected: each `== tests/test_*.sh` then `PASS ...`, final line `ALL TESTS PASSED`, exit 0.

- [ ] **Step 3: Clean-checkout order-independence check**

Run:
```bash
T=$(mktemp -d); rsync -a bitwarden-ops/ "$T/"; ( cd "$T" && bash tests/run.sh ); rm -rf "$T"
```
Expected: `ALL TESTS PASSED` (the suite has no cross-test or pre-existing-state dependency; each test makes its own `BW_STUB_DB`).

- [ ] **Step 4: SKILL.md cross-check (no placeholders / matches behavior)**

Verify by reading `bitwarden-ops/SKILL.md`:
- Every `bin/` tool named in "When to use" exists in `bin/`.
- Hard rule 4 (bw-put is user-run, reads `/dev/tty`) matches `bin/bw-put`.
- No "TODO"/"TBD". Run: `! grep -nE 'TODO|TBD' bitwarden-ops/SKILL.md`

- [ ] **Step 5: Commit**

```bash
git add -A bitwarden-ops
git commit -m "chore(bitwarden-ops): executable bits + full-suite green"
```

---

## Self-Review

**1. Spec coverage**

| Spec section | Covered by |
|---|---|
| §1 목적 (read+write, invariant: no secret to Claude/argv/disk/log) | Tasks 3 (mask/gate), 5/6 (read paths), 8 (tty-only write) |
| §2 사용 시점 / 범위 | Tasks 4–8 (one task per command); non-goals enforced by absence (no delete script) |
| §3.1 레포 구조 | File Structure table; Tasks 1–8 create exactly those files |
| §3.2 참조 문법 (대칭) | Task 3 `parse_ref` (REF_KIND); reused by bw-get/bw-exec/bw-put |
| §4 세션 모델 (locked-vault 기본, 사용자만 unlock) | Task 3 `require_session` (exit 3); every script calls it (Tasks 4–8) |
| §5.1 bw-get | Task 5 |
| §5.2 bw-exec | Task 6 (export+exec → secret not in argv; asserted) |
| §5.3 bw-ls | Task 7 (names only; value-absence asserted) |
| §5.4 bw-put (/dev/tty, type default, sync-first, overwrite guard, _read_secret seam) | Task 8 |
| §5.5 bw-status | Task 4 |
| §6 안전 계약 1–6 | Task 3 (gate, mask), 6 (argv-free), 8 (tty-only, --replace, sync-first) |
| §7 에러 처리 (no session=3, ref syntax, item vs field, empty, sync fail) | Tasks 3,5,8 (distinct messages + exit codes asserted) |
| §8 테스트 (parser, get→stdout, exec env-only, ls no values, put paths, locked, --ssh) | Tasks 3,5,6,7,8 test files; Task 9 full + clean-checkout |
| §9 비목표 (no delete/org/bws/attachment/migration/coupling) | No such code/tasks exist; skill is standalone (no cross-skill import) |

No gaps identified.

**2. Placeholder scan** — every code step contains full runnable content; no "TBD"/"TODO"/"similar to Task N"/"add error handling". Test code is concrete with explicit expected output.

**3. Type/name consistency** — `parse_ref` sets `REF_ITEM/REF_FIELD/REF_KIND` (Task 3) and is consumed with those exact names in bw-get (Task 5) and bw-put (Task 8). `die`/`require_cmd`/`require_session`/`mask` defined in Task 3, used identically in Tasks 4–8. `BW_EXIT` one-shot exit convention used consistently (Tasks 3,4). `BITWARDEN_OPS_TEST_SECRET_FILE` defined in Conventions, used only in Task 8 code + Task 8 test. Stub command surface (Task 2) — `status/sync/list/get {item,password,notes,template}/encode/create/edit` — matches exactly what bw-get/bw-ls/bw-status/bw-put invoke. `bw create item` / `bw edit item` read base64 from **stdin** (Task 8 pipes `... | bw encode | bw <create|edit>`); the stub decodes stdin accordingly (Task 2) — assumption noted: if a target `bw` build requires the encoded item as a positional arg instead of stdin, that would place the secret in argv and MUST NOT be used; pin to a `bw` version that accepts stdin.

Fixed inline: none required.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-16-bitwarden-ops.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
