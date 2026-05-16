# homelab-ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CLI toolkit + declarative inventory so Claude Code can safely operate a heterogeneous homelab fleet, where every state change passes through one graded guard chokepoint and is forensically logged.

**Architecture:** No daemon. Thin bash wrappers in `bin/` are called by Claude. All mutations go through `bin/guard`, which grades the action (safe/caution/destructive) by action-type × target `env`/`tags`, enforces a Bitwarden-session gate, runs dry-run + explicit approval for destructive ops, and appends an append-only JSONL audit record (runtime-local, gitignored) + full run log + pre-op state snapshot. Credentials live in inventory as `bw://` references only and are resolved at call time, in memory, never on disk. Provisioning Phase 1 uses the Proxmox API/SSH directly behind a stable `guard provision` interface (IaC is deferred).

**Tech Stack:** bash 5, `jq` (JSON construction/query), `python3`+PyYAML (YAML→JSON), `curl` (Proxmox REST), `ssh`/`ssh-agent`, Bitwarden `bw` CLI. Tests are a dependency-free pure-bash harness with PATH stubs for `bw`/`curl`/`ssh`.

**Conventions locked for all tasks** (use these exact names — do not rename):
- Sourced library: `bin/_lib.sh`. Functions: `die`, `mask`, `new_op_id`, `audit_append`, `run_log_path`. Vars: `REPO_ROOT`, `AUDIT_LOG`, `RUNS_DIR`, `HOMELAB_SESSION_ID`.
- Guard subcommands: `guard grade <action> <target-id>` (prints grade only) and `guard <action> <target-id> [--approve] [-- <extra>...]` (executes).
- Env vars: `BW_SESSION` (vault session, user-supplied), `HOMELAB_SESSION_ID` (session correlation), `HOMELAB_BACKEND` (test override for the action backend), `HL_EXIT` (one-shot exit code for `die`).
- Exit codes: `0` ok, `1` generic error, `3` vault locked, `10` approval required (dry-run/summary already printed), `20` backend failed, `30` denied.
- Audit JSON fields (exact keys): `ts session op actor action target grade env tags inv_snapshot dryrun_hash approver approved_at exit duration_ms`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `bin/_lib.sh` | Sourced helpers: IDs, `die`, secret masking, audit append, run-log path. |
| `bin/inv` | Read-only inventory query (list/get/resolve/children/group). |
| `bin/bw-resolve` | Resolve a single `bw://` ref to a secret on stdout (memory only). |
| `bin/guard` | The single chokepoint: grading, gates, dry-run, approval, audit, snapshot. |
| `bin/_backend` | Real action dispatcher (pve/ssh-run). Overridable by `HOMELAB_BACKEND` in tests. |
| `bin/pve` | Proxmox REST API client (token via `bw-resolve`, TLS verify on). |
| `bin/ssh-run` | SSH exec wrapper (`StrictHostKeyChecking=yes`, key via ssh-agent, never on disk). |
| `bin/forensics` | Timeline reconstruction over `logs/audit.jsonl` + run logs. |
| `provisioning/phase1` | Phase-1 provisioning backend (Proxmox clone/create; dry-run prints plan). |
| `inventory/fleet.yaml` | Declarative fleet (hosts/VMs/LXC/appliances). |
| `inventory/groups.yaml` | Logical groups → member ids. |
| `logs/audit.jsonl` | Append-only audit log (runtime-local, gitignored — not committed). |
| `logs/runs/<sess>/<op>.log` | Full masked stdout/stderr per op. |
| `tests/lib.sh` | Assertion helpers. |
| `tests/run.sh` | Test runner (discovers `tests/test_*.sh`, prepends `tests/stubs` to PATH). |
| `tests/stubs/{bw,curl,ssh,ssh-agent,ssh-add}` | Deterministic command stubs. |
| `skill/SKILL.md` | Canonical (git-tracked) global skill content. |
| `bin/install-skill` | One-shot idempotent installer: copies skill to `~/.claude/skills/homelab-ops/`, writes `~/.config/homelab-ops/config`. |
| `~/.claude/skills/homelab-ops/SKILL.md` | Installed global skill — usable from ANY project (cross-project fleet status/metrics). |
| `~/.config/homelab-ops/config` | `HOMELAB_REPO=<repo path>` pointer (default `~/projects/homelab-ops`). |
| `CLAUDE.md` | Operating rules (no guard bypass, BW_SESSION required, deny-by-default, no log gaps). |
| `README.md` | Human setup/usage. |
| `.gitignore` | Exclude secrets/sessions/.env/tfstate/run logs. |

---

### Task 1: Repo skeleton, .gitignore, README

**Files:**
- Create: `.gitignore`, `README.md`
- Create (dir markers): `inventory/`, `bin/`, `provisioning/`, `logs/runs/`, `tests/stubs/`

- [ ] **Step 1: Write the failing test**

Create `tests/test_skeleton.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# .gitignore must exclude secrets, sessions, env, tfstate, and run logs.
out="$(git check-ignore -v -- logs/runs/x/y.log .env secrets.txt foo.tfstate 2>/dev/null || true)"
echo "$out" | grep -q 'logs/runs' || { echo "FAIL: run logs not ignored"; exit 1; }
echo "$out" | grep -q '\.env'      || { echo "FAIL: .env not ignored"; exit 1; }
echo "$out" | grep -q 'tfstate'    || { echo "FAIL: tfstate not ignored"; exit 1; }

# logs/ is runtime-local operational state, NOT git-tracked (incl. audit.jsonl).
# Requirement is "never lose a record", not tamper-evidence (see design §6/§10).
git check-ignore -q logs/audit.jsonl || { echo "FAIL: audit.jsonl must be ignored"; exit 1; }

# logs/runs is runtime-local (gitignored), so it is intentionally NOT asserted.
for d in inventory bin provisioning tests/stubs; do
  [[ -d "$d" ]] || { echo "FAIL: missing dir $d"; exit 1; }
done
echo "PASS test_skeleton"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_skeleton.sh`
Expected: FAIL (e.g. `FAIL: run logs not ignored` or missing dir), non-zero exit.

- [ ] **Step 3: Create directories and keep-files**

```bash
mkdir -p inventory bin provisioning logs/runs tests/stubs
touch tests/stubs/.gitkeep
# logs/ (incl. audit.jsonl and runs/) is runtime-local and gitignored — created
# at runtime by audit_append/run_log_path, and by tests/lib.sh's `mkdir -p logs`.
# Nothing under logs/ is committed, so no .gitkeep is needed there.
```

- [ ] **Step 4: Create `.gitignore`**

```gitignore
# git worktrees (isolated workspaces)
.worktrees/

# secrets / sessions / local state — never commit
.env
*.env
*.key
*.pem
id_*
*_rsa
*_ed25519
secrets*
*.tfstate
*.tfstate.*
.terraform/
*.bw-session
BW_SESSION*

# logs/ is runtime-local operational state — never committed (audit.jsonl too).
# Requirement is "never lose a record" (append-only, no gaps), NOT tamper-
# evidence; local git gives no tamper-evidence anyway (design §6/§10).
logs/
!tests/stubs/.gitkeep
```

- [ ] **Step 5: Create `README.md`**

```markdown
# homelab-ops

CLI toolkit + declarative inventory for safely operating a homelab fleet via Claude Code.

## Requirements
`bash >= 5`, `jq`, `python3` + PyYAML, `curl`, `ssh`/`ssh-agent`, Bitwarden `bw` CLI.

## Install (once) — global skill + repo pointer
```sh
bin/install-skill
```
Installs `~/.claude/skills/homelab-ops/SKILL.md` (usable from any project) and writes
`~/.config/homelab-ops/config` with `HOMELAB_REPO=<this repo>`. Idempotent; re-run to
update the skill. The git repo stays the single source of truth.

## Session start (required before any change)
```sh
export BW_SESSION="$(bw unlock --raw)"   # you type the master password, never Claude
export HOMELAB_SESSION_ID="sess-$(date -u +%Y%m%dT%H%M%SZ)"
```
`BW_SESSION` unset ⇒ every mutating command refuses to start ("locked vault" default).

## Usage
- Read inventory: `bin/inv list | get <id> | resolve <id> | children <id> | group <name>`
- Any change: `bin/guard <action> <target-id> [--approve] [-- <extra>...]`
- Forensics: `bin/forensics {session|target|timeline} <id>`

## Tests
`bash tests/run.sh`
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/test_skeleton.sh`
Expected: `PASS test_skeleton`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add .gitignore README.md tests/test_skeleton.sh tests/stubs/.gitkeep
git commit -m "feat: repo skeleton, gitignore, readme"
```

---

### Task 2: Pure-bash test harness + stubs

**Files:**
- Create: `tests/lib.sh`, `tests/run.sh`
- Create: `tests/stubs/bw`, `tests/stubs/curl`, `tests/stubs/ssh`, `tests/stubs/ssh-agent`, `tests/stubs/ssh-add`
- Test: `tests/test_harness.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_harness.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

assert_eq "ab" "ab" "eq works"
assert_contains "hello world" "lo wo" "contains works"
assert_status 0 true "status 0 works"
assert_status 3 'bash -c "exit 3"' "status 3 works"

# stubs must be deterministic and on PATH via run.sh; check shape directly:
PATH="$PWD/tests/stubs:$PATH"
out="$(bw get password "x" --session s)"
[[ "$out" == "stub-secret-x" ]] || { echo "FAIL: bw stub"; exit 1; }

echo "PASS test_harness"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_harness.sh`
Expected: FAIL — `tests/lib.sh` does not exist, `source` errors out, non-zero exit.

- [ ] **Step 3: Create `tests/lib.sh`**

```bash
# shellcheck shell=bash
# Assertion helpers. Source this in test_*.sh files.
_FAILS=0

assert_eq() { # expected actual msg
  if [[ "$1" == "$2" ]]; then echo "  ok: $3";
  else echo "  FAIL: $3 — expected [$1] got [$2]"; _FAILS=$((_FAILS+1)); fi
}
assert_contains() { # haystack needle msg
  if [[ "$1" == *"$2"* ]]; then echo "  ok: $3";
  else echo "  FAIL: $3 — [$1] does not contain [$2]"; _FAILS=$((_FAILS+1)); fi
}
assert_status() { # expected_code cmd... msg(last arg)
  local exp="$1"; local msg="${@: -1}"; local n=$#; set -- "${@:2:n-2}"
  local rc=0; ( eval "$*" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$exp" ]]; then echo "  ok: $msg";
  else echo "  FAIL: $msg — expected exit $exp got $rc"; _FAILS=$((_FAILS+1)); fi
}
finish() { [[ $_FAILS -eq 0 ]] || { echo "  ($_FAILS failed)"; exit 1; }; }
```

- [ ] **Step 4: Create `tests/run.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/tests/stubs:$PATH"
export HOMELAB_SESSION_ID="test-sess"
rc=0
for t in tests/test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
[[ $rc -eq 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $rc
```

- [ ] **Step 5: Create stubs**

`tests/stubs/bw`:
```bash
#!/usr/bin/env bash
# bw get password|notes|item <name> --session <s>
verb="${2:-}"; name="${3:-}"
case "$verb" in
  password) echo "stub-secret-$name" ;;
  notes)    printf -- "-----BEGIN OPENSSH PRIVATE KEY-----\nSTUBKEY-%s\n-----END OPENSSH PRIVATE KEY-----\n" "$name" ;;
  item)     printf '{"fields":[{"name":"api-token","value":"stub-token-%s"}]}\n' "$name" ;;
  *) echo "bw-stub: unknown verb $verb" >&2; exit 1 ;;
esac
```

`tests/stubs/curl`:
```bash
#!/usr/bin/env bash
# Echo a deterministic Proxmox-shaped JSON so bin/pve is testable offline.
echo '{"data":{"status":"running","vmid":100,"name":"stub-vm"}}'
```

`tests/stubs/ssh`:
```bash
#!/usr/bin/env bash
# Record args so tests can assert StrictHostKeyChecking; echo a marker.
echo "ssh-stub args: $*" >&2
echo "stub-ssh-output"
```

`tests/stubs/ssh-agent`:
```bash
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99999; export SSH_AGENT_PID;'
```

`tests/stubs/ssh-add`:
```bash
#!/usr/bin/env bash
cat >/dev/null   # consume key from stdin, never write it anywhere
echo "Identity added (stub)" >&2
```

Make them executable:
```bash
chmod +x tests/stubs/bw tests/stubs/curl tests/stubs/ssh tests/stubs/ssh-agent tests/stubs/ssh-add tests/run.sh
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/test_harness.sh`
Expected: `PASS test_harness`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add tests/lib.sh tests/run.sh tests/stubs tests/test_harness.sh
git commit -m "feat: pure-bash test harness and command stubs"
```

---

### Task 3: Core sourced library `bin/_lib.sh`

**Files:**
- Create: `bin/_lib.sh`
- Test: `tests/test_lib.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_lib.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

cat > /tmp/_libprobe.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
case "$1" in
  opid)  new_op_id ;;
  mask)  echo "BW_SESSION=topsecret token=abcDEF123" | mask ;;
  audit) audit_append --arg a "$2" '{ts:"T",session:env.HOMELAB_SESSION_ID,action:$a}' ;;
  runlog) run_log_path "op-1" ;;
esac
EOF
cp /tmp/_libprobe.sh bin/_libprobe.sh
trap 'rm -f bin/_libprobe.sh' EXIT

op="$(HOMELAB_SESSION_ID=test bash bin/_libprobe.sh opid)"
assert_contains "$op" "op-" "new_op_id has op- prefix"

masked="$(bash bin/_libprobe.sh mask)"
assert_contains "$masked" "MASKED" "secrets are masked"
[[ "$masked" != *topsecret* ]] && echo "  ok: plaintext secret removed" \
  || { echo "  FAIL: secret leaked"; exit 1; }

: > logs/audit.jsonl
HOMELAB_SESSION_ID=test-sess bash bin/_libprobe.sh audit "start"
last="$(tail -1 logs/audit.jsonl)"
assert_eq "test-sess" "$(jq -r .session <<<"$last")" "audit record has session"
assert_eq "start" "$(jq -r .action <<<"$last")" "audit record has action"

rp="$(HOMELAB_SESSION_ID=test-sess bash bin/_libprobe.sh runlog)"
assert_contains "$rp" "logs/runs/test-sess/op-1.log" "run_log_path under session dir"
[[ -d logs/runs/test-sess ]] && echo "  ok: run dir created" \
  || { echo "  FAIL: run dir missing"; exit 1; }

finish; echo "PASS test_lib"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_lib.sh`
Expected: FAIL — `bin/_lib.sh` missing, `source` fails, non-zero exit.

- [ ] **Step 3: Create `bin/_lib.sh`**

```bash
# shellcheck shell=bash
# Sourced by every bin/ command. Not a standalone executable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT_LOG="$REPO_ROOT/logs/audit.jsonl"
RUNS_DIR="$REPO_ROOT/logs/runs"

: "${HOMELAB_SESSION_ID:=}"
if [[ -z "$HOMELAB_SESSION_ID" ]]; then
  HOMELAB_SESSION_ID="sess-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
export HOMELAB_SESSION_ID

die() { echo "homelab-ops: $*" >&2; exit "${HL_EXIT:-1}"; }

new_op_id() { echo "op-$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM"; }

# Mask anything secret-shaped on a text stream (used before writing run logs).
mask() {
  sed -E \
    -e 's/(BW_SESSION=)[^[:space:]]+/\1***MASKED***/g' \
    -e 's/(token=)[A-Za-z0-9._-]+/\1***MASKED***/g' \
    -e 's/(PVEAPIToken[^=]*=)[^[:space:]]+/\1***MASKED***/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/***MASKED-PRIVATE-KEY***/g' \
    -e 's/[A-Za-z0-9+\/]{40,}={0,2}/***MASKED-BLOB***/g'
}

# Append exactly one JSON object to the append-only audit log.
# Usage: audit_append <jq-args...> '<jq-filter producing the object>'
audit_append() {
  mkdir -p "$(dirname "$AUDIT_LOG")"
  jq -c -n "$@" >> "$AUDIT_LOG"
}

run_log_path() { # <op-id> -> path (creates session run dir)
  mkdir -p "$RUNS_DIR/$HOMELAB_SESSION_ID"
  echo "$RUNS_DIR/$HOMELAB_SESSION_ID/$1.log"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_lib.sh`
Expected: each `ok:` line then `PASS test_lib`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/_lib.sh tests/test_lib.sh
git commit -m "feat: core sourced library (ids, masking, audit append, run log)"
```

---

### Task 4: Inventory model + `bin/inv`

**Files:**
- Create: `inventory/fleet.yaml`, `inventory/groups.yaml`, `bin/inv`
- Test: `tests/test_inv.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_inv.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/inv 2>/dev/null || true

ids="$(bin/inv list)"
assert_contains "$ids" "pve-01" "list includes pve-01"
assert_contains "$ids" "lab-vm-900" "list includes lab dummy"

entry="$(bin/inv get pve-01)"
assert_eq "proxmox-host" "$(jq -r .kind <<<"$entry")" "get returns kind"
assert_eq "prod" "$(jq -r .env <<<"$entry")" "get returns env"

resolved="$(bin/inv resolve pve-01)"
assert_contains "$(jq -rc '.groups' <<<"$resolved")" "pve-hosts" "resolve attaches groups"

kids="$(bin/inv children pve-01)"
assert_contains "$kids" "vm-100" "children lists guests"

mem="$(bin/inv group pve-hosts)"
assert_contains "$mem" "pve-01" "group lists members"

assert_status 1 'bin/inv get nope' "unknown id exits 1"

finish; echo "PASS test_inv"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_inv.sh`
Expected: FAIL — `bin/inv` missing / not executable, non-zero exit.

- [ ] **Step 3: Create `inventory/fleet.yaml`**

```yaml
# Credentials are REFERENCES ONLY (bw://...). No secret value lives in any file.
- id: pve-01
  kind: proxmox-host
  address: 10.0.0.11
  env: prod
  access:
    api: { token_ref: "bw://Proxmox pve-01/api-token" }
    ssh: { user: root, key_ref: "bw://ssh-pve-01" }
  children: [vm-100, lxc-201]
  tags: [critical]

- id: vm-100
  kind: vm
  address: 10.0.0.100
  env: prod
  access:
    ssh: { user: ops, key_ref: "bw://ssh-vm-100" }
  tags: []

- id: lxc-201
  kind: lxc
  address: 10.0.0.201
  env: prod
  access:
    ssh: { user: root, key_ref: "bw://ssh-lxc-201" }
  tags: []

- id: nas-01
  kind: appliance
  address: 10.0.0.50
  env: prod
  access:
    ssh: { user: admin, key_ref: "bw://ssh-nas-01" }
  tags: [critical]

# lab dummy target for safe/caution/destructive integration smoke (§8)
- id: lab-vm-900
  kind: vm
  address: 10.0.9.900
  env: lab
  access:
    ssh: { user: ops, key_ref: "bw://ssh-lab-vm-900" }
  tags: []
```

- [ ] **Step 4: Create `inventory/groups.yaml`**

```yaml
pve-hosts:     [pve-01]
observability: [vm-100]
storage:       [nas-01]
lab:           [lab-vm-900]
```

- [ ] **Step 5: Create `bin/inv`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
FLEET="$REPO_ROOT/inventory/fleet.yaml"
GROUPS="$REPO_ROOT/inventory/groups.yaml"

y2j() { python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(sys.stdin) or [], sys.stdout)' < "$1"; }

cmd="${1:-}"; arg="${2:-}"
case "$cmd" in
  list)
    y2j "$FLEET" | jq -r '.[].id' ;;
  get)
    [[ -n "$arg" ]] || die "usage: inv get <id>"
    y2j "$FLEET" | jq -e --arg id "$arg" '.[] | select(.id==$id)' >/dev/null 2>&1 \
      || die "no such inventory id: $arg"
    y2j "$FLEET" | jq --arg id "$arg" '.[] | select(.id==$id)' ;;
  resolve)
    [[ -n "$arg" ]] || die "usage: inv resolve <id>"
    e="$(y2j "$FLEET")"; g="$(y2j "$GROUPS")"
    echo "$e" | jq -e --arg id "$arg" '.[]|select(.id==$id)' >/dev/null 2>&1 \
      || die "no such inventory id: $arg"
    jq -n --argjson f "$e" --argjson g "$g" --arg id "$arg" '
      ($f[] | select(.id==$id)) as $entry
      | $entry + { groups: ($g | to_entries | map(select(.value|index($id)) | .key)) }' ;;
  children)
    [[ -n "$arg" ]] || die "usage: inv children <id>"
    "$0" get "$arg" | jq -r '.children[]? // empty' ;;
  group)
    [[ -n "$arg" ]] || die "usage: inv group <name>"
    y2j "$GROUPS" | jq -r --arg n "$arg" '.[$n][]? // empty' ;;
  *)
    die "usage: inv {list|get <id>|resolve <id>|children <id>|group <name>}" ;;
esac
```

```bash
chmod +x bin/inv
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/test_inv.sh`
Expected: all `ok:` lines then `PASS test_inv`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add inventory/fleet.yaml inventory/groups.yaml bin/inv tests/test_inv.sh
git commit -m "feat: declarative inventory model and inv query tool"
```

---

### Task 5: `bin/bw-resolve` — credential resolution

**Files:**
- Create: `bin/bw-resolve`
- Test: `tests/test_bw_resolve.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_bw_resolve.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/bw-resolve 2>/dev/null || true

# Locked vault: no BW_SESSION → exit 3, nothing printed.
assert_status 3 'env -u BW_SESSION bin/bw-resolve "bw://Item/password"' "locked vault exits 3"

export BW_SESSION="stub-session"

pw="$(bin/bw-resolve 'bw://MyItem/password')"
assert_eq "stub-secret-MyItem" "$pw" "password ref resolves"

fld="$(bin/bw-resolve 'bw://Proxmox pve-01/api-token')"
assert_eq "stub-token-Proxmox pve-01" "$fld" "custom field ref resolves"

key="$(bin/bw-resolve --ssh 'bw://ssh-pve-01')"
assert_contains "$key" "BEGIN OPENSSH PRIVATE KEY" "ssh mode emits private key to stdout"

assert_status 1 'bin/bw-resolve "not-a-bw-ref"' "non bw:// ref rejected"

# resolved secret must never be written to disk by bw-resolve itself
grep -rq "stub-secret-MyItem" logs/ 2>/dev/null && { echo "FAIL: secret on disk"; exit 1; } || true
echo "  ok: no secret written to logs/"

finish; echo "PASS test_bw_resolve"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_bw_resolve.sh`
Expected: FAIL — `bin/bw-resolve` missing, non-zero exit.

- [ ] **Step 3: Create `bin/bw-resolve`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"

ssh_mode=0
if [[ "${1:-}" == "--ssh" ]]; then ssh_mode=1; shift; fi
ref="${1:-}"
[[ -n "$ref" ]] || die "usage: bw-resolve [--ssh] bw://<item>[/<field>]"
[[ -n "${BW_SESSION:-}" ]] || { HL_EXIT=3 die "locked vault: BW_SESSION not set"; }
[[ "$ref" == bw://* ]] || die "ref must start with bw:// : $ref"

path="${ref#bw://}"
item="${path%%/*}"
field=""
[[ "$path" == */* ]] && field="${path#*/}"

if [[ $ssh_mode -eq 1 ]]; then
  # SSH private key: stdout only. Caller pipes into ssh-add; never touches disk.
  bw get notes "$item" --session "$BW_SESSION" 2>/dev/null \
    || die "bw: cannot resolve ssh key for '$item'"
  exit 0
fi

if [[ -z "$field" || "$field" == "password" ]]; then
  bw get password "$item" --session "$BW_SESSION" 2>/dev/null \
    || die "bw: cannot resolve $ref"
else
  bw get item "$item" --session "$BW_SESSION" 2>/dev/null \
    | jq -er --arg f "$field" '.fields[]? | select(.name==$f) | .value' \
    || die "bw: cannot resolve field '$field' of '$item'"
fi
```

```bash
chmod +x bin/bw-resolve
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_bw_resolve.sh`
Expected: all `ok:` lines then `PASS test_bw_resolve`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/bw-resolve tests/test_bw_resolve.sh
git commit -m "feat: bw-resolve credential resolution (memory only, locked-vault default)"
```

---

### Task 6: `guard grade` — grading engine (pure)

**Files:**
- Create: `bin/guard` (grading subcommand only in this task)
- Test: `tests/test_guard_grade.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_guard_grade.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard 2>/dev/null || true

assert_eq "safe"        "$(bin/guard grade status vm-100)"       "status on non-critical = safe"
assert_eq "caution"     "$(bin/guard grade stop vm-100)"         "stop on plain vm = caution"
assert_eq "destructive" "$(bin/guard grade destroy vm-100)"      "destroy = destructive"
# critical tag escalates one level
assert_eq "caution"     "$(bin/guard grade status pve-01)"       "status on critical = caution (bumped)"
assert_eq "destructive" "$(bin/guard grade stop nas-01)"         "stop on critical = destructive (bumped)"
# deny-by-default: unknown action
assert_eq "destructive" "$(bin/guard grade frobnicate vm-100)"   "unknown action = destructive"
# provision is always destructive
assert_eq "destructive" "$(bin/guard grade provision lab-vm-900)" "provision = destructive"

finish; echo "PASS test_guard_grade"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_guard_grade.sh`
Expected: FAIL — `bin/guard` missing, non-zero exit.

- [ ] **Step 3: Create `bin/guard` (grading core)**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
HERE="$(dirname "$0")"

declare -A GRADE=(
  [status]=safe [list]=safe [metrics]=safe [get]=safe [inventory]=safe
  [start]=caution [stop]=caution [restart]=caution [snapshot]=caution [pkg-install]=caution
  [destroy]=destructive [delete]=destructive [storage-remove]=destructive
  [kill]=destructive [net-change]=destructive [provision]=destructive
)

_bump() { case "$1" in safe) echo caution;; caution) echo destructive;; *) echo destructive;; esac; }

# grade <action> <target-id> -> prints safe|caution|destructive
guard_grade() {
  local action="$1" target="$2" g tj
  g="${GRADE[$action]:-destructive}"          # deny-by-default
  tj="$("$HERE/inv" get "$target")" || die "cannot resolve target: $target"
  if jq -e '(.tags? // []) | index("critical")' >/dev/null <<<"$tj"; then
    g="$(_bump "$g")"                          # critical escalates one level
  fi
  echo "$g"
}

case "${1:-}" in
  grade)
    [[ $# -ge 3 ]] || die "usage: guard grade <action> <target-id>"
    guard_grade "$2" "$3" ;;
  *)
    die "usage: guard grade <action> <target-id>   (execution path added in Task 7)" ;;
esac
```

```bash
chmod +x bin/guard
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_guard_grade.sh`
Expected: all `ok:` lines then `PASS test_guard_grade`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/guard tests/test_guard_grade.sh
git commit -m "feat: guard grading engine (deny-by-default, critical escalation)"
```

---

### Task 7: `bin/_backend` + guard execution flow

**Files:**
- Create: `bin/_backend`
- Modify: `bin/guard` (replace the `*)` branch with full execution flow)
- Test: `tests/test_guard_exec.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_guard_exec.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

# Fake backend: records the call, succeeds for "ok" target, fails for "boom".
cat > /tmp/fake-backend <<'EOF'
#!/usr/bin/env bash
echo "BACKEND action=$1 target=$2 extra=${4:-}" 
[[ "$2" == boom* ]] && exit 20 || exit 0
EOF
chmod +x /tmp/fake-backend
export HOMELAB_BACKEND=/tmp/fake-backend
export BW_SESSION="stub-session"
: > logs/audit.jsonl

# safe: runs immediately, audited, exit 0
out="$(bin/guard status vm-100)"
assert_contains "$out" "BACKEND action=status" "safe action executes"
assert_eq "safe" "$(tail -1 logs/audit.jsonl | jq -r .grade)" "safe audited"
assert_eq "0" "$(tail -1 logs/audit.jsonl | jq -r .exit)" "safe exit 0 audited"

# non-safe requires BW_SESSION
assert_status 3 'env -u BW_SESSION bin/guard stop lab-vm-900' "stop without BW_SESSION exits 3"

# caution on lab env: 1-line summary, proceeds without --approve
out="$(bin/guard stop lab-vm-900)"
assert_contains "$out" "SUMMARY" "caution prints summary"
assert_contains "$out" "BACKEND action=stop" "caution lab proceeds"

# caution on prod env: requires --approve → exit 10 first
assert_status 10 'bin/guard stop vm-100' "caution+prod without approve exits 10"
out="$(bin/guard stop vm-100 --approve)"
assert_contains "$out" "BACKEND action=stop" "caution+prod with approve runs"

# destructive without --approve: dry-run + impact, exit 10, NO backend call
set +e; out="$(bin/guard destroy lab-vm-900 2>&1)"; rc=$?; set -e
assert_eq "10" "$rc" "destructive without approve exits 10"
assert_contains "$out" "DRY-RUN" "destructive prints dry-run"
[[ "$out" != *"BACKEND action=destroy"* ]] && echo "  ok: backend NOT called on dry-run" \
  || { echo "  FAIL: backend ran during dry-run"; exit 1; }

# destructive with --approve: runs, audit has approver + dryrun_hash + inv_snapshot
out="$(bin/guard destroy lab-vm-900 --approve)"
assert_contains "$out" "BACKEND action=destroy" "destructive+approve runs"
rec="$(tail -1 logs/audit.jsonl)"
assert_eq "destructive" "$(jq -r .grade <<<"$rec")" "destructive audited"
[[ "$(jq -r .approver <<<"$rec")" != "null" ]] && echo "  ok: approver recorded" \
  || { echo "  FAIL: approver missing"; exit 1; }
[[ "$(jq -r .dryrun_hash <<<"$rec")" != "null" ]] && echo "  ok: dryrun_hash recorded" \
  || { echo "  FAIL: dryrun_hash missing"; exit 1; }
[[ "$(jq -r .inv_snapshot.id <<<"$rec")" == "lab-vm-900" ]] && echo "  ok: inv snapshot recorded" \
  || { echo "  FAIL: inv snapshot missing"; exit 1; }

# backend failure → exit 20 AND audit/run-log still written (no log gap)
n_before="$(wc -l < logs/audit.jsonl)"
set +e; bin/guard destroy boom-target --approve >/dev/null 2>&1; rc=$?; set -e
assert_eq "20" "$rc" "backend failure propagates exit 20"
n_after="$(wc -l < logs/audit.jsonl)"
[[ "$n_after" -gt "$n_before" ]] && echo "  ok: failure still audited (no gap)" \
  || { echo "  FAIL: failure left audit gap"; exit 1; }
assert_eq "20" "$(tail -1 logs/audit.jsonl | jq -r .exit)" "failure exit code audited"

# run log exists and is masked
rl="$(ls -t logs/runs/$HOMELAB_SESSION_ID/*.log | head -1)"
[[ -s "$rl" ]] && echo "  ok: run log written" || { echo "  FAIL: no run log"; exit 1; }

finish; echo "PASS test_guard_exec"
```

> Note: `boom-target` is not in inventory, so add it implicitly handled — `guard_grade` calls `inv get` which would `die`. To keep this test honest, add `boom-target` to the fake path: instead of relying on inventory, the test uses a target that *is* in inventory. **Replace `boom-target` with `lab-vm-900` and make the fake backend fail when extra arg `--boom` is present.** Adjust: the failure case becomes `bin/guard destroy lab-vm-900 --approve -- --boom` and the fake backend checks `"$*" == *--boom*`. Update `/tmp/fake-backend` accordingly:

```bash
cat > /tmp/fake-backend <<'EOF'
#!/usr/bin/env bash
echo "BACKEND action=$1 target=$2 extra=$*"
[[ "$*" == *--boom* ]] && exit 20 || exit 0
EOF
chmod +x /tmp/fake-backend
```

And the failure case in the test becomes:

```bash
n_before="$(wc -l < logs/audit.jsonl)"
set +e; bin/guard destroy lab-vm-900 --approve -- --boom >/dev/null 2>&1; rc=$?; set -e
assert_eq "20" "$rc" "backend failure propagates exit 20"
```

(Use this corrected `/tmp/fake-backend` and failure invocation when writing the test file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_guard_exec.sh`
Expected: FAIL — guard has no execution path yet (`usage:` message), non-zero exit.

- [ ] **Step 3: Create `bin/_backend`**

```bash
#!/usr/bin/env bash
# Real action dispatcher. Overridden by $HOMELAB_BACKEND in tests.
# Usage: _backend <action> <target-id> -- <extra args...>
source "$(dirname "$0")/_lib.sh"
HERE="$(dirname "$0")"
action="$1"; target="$2"; shift 2
[[ "${1:-}" == "--" ]] && shift || true

inv="$("$HERE/inv" get "$target")"
kind="$(jq -r .kind <<<"$inv")"
addr="$(jq -r .address <<<"$inv")"

case "$action:$kind" in
  status:*|metrics:*|get:*)
    "$HERE/inv" resolve "$target" ;;
  start:*|stop:*|restart:*|destroy:*|snapshot:*)
    if [[ "$kind" == proxmox-host || "$kind" == vm || "$kind" == lxc ]]; then
      host="$("$HERE/inv" list | while read -r h; do
                "$HERE/inv" children "$h" | grep -qx "$target" && echo "$h"; done | head -1)"
      [[ -n "$host" ]] || host="$target"
      "$HERE/pve" "$host" action "$action" "$target" "$@"
    else
      "$HERE/ssh-run" "$target" -- "$action" "$@"
    fi ;;
  pkg-install:*)
    "$HERE/ssh-run" "$target" -- sudo apt-get install -y "$@" ;;
  provision:*)
    "$REPO_ROOT/provisioning/phase1" apply "$target" "$@" ;;
  *)
    die "no backend mapping for action '$action' on kind '$kind'" ;;
esac
```

```bash
chmod +x bin/_backend
```

- [ ] **Step 4: Replace the `*)` branch in `bin/guard` with the full execution flow**

In `bin/guard`, replace exactly this block:

```bash
  *)
    die "usage: guard grade <action> <target-id>   (execution path added in Task 7)" ;;
esac
```

with:

```bash
  "")
    die "usage: guard <action> <target-id> [--approve] [-- <extra>...]" ;;
  *)
    action="$1"; target="$2"; shift 2
    approve=0; extra=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --approve) approve=1; shift ;;
        --) shift; extra=("$@"); break ;;
        *) extra+=("$1"); shift ;;
      esac
    done

    [[ -n "$action" && -n "$target" ]] || die "usage: guard <action> <target-id> [--approve] [-- <extra>...]"
    inv_json="$("$HERE/inv" get "$target")" || die "cannot resolve target: $target"
    env_t="$(jq -r '.env // "unknown"' <<<"$inv_json")"
    tags_t="$(jq -rc '.tags // []' <<<"$inv_json")"
    grade="$(guard_grade "$action" "$target")"
    op="$(new_op_id)"
    rl="$(run_log_path "$op")"
    backend="${HOMELAB_BACKEND:-$HERE/_backend}"
    start_ms=$(date +%s%3N)
    approver="null"; approved_at="null"; dryrun_hash="null"

    _audit() { # <exit-code>
      local end_ms; end_ms=$(date +%s%3N)
      audit_append \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg session "$HOMELAB_SESSION_ID" --arg op "$op" \
        --arg actor "claude" --arg action "$action" --arg target "$target" \
        --arg grade "$grade" --arg env "$env_t" \
        --argjson tags "$tags_t" --argjson inv "$inv_json" \
        --arg dh "$dryrun_hash" --arg apr "$approver" --arg apat "$approved_at" \
        --argjson ex "$1" --argjson dur "$((end_ms-start_ms))" '
        {ts:$ts,session:$session,op:$op,actor:$actor,action:$action,
         target:$target,grade:$grade,env:$env,tags:$tags,inv_snapshot:$inv,
         dryrun_hash:$dh,approver:$apr,approved_at:$apat,exit:$ex,duration_ms:$dur}'
    }
    # Never let an abnormal exit leave an audit gap.
    trap 'rc=$?; [[ -z "${_DONE:-}" ]] && _audit "$rc" >/dev/null 2>&1; exit $rc' EXIT

    # BW_SESSION gate for everything except safe.
    if [[ "$grade" != "safe" && -z "${BW_SESSION:-}" ]]; then
      _DONE=1; _audit 3 >/dev/null; HL_EXIT=3 die "locked vault: BW_SESSION not set"
    fi

    needs_approval=0
    [[ "$grade" == "destructive" ]] && needs_approval=1
    [[ "$grade" == "caution" && "$env_t" == "prod" ]] && needs_approval=1

    if [[ "$grade" == "caution" ]]; then
      echo "SUMMARY: [$grade] $action $target (env=$env_t tags=$tags_t)"
    fi

    if [[ "$needs_approval" -eq 1 ]]; then
      dry="$("$backend" "$action" "$target" --dry-run -- "${extra[@]:-}" 2>&1 || true)"
      dryrun_hash="$(printf '%s' "$dry" | sha256sum | awk '{print $1}')"
      if [[ "$approve" -ne 1 ]]; then
        echo "DRY-RUN [$grade] $action $target (env=$env_t tags=$tags_t)"
        echo "$dry" | mask
        echo "Impact above. Re-run with --approve to execute."
        _DONE=1; _audit 10 >/dev/null
        trap - EXIT; exit 10
      fi
      approver="claude+user"; approved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi

    # Pre-op state snapshot → run log (best-effort, never blocks).
    {
      echo "=== pre-op snapshot $(date -u +%FT%TZ) op=$op ==="
      "$HERE/inv" resolve "$target" 2>/dev/null || true
      "$backend" status "$target" -- 2>/dev/null || true
      echo "=== action output ==="
    } | mask > "$rl"

    set +e
    "$backend" "$action" "$target" -- "${extra[@]:-}" 2>&1 | mask | tee -a "$rl"
    rc="${PIPESTATUS[0]}"
    set -e

    _DONE=1
    _audit "$rc" >/dev/null
    trap - EXIT
    exit "$rc" ;;
esac
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_guard_exec.sh`
Expected: all `ok:` lines then `PASS test_guard_exec`, exit 0.

- [ ] **Step 6: Run the full suite (regression check)**

Run: `bash tests/run.sh`
Expected: `ALL TESTS PASSED`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add bin/_backend bin/guard tests/test_guard_exec.sh
git commit -m "feat: guard execution flow (gates, dry-run, approval, audit, snapshot)"
```

---

### Task 8: `bin/pve` — Proxmox REST client

**Files:**
- Create: `bin/pve`
- Test: `tests/test_pve.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_pve.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/pve 2>/dev/null || true
export BW_SESSION="stub-session"

# curl is stubbed → deterministic Proxmox-shaped JSON
out="$(bin/pve pve-01 api GET /nodes)"
assert_contains "$out" '"status"' "pve api returns json"

st="$(bin/pve pve-01 status)"
assert_contains "$st" "running" "pve status convenience works"

# locked vault: pve must refuse (it resolves a token via bw-resolve)
assert_status 3 'env -u BW_SESSION bin/pve pve-01 status' "pve without BW_SESSION exits 3"

# TLS verification must be ON: pve must NOT pass -k/--insecure to curl.
cat > /tmp/curl-spy <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/curl-args
echo '{"data":{"status":"running"}}'
EOF
chmod +x /tmp/curl-spy
: > /tmp/curl-args
PATH="/tmp-not-real" # placeholder to show intent; real check below
# Use a dir whose only curl is the spy:
mkdir -p /tmp/spybin && cp /tmp/curl-spy /tmp/spybin/curl
PATH="/tmp/spybin:$PWD/tests/stubs:$PATH" bin/pve pve-01 status >/dev/null
grep -q -- '-k' /tmp/curl-args && { echo "FAIL: curl -k used (TLS off)"; exit 1; }
grep -q -- '--insecure' /tmp/curl-args && { echo "FAIL: --insecure used"; exit 1; }
echo "  ok: TLS verification left on"

finish; echo "PASS test_pve"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_pve.sh`
Expected: FAIL — `bin/pve` missing, non-zero exit.

- [ ] **Step 3: Create `bin/pve`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
HERE="$(dirname "$0")"

host_id="${1:-}"; sub="${2:-}"
[[ -n "$host_id" && -n "$sub" ]] || die "usage: pve <host-id> {api <METHOD> <path> [data] | status | vm-config <vmid> | action <verb> <target> [extra]}"

inv="$("$HERE/inv" get "$host_id")" || die "no such host: $host_id"
addr="$(jq -r '.address' <<<"$inv")"
token_ref="$(jq -r '.access.api.token_ref // empty' <<<"$inv")"
[[ -n "$token_ref" ]] || die "host $host_id has no access.api.token_ref"

token="$("$HERE/bw-resolve" "$token_ref")" || exit $?   # propagates exit 3 if vault locked
base="https://${addr}:8006/api2/json"

call() { # METHOD path [data]
  local m="$1" p="$2" d="${3:-}"
  # TLS verification ON (no -k / --insecure). Token via header only.
  if [[ -n "$d" ]]; then
    curl -sS -X "$m" -H "Authorization: PVEAPIToken=${token}" \
      --data "$d" "${base}${p}"
  else
    curl -sS -X "$m" -H "Authorization: PVEAPIToken=${token}" "${base}${p}"
  fi
}

case "$sub" in
  api)     call "${3:?METHOD}" "${4:?path}" "${5:-}" ;;
  status)  call GET "/nodes/${host_id}/status" ;;
  vm-config)
    vmid="${3:?vmid}"; call GET "/nodes/${host_id}/qemu/${vmid}/config" ;;
  action)
    verb="${3:?verb}"; tgt="${4:?target}"
    case "$verb" in
      start)   call POST "/nodes/${host_id}/qemu/${tgt#vm-}/status/start" ;;
      stop)    call POST "/nodes/${host_id}/qemu/${tgt#vm-}/status/stop" ;;
      restart) call POST "/nodes/${host_id}/qemu/${tgt#vm-}/status/reboot" ;;
      snapshot) call POST "/nodes/${host_id}/qemu/${tgt#vm-}/snapshot" "snapname=ho-$(date +%s)" ;;
      destroy) call DELETE "/nodes/${host_id}/qemu/${tgt#vm-}" ;;
      *) die "pve: unknown action verb $verb" ;;
    esac ;;
  *) die "pve: unknown subcommand $sub" ;;
esac
```

```bash
chmod +x bin/pve
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_pve.sh`
Expected: all `ok:` lines then `PASS test_pve`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/pve tests/test_pve.sh
git commit -m "feat: pve Proxmox REST client (token via bw-resolve, TLS on)"
```

---

### Task 9: `bin/ssh-run` — SSH exec wrapper

**Files:**
- Create: `bin/ssh-run`
- Test: `tests/test_ssh_run.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_ssh_run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/ssh-run 2>/dev/null || true
export BW_SESSION="stub-session"

# locked vault refusal (key resolved via bw-resolve --ssh)
assert_status 3 'env -u BW_SESSION bin/ssh-run nas-01 -- uname -a' "ssh-run without BW_SESSION exits 3"

out="$(bin/ssh-run nas-01 -- uname -a 2>err.txt; cat err.txt)"
assert_contains "$out" "stub-ssh-output" "ssh-run runs remote command"
# StrictHostKeyChecking must be enforced
assert_contains "$out" "StrictHostKeyChecking=yes" "StrictHostKeyChecking=yes enforced"
assert_contains "$out" "BatchMode=yes" "BatchMode=yes enforced"
rm -f err.txt

# Key must never be written to disk: scan repo + /tmp for the stub key marker.
grep -rq "STUBKEY-ssh-nas-01" . --include='*' 2>/dev/null && { echo "FAIL: ssh key on disk"; exit 1; } || true
echo "  ok: ssh key never written to disk"

finish; echo "PASS test_ssh_run"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_ssh_run.sh`
Expected: FAIL — `bin/ssh-run` missing, non-zero exit.

- [ ] **Step 3: Create `bin/ssh-run`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
HERE="$(dirname "$0")"

target="${1:-}"
[[ -n "$target" ]] || die "usage: ssh-run <target-id> -- <command...>"
shift
[[ "${1:-}" == "--" ]] && shift || die "usage: ssh-run <target-id> -- <command...>"
[[ $# -ge 1 ]] || die "no remote command given"

inv="$("$HERE/inv" get "$target")" || die "no such target: $target"
addr="$(jq -r '.address' <<<"$inv")"
user="$(jq -r '.access.ssh.user // "root"' <<<"$inv")"
key_ref="$(jq -r '.access.ssh.key_ref // empty' <<<"$inv")"
[[ -n "$key_ref" ]] || die "target $target has no access.ssh.key_ref"

# Ephemeral ssh-agent; key piped from bw-resolve into ssh-add stdin. No disk.
eval "$(ssh-agent -s)" >/dev/null
cleanup() { ssh-agent -k >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$HERE/bw-resolve" --ssh "$key_ref" | ssh-add - >/dev/null 2>&1 \
  || { rc=$?; [[ $rc -eq 3 ]] && { HL_EXIT=3 die "locked vault: BW_SESSION not set"; }; die "ssh-add failed"; }

ssh -o StrictHostKeyChecking=yes -o BatchMode=yes \
    -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
    "${user}@${addr}" -- "$@"
```

```bash
chmod +x bin/ssh-run
```

> Note on the test: the stub `ssh` echoes its args to stderr including the `-o StrictHostKeyChecking=yes` options, so the assertions inspect that. `bw-resolve --ssh` with the locked vault exits 3; the pipeline's `ssh-add` then sees no input and we map that back to exit 3 via the explicit check. Because `set -o pipefail` is on (from `_lib.sh`), capture the bw-resolve exit explicitly if needed; the provided `|| { rc=$?; ... }` handles the failure path.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_ssh_run.sh`
Expected: all `ok:` lines then `PASS test_ssh_run`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/ssh-run tests/test_ssh_run.sh
git commit -m "feat: ssh-run wrapper (StrictHostKeyChecking, key via ssh-agent, no disk)"
```

---

### Task 10: Provisioning Phase 1

**Files:**
- Create: `provisioning/phase1`
- Test: `tests/test_provision.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_provision.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x provisioning/phase1 2>/dev/null || true
export BW_SESSION="stub-session"

# dry-run prints what WILL be created/destroyed and calls no mutating API
out="$(provisioning/phase1 dry-run lab-vm-900 --from-template 9000 --new-vmid 950)"
assert_contains "$out" "WOULD CREATE" "dry-run announces creation"
assert_contains "$out" "950" "dry-run shows new vmid"
[[ "$out" != *"CREATED"* ]] && echo "  ok: dry-run did not create" \
  || { echo "  FAIL: dry-run created"; exit 1; }

# apply path performs the clone via pve (curl stubbed → deterministic)
out="$(provisioning/phase1 apply lab-vm-900 --from-template 9000 --new-vmid 950)"
assert_contains "$out" "CREATED" "apply performs clone"

# guard routes provision (destructive) through dry-run/approval
export HOMELAB_BACKEND=""   # use real _backend → provisioning/phase1
set +e; out="$(bin/guard provision lab-vm-900 -- --from-template 9000 --new-vmid 950 2>&1)"; rc=$?; set -e
assert_eq "10" "$rc" "guard provision needs approval (destructive)"
assert_contains "$out" "DRY-RUN" "guard provision shows dry-run"

finish; echo "PASS test_provision"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_provision.sh`
Expected: FAIL — `provisioning/phase1` missing, non-zero exit.

- [ ] **Step 3: Create `provisioning/phase1`**

```bash
#!/usr/bin/env bash
# Phase-1 provisioning backend. Stable interface; backend swappable in Phase 2.
# Usage: phase1 {dry-run|apply} <target-id> --from-template <vmid> --new-vmid <vmid> [--name <n>]
source "$(dirname "$0")/../bin/_lib.sh"
BIN="$REPO_ROOT/bin"

mode="${1:-}"; target="${2:-}"; shift 2 || true
# guard's dry-run probe passes "--dry-run" as the mode-equivalent extra; normalize:
[[ "$mode" == "--dry-run" ]] && { mode="dry-run"; target="${1:-}"; shift || true; }

tmpl=""; newid=""; name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) mode="dry-run"; shift ;;
    --from-template) tmpl="$2"; shift 2 ;;
    --new-vmid) newid="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    --) shift ;;
    *) shift ;;
  esac
done
[[ -n "$target" ]] || die "usage: phase1 {dry-run|apply} <target> --from-template <vmid> --new-vmid <vmid>"
[[ -n "$tmpl" && -n "$newid" ]] || die "phase1 requires --from-template and --new-vmid"

inv="$("$BIN/inv" get "$target")" || die "no such target: $target"
host="$(jq -r '.id' <<<"$inv")"
name="${name:-ho-${newid}}"

if [[ "$mode" == "dry-run" ]]; then
  echo "WOULD CREATE: clone template ${tmpl} -> vmid ${newid} (name=${name}) on host ${host}"
  echo "WOULD DESTROY: nothing"
  exit 0
fi
if [[ "$mode" == "apply" ]]; then
  "$BIN/pve" "$host" api POST "/nodes/${host}/qemu/${tmpl}/clone" "newid=${newid}&name=${name}" \
    >/dev/null || die "clone failed"
  echo "CREATED: vmid ${newid} (name=${name}) cloned from ${tmpl} on ${host}"
  exit 0
fi
die "unknown mode: $mode"
```

```bash
chmod +x provisioning/phase1
```

> Note: `bin/_backend`'s `provision:*` branch calls `provisioning/phase1 apply "$target" "$@"`; guard's needs-approval probe calls the backend with `--dry-run`, which `_backend` forwards, and `phase1` normalizes `--dry-run` into dry-run mode. This keeps `guard provision` on the stable interface (§9).

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_provision.sh`
Expected: all `ok:` lines then `PASS test_provision`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add provisioning/phase1 tests/test_provision.sh
git commit -m "feat: provisioning Phase 1 (Proxmox clone behind stable guard interface)"
```

---

### Task 11: `bin/forensics` — timeline reconstruction

**Files:**
- Create: `bin/forensics`
- Test: `tests/test_forensics.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_forensics.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/forensics 2>/dev/null || true

# Seed a deterministic audit log with two sessions + one failure.
: > logs/audit.jsonl
jq -cn '{ts:"2026-05-16T10:00:00Z",session:"S1",op:"op-a",actor:"claude",action:"status",target:"vm-100",grade:"safe",env:"prod",tags:[],inv_snapshot:{id:"vm-100"},dryrun_hash:null,approver:null,approved_at:null,exit:0,duration_ms:12}' >> logs/audit.jsonl
jq -cn '{ts:"2026-05-16T10:01:00Z",session:"S1",op:"op-b",actor:"claude",action:"destroy",target:"vm-100",grade:"destructive",env:"prod",tags:[],inv_snapshot:{id:"vm-100"},dryrun_hash:"abc",approver:"claude+user",approved_at:"2026-05-16T10:00:59Z",exit:20,duration_ms:300}' >> logs/audit.jsonl
jq -cn '{ts:"2026-05-16T11:00:00Z",session:"S2",op:"op-c",actor:"claude",action:"start",target:"nas-01",grade:"caution",env:"prod",tags:["critical"],inv_snapshot:{id:"nas-01"},dryrun_hash:null,approver:null,approved_at:null,exit:0,duration_ms:40}' >> logs/audit.jsonl

s1="$(bin/forensics session S1)"
assert_contains "$s1" "op-a" "session filter includes op-a"
assert_contains "$s1" "op-b" "session filter includes op-b"
[[ "$s1" != *"op-c"* ]] && echo "  ok: session filter excludes other sessions" \
  || { echo "  FAIL: leaked op-c"; exit 1; }

tgt="$(bin/forensics target nas-01)"
assert_contains "$tgt" "op-c" "target filter works"

tl="$(bin/forensics timeline S1)"
# timeline is ordered and surfaces the failure (exit 20)
assert_contains "$tl" "op-a" "timeline has first op"
assert_contains "$tl" "20" "timeline surfaces the failed op exit code"
first_line="$(head -1 <<<"$tl")"
assert_contains "$first_line" "10:00:00" "timeline ordered by time (earliest first)"

finish; echo "PASS test_forensics"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_forensics.sh`
Expected: FAIL — `bin/forensics` missing, non-zero exit.

- [ ] **Step 3: Create `bin/forensics`**

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"

cmd="${1:-}"; key="${2:-}"
[[ -f "$AUDIT_LOG" ]] || die "no audit log at $AUDIT_LOG"

case "$cmd" in
  session)
    [[ -n "$key" ]] || die "usage: forensics session <session-id>"
    jq -c --arg s "$key" 'select(.session==$s)' "$AUDIT_LOG" ;;
  target)
    [[ -n "$key" ]] || die "usage: forensics target <target-id>"
    jq -c --arg t "$key" 'select(.target==$t)' "$AUDIT_LOG" ;;
  timeline)
    [[ -n "$key" ]] || die "usage: forensics timeline <session-id>"
    jq -r --arg s "$key" '
      select(.session==$s)
      | [.ts,.op,.action,.target,.grade,("exit="+(.exit|tostring))] | @tsv' \
      "$AUDIT_LOG" | sort ;;
  runlog)
    [[ -n "$key" ]] || die "usage: forensics runlog <session-id>/<op>.log"
    f="$RUNS_DIR/$key"
    [[ -f "$f" ]] || die "no run log: $f"
    cat "$f" ;;
  *)
    die "usage: forensics {session <id>|target <id>|timeline <id>|runlog <sess/op.log>}" ;;
esac
```

```bash
chmod +x bin/forensics
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_forensics.sh`
Expected: all `ok:` lines then `PASS test_forensics`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add bin/forensics tests/test_forensics.sh
git commit -m "feat: forensics timeline reconstruction over audit log"
```

---

### Task 12: Global skill install + CLAUDE.md

This task makes `homelab-ops` a **global** skill (usable from any project, matching the
harbor-ops/gitea-ops pattern). Canonical content is git-tracked at `skill/SKILL.md`;
`bin/install-skill` lays it down at `~/.claude/skills/homelab-ops/SKILL.md` and writes a
repo-pointer config at `~/.config/homelab-ops/config`. Both target dirs are env-overridable
so the test never touches the real `$HOME`.

**Files:**
- Create: `skill/SKILL.md` (canonical, git-tracked)
- Create: `bin/install-skill`
- Create: `CLAUDE.md`
- Test: `tests/test_skill.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/test_skill.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/install-skill 2>/dev/null || true

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOMELAB_SKILL_DIR="$tmp/skills/homelab-ops"
export HOMELAB_CONFIG_DIR="$tmp/config/homelab-ops"

bin/install-skill >/dev/null

s="$HOMELAB_SKILL_DIR/SKILL.md"
[[ -f "$s" ]] || { echo "FAIL: $s not installed"; exit 1; }
head -1 "$s" | grep -qx -- '---' || { echo "FAIL: no frontmatter open"; exit 1; }
grep -q '^name: homelab-ops$' "$s" || { echo "FAIL: name field"; exit 1; }
grep -q '^description: ' "$s" || { echo "FAIL: description field"; exit 1; }
assert_contains "$(cat "$s")" "guard" "skill: mutate only via guard"
assert_contains "$(cat "$s")" "BW_SESSION" "skill: BW_SESSION requirement"
assert_contains "$(cat "$s")" "HOMELAB_REPO" "skill: resolves repo via HOMELAB_REPO pointer"
assert_contains "$(cat "$s")" "homelab-ops/config" "skill: references ~/.config/homelab-ops/config"

cfg="$HOMELAB_CONFIG_DIR/config"
[[ -f "$cfg" ]] || { echo "FAIL: config not written"; exit 1; }
repo_abs="$(pwd)"
assert_eq "HOMELAB_REPO=$repo_abs" "$(grep -m1 '^HOMELAB_REPO=' "$cfg")" "config points at this repo"

# idempotent: a user-edited config must be preserved on re-run
echo "HOMELAB_REPO=/custom/path" > "$cfg"
bin/install-skill >/dev/null
assert_eq "HOMELAB_REPO=/custom/path" "$(grep -m1 '^HOMELAB_REPO=' "$cfg")" "re-run preserves user config"
[[ -f "$s" ]] && echo "  ok: re-run keeps skill installed" \
  || { echo "FAIL: skill lost on re-run"; exit 1; }

# canonical source is git-tracked in the repo
[[ -f skill/SKILL.md ]] && echo "  ok: canonical skill/SKILL.md present" \
  || { echo "FAIL: canonical skill/SKILL.md missing"; exit 1; }

c="CLAUDE.md"
[[ -f "$c" ]] || { echo "FAIL: CLAUDE.md missing"; exit 1; }
for rule in "guard" "BW_SESSION" "deny-by-default" "audit"; do
  assert_contains "$(cat "$c")" "$rule" "CLAUDE.md states rule: $rule"
done

finish; echo "PASS test_skill"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_skill.sh`
Expected: FAIL — `bin/install-skill`/`skill/SKILL.md`/`CLAUDE.md` missing, non-zero exit.

- [ ] **Step 3: Create `skill/SKILL.md` (canonical, git-tracked)**

```markdown
---
name: homelab-ops
description: Use from ANY project when the user wants to inspect or operate their homelab fleet (Proxmox hosts, VMs, LXC, appliances like Victoria Metrics/NAS) — list/status/metrics, start/stop/snapshot, destroy/storage/network changes, or Phase-1 provisioning. Resolves the toolkit repo via ~/.config/homelab-ops/config; reads inventory with the repo's `inv`; performs ANY state change ONLY through the repo's `guard`, which grades the action, gates on the Bitwarden session, dry-runs + requires approval for destructive ops, and forensically logs everything.
---

# homelab-ops

Global fleet-operations skill. The toolkit lives in a git repo; this skill is a thin pointer.

## Resolve the repo first (every invocation)
```sh
HOMELAB_REPO="$( . "$HOME/.config/homelab-ops/config" 2>/dev/null; echo "${HOMELAB_REPO:-$HOME/projects/homelab-ops}" )"
```
Then call `"$HOMELAB_REPO/bin/inv"`, `"$HOMELAB_REPO/bin/guard"`, `"$HOMELAB_REPO/bin/forensics"`.
Paths are absolute, so this works from any project's cwd. The repo is the single source of
truth for tooling (inventory, guard); `logs/audit.jsonl` is runtime-local and gitignored
(append-only, not part of the tracked source — see design §6/§10).

## When to use
- "What's on the fleet / status / metrics?" → `$HOMELAB_REPO/bin/inv list|get|resolve`, `guard status <id>`
- "Start/stop/restart/snapshot X" → `guard <verb> <id>` (prod ⇒ needs `--approve`)
- "Destroy/delete/storage/network change" → `guard <verb> <id>` → review DRY-RUN → re-run `--approve`
- "Provision a VM" → `guard provision <id> -- --from-template <vmid> --new-vmid <vmid>`
- "What happened / why did X fail?" → `forensics {session|target|timeline} <id>`

## Hard rules
1. NEVER call `bin/pve` or `bin/ssh-run` to make a change. Mutations go through `guard` only.
2. Mutations require `BW_SESSION`. If unset, ask the user to run `export BW_SESSION="$(bw unlock --raw)"`. Never handle the master password.
3. Unknown action ⇒ guard treats it as destructive (deny-by-default). Do not work around this.
4. For destructive/prod-caution ops: show the user the guard DRY-RUN/impact, get explicit confirmation, THEN re-run with `--approve`.
5. Never disable logging or edit/truncate `logs/audit.jsonl`. It is append-only and runtime-local (gitignored, not committed); back it up out-of-band if you need tamper-evidence.

## Setup the user does once per session
```sh
export BW_SESSION="$(bw unlock --raw)"
export HOMELAB_SESSION_ID="sess-$(date -u +%Y%m%dT%H%M%SZ)"
```
```

- [ ] **Step 4: Create `bin/install-skill`**

```bash
#!/usr/bin/env bash
# One-shot idempotent installer for the global homelab-ops skill + repo pointer.
# Target dirs are env-overridable (HOMELAB_SKILL_DIR / HOMELAB_CONFIG_DIR) for tests.
source "$(dirname "$0")/_lib.sh"

skill_dir="${HOMELAB_SKILL_DIR:-$HOME/.claude/skills/homelab-ops}"
cfg_dir="${HOMELAB_CONFIG_DIR:-$HOME/.config/homelab-ops}"
src="$REPO_ROOT/skill/SKILL.md"
[[ -f "$src" ]] || die "canonical skill missing: $src"

mkdir -p "$skill_dir" "$cfg_dir"
cp "$src" "$skill_dir/SKILL.md"          # always refresh (this is how you update the skill)

cfg="$cfg_dir/config"
if [[ -f "$cfg" ]]; then
  echo "config kept (user-managed): $cfg"
else
  printf 'HOMELAB_REPO=%s\n' "$REPO_ROOT" > "$cfg"
  chmod 0600 "$cfg"
  echo "config written: $cfg"
fi
echo "skill installed: $skill_dir/SKILL.md"
echo "repo: $( . "$cfg"; echo "${HOMELAB_REPO:-?}" )"
```

```bash
chmod +x bin/install-skill
```

- [ ] **Step 5: Create `CLAUDE.md`**

```markdown
# Claude operating rules for homelab-ops

These rules are non-negotiable. They exist so destructive mistakes are hard and
every action is forensically reconstructable.

1. **No guard bypass.** Every state change runs as `bin/guard <action> <target> [--approve]`.
   `bin/pve` and `bin/ssh-run` are read/transport layers — never invoke them to mutate state.
2. **BW_SESSION required for any change.** No `BW_SESSION` ⇒ guard refuses (exit 3,
   "locked vault"). Ask the user to `bw unlock`; never see or store the master password.
3. **deny-by-default.** Any action not in guard's grade table is treated as destructive.
   Do not add ad-hoc actions to dodge this — extend the grade table deliberately if needed.
4. **Destructive needs eyes.** destructive (and prod caution) print a DRY-RUN + impact and
   exit 10. Show that to the user, get explicit approval, then re-run with `--approve`.
5. **No log gaps.** `logs/audit.jsonl` is append-only; full per-op output
   lives in `logs/runs/<session>/<op>.log` (secrets masked). Never edit, truncate, or skip them.
   Operational state is runtime-local and gitignored — back it up out-of-band if you need
   tamper-evidence (local git is not tamper-evidence; see design §6/§10).
6. **Credentials are references.** Inventory holds `bw://` refs only. Resolution is in-memory
   via `bin/bw-resolve`; never write a secret to disk or echo it unmasked.
7. **Provisioning is Phase 1.** Use `guard provision` only. No Terraform/Ansible until Phase 2;
   the interface stays the same when the backend is swapped.
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/test_skill.sh`
Expected: all `ok:` lines then `PASS test_skill`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add skill/SKILL.md bin/install-skill CLAUDE.md tests/test_skill.sh
git commit -m "feat: global homelab-ops skill installer + CLAUDE.md operating rules"
```

---

### Task 13: Forensic-sufficiency integration test + full suite green

**Files:**
- Create: `tests/test_forensic_sufficiency.sh`
- Test: itself + `tests/run.sh` (whole suite)

This task implements spec §8 bullet 3: inject a deliberate failure and prove `audit.jsonl` + run log + pre/post snapshot are sufficient to trace root cause.

- [ ] **Step 1: Write the failing test**

Create `tests/test_forensic_sufficiency.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_SESSION="stub-session"
export HOMELAB_SESSION_ID="forensic-sess"
: > logs/audit.jsonl
rm -rf "logs/runs/forensic-sess"

# Deliberate failure: backend fails on a destructive, approved op.
cat > /tmp/fail-backend <<'EOF'
#!/usr/bin/env bash
echo "BACKEND action=$1 target=$2 args=$*"
[[ "$1" == status ]] && { echo '{"state":"pre-op-running"}'; exit 0; }
echo "simulated catastrophic failure" >&2
exit 20
EOF
chmod +x /tmp/fail-backend
export HOMELAB_BACKEND=/tmp/fail-backend

set +e
bin/guard destroy lab-vm-900 --approve >/dev/null 2>&1
rc=$?
set -e
assert_eq "20" "$rc" "deliberate failure surfaces as exit 20"

# 1) audit.jsonl has the failed op with enough context to start root-cause
rec="$(bin/forensics session forensic-sess | tail -1)"
assert_eq "destroy"      "$(jq -r .action <<<"$rec")"       "audit: action recorded"
assert_eq "destructive"  "$(jq -r .grade  <<<"$rec")"       "audit: grade recorded"
assert_eq "20"           "$(jq -r .exit   <<<"$rec")"       "audit: failure exit recorded"
assert_eq "lab-vm-900"   "$(jq -r .inv_snapshot.id <<<"$rec")" "audit: inventory snapshot recorded"
[[ "$(jq -r .dryrun_hash <<<"$rec")" != "null" ]] && echo "  ok: audit dryrun_hash present" \
  || { echo "  FAIL: dryrun_hash missing"; exit 1; }
[[ "$(jq -r .approver <<<"$rec")" != "null" ]] && echo "  ok: audit approver present" \
  || { echo "  FAIL: approver missing"; exit 1; }

# 2) run log exists, captured pre-op snapshot AND the failure stderr
op="$(jq -r .op <<<"$rec")"
rl="logs/runs/forensic-sess/${op}.log"
[[ -s "$rl" ]] || { echo "FAIL: run log missing"; exit 1; }
assert_contains "$(cat "$rl")" "pre-op snapshot" "run log has pre-op snapshot section"
assert_contains "$(cat "$rl")" "pre-op-running" "run log captured pre-op state"
assert_contains "$(cat "$rl")" "catastrophic failure" "run log captured failure cause"

# 3) timeline reconstructs the sequence ending in the failure
tl="$(bin/forensics timeline forensic-sess)"
assert_contains "$tl" "destroy" "timeline includes the failed action"
assert_contains "$tl" "exit=20" "timeline shows the failure"

finish; echo "PASS test_forensic_sufficiency"
```

- [ ] **Step 2: Run test to verify it fails (or reveals a real gap)**

Run: `bash tests/test_forensic_sufficiency.sh`
Expected: It must PASS if Tasks 7/11 are correct. If anything FAILs, that is a genuine forensic gap — fix the offending script (most likely `bin/guard` pre-op snapshot / `_audit` on failure) until it passes. Do not weaken the test.

- [ ] **Step 3: Run the full suite**

Run: `bash tests/run.sh`
Expected: every `tests/test_*.sh` prints `PASS ...`, final line `ALL TESTS PASSED`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add tests/test_forensic_sufficiency.sh
git commit -m "test: forensic-sufficiency integration (deliberate failure traceability)"
```

- [ ] **Step 5: (none)**

`logs/audit.jsonl` is runtime-local and gitignored — it is NOT committed. The
invariant is "append-only, no gaps" (every op recorded), not git-tracked
tamper-evidence (design §6/§10). Do not `git add logs/`.

---

## Self-Review

**1. Spec coverage**

| Spec section | Covered by |
|---|---|
| §4.1 repo structure | Task 1 (dirs/.gitignore/README), all `bin/` tasks, Task 12 (CLAUDE.md/skill) |
| §4.2 inventory model (`bw://` refs only, kind/env/tags, children) | Task 4 |
| §5.1 credential flow (bw, locked-vault default, no disk) | Task 5, gate in Task 7, ssh-agent in Task 9 |
| §5.2 access layer (pve token+TLS, ssh StrictHostKeyChecking) | Task 8, Task 9 |
| §5.3 graded guard (table, deny-by-default, critical bump, prod approval, dry-run) | Task 6 (grade), Task 7 (exec) |
| §6 forensics (session/op IDs, audit fields, run logs, pre-op snapshot, failure logged, append-only, query) | Task 3, Task 7, Task 11, Task 13 |
| §7 Claude interface (one **global** skill + `~/.config/homelab-ops/config` repo pointer, mutate via guard) | Task 12 |
| §8 tests (grade/deny/approval unit, lab smoke, forensic verification) | Tasks 6,7 (unit), 7/10 (lab smoke via lab-vm-900), Task 13 (forensic) |
| §9 provisioning Phase 1 (no IaC, stable `guard provision`, dry-run = plan) | Task 10 |
| §10 non-goals (no daemon/MCP, no cluster/HA, no IaC in P1) | Honored — no daemon/MCP anywhere; pve has no cluster ops; provisioning is API-only |

No gaps identified.

**2. Placeholder scan** — every code step contains full runnable content; no "TBD"/"add error handling"/"similar to Task N". The only prose "Note:" blocks clarify behavior and do not defer code.

**3. Type/name consistency** — verified across tasks: `_lib.sh` exports `REPO_ROOT/AUDIT_LOG/RUNS_DIR/HOMELAB_SESSION_ID` and functions `die/mask/new_op_id/audit_append/run_log_path`, all consumed with those exact names. Guard uses `guard_grade`/`GRADE`/`_bump` consistently between Task 6 and Task 7. Backend contract `_backend <action> <target> -- <extra>` and the `--dry-run` probe are used identically in Task 7, 8, 10. Audit field set is identical in `_lib.sh` test (Task 3), guard `_audit` (Task 7), seeded data (Task 11), and assertions (Task 13). Exit codes 3/10/20 used consistently. `HOMELAB_BACKEND` override used uniformly in tests.

One inconsistency found and fixed inline: Task 7's first-draft test used an out-of-inventory `boom-target` which `guard_grade`→`inv get` would reject; corrected in Step 1's note to use `lab-vm-900` with a `--boom` extra arg and an updated fake backend.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-16-homelab-ops.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
