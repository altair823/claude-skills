# homelab-ops SSH-transport 자격 정렬 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** homelab-ops 의 SSH-transport 옵을 키(notes 저장)·패스워드 양쪽 인증에서 동작시키고, bitwarden-ops `bw-put` 으로 multi-line 키 파일을 vault 에 등록할 수 있게 한다.

**Architecture:** bitwarden-ops `bw-put` 에 user-run `--from-file` 추가(키→item notes). homelab-ops 는 키 경로는 인벤토리 규약(`bw://ssh-<id>/notes`)만 바꿔 로직 무변경; 패스워드 경로는 인벤토리 `auth/pass_ref` 스키마 + `ssh-run` 의 `sshpass -e` 분기 + `guard --plan`/credential-gate 분기 + `mask` 규칙 추가.

**Tech Stack:** bash, jq, bitwarden `bw`(stub), `sshpass`(조건부), 기존 stub-구동 오프라인 테스트 스위트.

**Spec:** `docs/superpowers/specs/2026-05-17-bw-put-from-file-ssh-notes-design.md`

---

## Prerequisites (실행 전 필독)

1. **Base branch:** 본 plan 은 homelab-ops `bin/guard`·`bin/_lib.sh`·`tests/`(특히 `HOMELAB_INVENTORY_DIR` fixture 분리)에 의존한다. PR #24(`feat/homelab-ops-ca-and-inventory-decoupling`)가 **main 에 머지된 후** main 기준으로 새 브랜치를 만들거나, 머지 전이면 `feat/homelab-ops-ca-and-inventory-decoupling` 에서 분기한다. main(머지 전) 단독 기준 금지 — `HOMELAB_INVENTORY_DIR` 미존재로 Part B 테스트 작성 불가.
2. 브랜치: `git checkout -b feat/ssh-transport-credentials <base>`.
3. 작업 디렉터리는 repo 루트 `/home/altair823/claude-skills`. 두 스킬 경로:
   - `BW=homelab-ops 가 아닌` → bitwarden-ops 실경로: `homelab-ops` 와 형제. 본 plan 의 모든 경로는 repo 상대 경로로 적되, 스킬 심볼릭은 `~/.claude/skills/{bitwarden-ops,homelab-ops}` → 실체 `~/claude-skills/{bitwarden-ops,homelab-ops}`. **테스트·커밋은 실체 repo 경로에서.**
4. 환경 specific 데이터(실 inventory/키/비번)는 절대 커밋하지 않는다. 본 plan 산출물은 전부 범용 코드·테스트·문서.

---

## File Structure

**bitwarden-ops** (`bitwarden-ops/`)
- `bin/bw-put` — `--from-file PATH` 인자 + `_read_secret` 파일 분기 추가.
- `tests/test_put.sh` — `--from-file` 케이스 확장.
- `SKILL.md` — `--from-file` 사용법 + SSH 키 등록 예시.

**homelab-ops** (`homelab-ops/`)
- `bin/guard` — `--plan` ssh arm + credential gate 를 `access.ssh.auth` 로 분기.
- `bin/ssh-run` — 자격 검사 순서 재배치 + `auth==password` 시 `sshpass -e` 경로.
- `bin/_lib.sh` — `mask()` 에 `HL_SSH_PASS`/`SSHPASS` 규칙.
- `tests/stubs/sshpass` — 신규 stub.
- `tests/fixtures/fleet.yaml` — 패스워드 인증 fixture 호스트 추가.
- `tests/test_guard_plan.sh`, `tests/test_guard_exec.sh`, `tests/test_ssh_run.sh`, `tests/test_mask_parity.sh` — 케이스 확장.
- `SKILL.md` — deps 에 `sshpass`(조건부), hard rule #2 에 `HL_SSH_PASS`, `auth`/`pass_ref` 규약, 키 `bw://ssh-<id>/notes` 규약.
- `inventory/fleet.example.yaml` — 키(`/notes`)·패스워드 예시.

각 task 는 독립 커밋. 키 경로 회귀 0 가 합격 기준.

---

## Task 1: bitwarden-ops `bw-put --from-file`

**Files:**
- Modify: `bitwarden-ops/bin/bw-put` (arg loop, `_read_secret`)
- Test: `bitwarden-ops/tests/test_put.sh`

- [ ] **Step 1: Write the failing test** — `bitwarden-ops/tests/test_put.sh` 의 `# 6) Locked vault.` 직전에 삽입:

```bash
# 7) --from-file: multi-line content stored byte-verbatim into notes.
KEYF="$(mktemp)"; trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced" "$SECRET" "$KEYF"' EXIT
printf -- '-----BEGIN KEY-----\nline2\nline3\n-----END KEY-----\n' > "$KEYF"
BW_SESSION=x bash bin/bw-put 'bw://ssh-h/notes' --type note --from-file "$KEYF" >/dev/null
got="$(BW_SESSION=x bash bin/bw-get 'bw://ssh-h/notes')"
want="$(cat "$KEYF")"
assert_eq "$want" "$got" "--from-file stores multi-line notes verbatim"

# 8) --from-file missing path fails.
assert_status 1 "BW_SESSION=x bash bin/bw-put 'bw://ssh-h2/notes' --type note --from-file /no/such/file" "--from-file missing path → die"

# 9) --from-file empty file rejected.
EMPTYF="$(mktemp)"; : > "$EMPTYF"
assert_status 1 "BW_SESSION=x bash bin/bw-put 'bw://ssh-h3/notes' --type note --from-file '$EMPTYF'" "--from-file empty → die"
rm -f "$EMPTYF"

# 10) --from-file overwrite needs --replace.
printf 'v1' > "$KEYF"; BW_SESSION=x bash bin/bw-put 'bw://ssh-h4' --from-file "$KEYF" >/dev/null
printf 'v2' > "$KEYF"
assert_status 1 "BW_SESSION=x bash bin/bw-put 'bw://ssh-h4' --from-file '$KEYF'" "--from-file overwrite needs --replace"
BW_SESSION=x bash bin/bw-put 'bw://ssh-h4' --from-file "$KEYF" --replace >/dev/null
assert_eq "v2" "$(BW_SESSION=x bash bin/bw-get 'bw://ssh-h4')" "--from-file --replace overwrites"
```

(기존 `trap 'rm -f ... "$SECRET"' EXIT` 줄은 위 새 trap 줄로 대체되므로, 기존 줄을 삭제하고 새 trap 줄을 쓴다.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/claude-skills/bitwarden-ops && bash tests/test_put.sh`
Expected: FAIL — `--from-file` 가 미지원 인자라 `bw-put` 가 usage die → "stores multi-line notes verbatim" 등에서 FAIL.

- [ ] **Step 3: Implement minimal code** — `bitwarden-ops/bin/bw-put`:

(a) arg loop(현재 7–14행)에 `--from-file` 분기 추가:

```bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)      type="${2:?--type 값 필요}"; shift 2 ;;
    --replace)   replace=1; shift ;;
    --from-file) from_file="${2:?--from-file 값 필요}"; shift 2 ;;
    bw://*)      ref="$1"; shift ;;
    *) die "usage: bw-put bw://<item>[/<field>] [--type password|field|note] [--from-file PATH] [--replace]" ;;
  esac
done
```

루프 위 변수 초기화부에 `from_file=""` 를 추가(기존 `type=""`/`replace=0` 와 같은 위치).

(b) `_read_secret()`(현재 49–58행)를 다음으로 교체:

```bash
_read_secret() {
  if [[ -n "$from_file" ]]; then
    [[ -r "$from_file" ]] || die "--from-file 경로를 읽을 수 없음: $from_file"
    # 파일 바이트 그대로(말미 개행 보존): $() 의 trailing-newline strip 회피.
    local s; s="$(cat -- "$from_file"; printf x)"; printf '%s' "${s%x}"
    return
  fi
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
```

기존 빈값 거부 라인(`[[ -n "$secret" ]] || die "빈 값..."`)이 그대로 빈 파일을 처리한다(추가 코드 불필요).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/claude-skills/bitwarden-ops && bash tests/test_put.sh`
Expected: PASS (`PASS`/`ok:` 라인, FAIL 없음). 이어서 전체: `bash tests/run.sh` → `ALL TESTS PASSED` (기존 케이스 회귀 없음 — tty/`BITWARDEN_OPS_TEST_SECRET_FILE` 경로 불변).

- [ ] **Step 5: Commit**

```bash
cd ~/claude-skills
git add bitwarden-ops/bin/bw-put bitwarden-ops/tests/test_put.sh
git commit -m "feat(bitwarden-ops): bw-put --from-file (user-run, multi-line verbatim)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: bitwarden-ops SKILL.md — `--from-file` 문서

**Files:**
- Modify: `bitwarden-ops/SKILL.md`

- [ ] **Step 1: Edit** — `## When to use` 의 "Register a credential I haven't stored" 항목 바로 아래에 추가:

```markdown
- "Register a multi-line secret (SSH private key) from a file" → tell the user
  to run `"$BW/bin/bw-put" bw://ssh-<id>/notes --type note --from-file ~/.ssh/<key>`
  themselves. `--from-file PATH` reads the secret bytes from PATH instead of the
  tty (still user-run; Claude never runs bw-put). Multi-line preserved verbatim.
```

- [ ] **Step 2: Edit** — `## Reference grammar` 의 `--ssh` 줄 아래에 한 줄 추가:

```markdown
- SSH private keys live in an item's notes (`bw://ssh-<id>/notes`); register
  with `bw-put ... --type note --from-file <keyfile>`, consume via `bw-get
  --ssh` or a `/notes` ref.
```

- [ ] **Step 3: Verify docs test still green**

Run: `cd ~/claude-skills/bitwarden-ops && bash tests/test_docs.sh`
Expected: PASS (test_docs.sh 가 SKILL.md 구조를 검증하면 깨지지 않음 확인; 깨지면 형식만 맞춰 수정).

- [ ] **Step 4: Commit**

```bash
cd ~/claude-skills
git add bitwarden-ops/SKILL.md
git commit -m "docs(bitwarden-ops): document bw-put --from-file + SSH key in notes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: homelab-ops Part A — 키 `bw://ssh-<id>/notes` 규약 (로직 0)

Part A 는 homelab-ops 동작을 바꾸지 않는다(`guard --plan` 은 이미 key_ref 를 verbatim 출력). 따라서 이 task 는 **특성화(lock) 테스트 + 문서/예시**이며 RED 단계가 없다(의도된 무-로직-변경 정렬). 회귀 방지가 목적.

**Files:**
- Modify: `homelab-ops/tests/fixtures/fleet.yaml` (키 호스트에 `/notes` ref)
- Modify: `homelab-ops/tests/test_guard_plan.sh`
- Modify: `homelab-ops/inventory/fleet.example.yaml`
- Modify: `homelab-ops/SKILL.md`

- [ ] **Step 1: fixture 에 /notes 키 호스트 추가** — `homelab-ops/tests/fixtures/fleet.yaml` 끝에 추가:

```yaml
- id: keyhost-notes
  kind: appliance
  address: 10.0.0.60
  env: lab
  access:
    ssh: { user: ops, key_ref: "bw://ssh-keyhost-notes/notes" }
  tags: []
```

- [ ] **Step 2: lock 테스트 추가** — `homelab-ops/tests/test_guard_plan.sh` 의 `finish;` 줄 직전에 삽입:

```bash
# 키 ref 가 /notes 를 포함해도 guard --plan 은 변형 없이 verbatim 통과.
out="$(bin/guard --plan stop keyhost-notes)"
assert_eq "HL_SSH_KEY=bw://ssh-keyhost-notes/notes" "$out" "ssh key_ref with /notes passes verbatim"
```

- [ ] **Step 3: Run test to verify it passes immediately (lock, not RED)**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_guard_plan.sh`
Expected: PASS (Part A 는 무-로직-변경이므로 즉시 통과 — 이 테스트는 회귀 잠금용이며 RED 없음이 의도).

- [ ] **Step 4: SKILL.md 규약 명시** — `homelab-ops/SKILL.md` 의 `## Credentials — delegated to bitwarden-ops` 절 끝(Notes 블록 뒤)에 추가:

```markdown
> - SSH **키** 호스트의 `access.ssh.key_ref` 는 `bw://ssh-<id>/notes` 규약
>   (키는 vault item notes 에 저장; `bw-put ... --type note --from-file` 로
>   등록). `guard --plan` 은 key_ref 를 verbatim 으로 `HL_SSH_KEY` 에 싣는다.
```

- [ ] **Step 5: example 갱신** — `homelab-ops/inventory/fleet.example.yaml` 의 모든 `key_ref: "bw://ssh-<x>"` 를 `key_ref: "bw://ssh-<x>/notes"` 로 변경(예: `bw://ssh-pve-01` → `bw://ssh-pve-01/notes`, `bw://ssh-vm-100` → `bw://ssh-vm-100/notes`, `bw://ssh-lxc-201` → `bw://ssh-lxc-201/notes`, `bw://ssh-nas-01` → `bw://ssh-nas-01/notes`).

- [ ] **Step 6: 전체 스위트 회귀 확인**

Run: `cd ~/claude-skills/homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 7: Commit**

```bash
cd ~/claude-skills
git add homelab-ops/tests/fixtures/fleet.yaml homelab-ops/tests/test_guard_plan.sh homelab-ops/SKILL.md homelab-ops/inventory/fleet.example.yaml
git commit -m "feat(homelab-ops): SSH key_ref /notes convention (Part A, no logic change)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Part B — 패스워드 fixture + `guard --plan` auth 분기

**Files:**
- Modify: `homelab-ops/tests/fixtures/fleet.yaml`
- Modify: `homelab-ops/bin/guard` (`--plan` ssh arm)
- Modify: `homelab-ops/tests/test_guard_plan.sh`

- [ ] **Step 1: 패스워드 fixture 호스트 추가** — `homelab-ops/tests/fixtures/fleet.yaml` 끝에 추가:

```yaml
- id: pwhost
  kind: appliance
  address: 10.0.0.61
  env: lab
  access:
    ssh: { user: ops, auth: password, pass_ref: "bw://ssh-pwhost-pass" }
  tags: []
```

- [ ] **Step 2: Write failing test** — `homelab-ops/tests/test_guard_plan.sh` 의 `finish;` 직전에 삽입:

```bash
# auth=password 호스트는 HL_SSH_PASS 자격을 산출한다.
out="$(bin/guard --plan stop pwhost)"
assert_eq "HL_SSH_PASS=bw://ssh-pwhost-pass" "$out" "password host → HL_SSH_PASS ref"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_guard_plan.sh`
Expected: FAIL — 현재 ssh arm 은 `HL_SSH_KEY=` 만 내보내므로 `pwhost` 는 `key_ref` 없음 → 빈 출력, `HL_SSH_PASS=...` 와 불일치.

- [ ] **Step 4: Implement** — `homelab-ops/bin/guard` 의 `--plan` 내 `ssh)` arm 을 교체:

기존:
```bash
      ssh)
        pref="$(jq -r '.access.ssh.key_ref // empty' <<<"$pinv")"
        [[ -n "$pref" ]] && printf 'HL_SSH_KEY=%s\n' "$pref" ;;
```
신규:
```bash
      ssh)
        pauth="$(jq -r '.access.ssh.auth // "key"' <<<"$pinv")"
        if [[ "$pauth" == "password" ]]; then
          pref="$(jq -r '.access.ssh.pass_ref // empty' <<<"$pinv")"
          [[ -n "$pref" ]] && printf 'HL_SSH_PASS=%s\n' "$pref"
        else
          pref="$(jq -r '.access.ssh.key_ref // empty' <<<"$pinv")"
          [[ -n "$pref" ]] && printf 'HL_SSH_KEY=%s\n' "$pref"
        fi ;;
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_guard_plan.sh`
Expected: PASS (신규 단언 + 기존 `appliance stop → HL_SSH_KEY` 등 회귀 없음).

- [ ] **Step 6: Commit**

```bash
cd ~/claude-skills
git add homelab-ops/tests/fixtures/fleet.yaml homelab-ops/bin/guard homelab-ops/tests/test_guard_plan.sh
git commit -m "feat(homelab-ops): guard --plan emits HL_SSH_PASS for auth=password

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Part B — credential gate auth 분기

**Files:**
- Modify: `homelab-ops/bin/guard` (credential gate 블록)
- Modify: `homelab-ops/tests/test_guard_exec.sh`

- [ ] **Step 1: Write failing test** — `homelab-ops/tests/test_guard_exec.sh` 의 `# caution on lab env:` 줄 직전에 삽입:

```bash
# password 호스트: HL_SSH_KEY 가 있어도 HL_SSH_PASS 없으면 ssh-gate 가 막는다.
assert_status 3 'env -u HL_SSH_PASS HL_SSH_KEY=x PVE_TOKEN=x bin/guard stop pwhost' "password host without HL_SSH_PASS exits 3"
# password 호스트: HL_SSH_PASS 있으면 자격 게이트 통과(→ caution+lab 진행)
out="$(HL_SSH_PASS=x bin/guard stop pwhost)"
assert_contains "$out" "BACKEND action=stop" "password host with HL_SSH_PASS passes gate"
```

(주: `test_guard_exec.sh` 는 `tests/fixtures/fleet.yaml` 사용 — Task 4 에서 `pwhost` 추가됨. 이 파일은 `HOMELAB_BACKEND=/tmp/fake-backend` 이므로 ssh-run 까지 가지 않고 게이트만 검증.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_guard_exec.sh`
Expected: FAIL — 현재 게이트는 ssh transport 에서 `HL_SSH_KEY` 만 본다. `HL_SSH_KEY=x` 면 통과해버려 "without HL_SSH_PASS exits 3" 가 FAIL(exit 3 아님).

- [ ] **Step 3: Implement** — `homelab-ops/bin/guard` 의 credential gate 블록. 기존:

```bash
    _t="$(op_transport "$action" "$(jq -r '.kind // ""' <<<"$inv_json")")"
    if [[ "$grade" != "safe" ]]; then
      _gate_var=""
      [[ "$_t" == "pve" && -z "${PVE_TOKEN:-}"  ]] && _gate_var="PVE_TOKEN"
      [[ "$_t" == "ssh" && -z "${HL_SSH_KEY:-}" ]] && _gate_var="HL_SSH_KEY"
      if [[ -n "$_gate_var" ]]; then
```
신규:
```bash
    _t="$(op_transport "$action" "$(jq -r '.kind // ""' <<<"$inv_json")")"
    _auth="$(jq -r '.access.ssh.auth // "key"' <<<"$inv_json")"
    if [[ "$grade" != "safe" ]]; then
      _gate_var=""
      [[ "$_t" == "pve" && -z "${PVE_TOKEN:-}" ]] && _gate_var="PVE_TOKEN"
      if [[ "$_t" == "ssh" ]]; then
        if [[ "$_auth" == "password" ]]; then
          [[ -z "${HL_SSH_PASS:-}" ]] && _gate_var="HL_SSH_PASS"
        else
          [[ -z "${HL_SSH_KEY:-}" ]] && _gate_var="HL_SSH_KEY"
        fi
      fi
      if [[ -n "$_gate_var" ]]; then
```

(이후 `_gate_var` 사용부·die 메시지는 그대로 — 변수명만 동적으로 들어간다.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_guard_exec.sh`
Expected: PASS (신규 2단언 + 기존 `pkg-install without HL_SSH_KEY exits 3` 등 회귀 없음 — key 경로 `_auth` 기본값 "key" 라 분기 동일).

- [ ] **Step 5: Commit**

```bash
cd ~/claude-skills
git add homelab-ops/bin/guard homelab-ops/tests/test_guard_exec.sh
git commit -m "feat(homelab-ops): credential gate requires HL_SSH_PASS for auth=password

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Part B — `ssh-run` sshpass 경로 + stub

**Files:**
- Create: `homelab-ops/tests/stubs/sshpass`
- Modify: `homelab-ops/bin/ssh-run` (자격 검사 순서 재배치 + password 분기)
- Modify: `homelab-ops/tests/test_ssh_run.sh`

- [ ] **Step 1: sshpass stub 생성** — `homelab-ops/tests/stubs/sshpass`:

```bash
#!/usr/bin/env bash
# Test stub: record argv (mask SSHPASS), then exec the wrapped command
# (`ssh ...`, itself stubbed). `-e` means password comes from $SSHPASS env.
echo "sshpass $*" >> "${SSHPASS_SPY:-/tmp/sshpass-args}"
[[ "${1:-}" == "-e" ]] && shift
exec "$@"
```
생성 후 실행권한: `chmod +x homelab-ops/tests/stubs/sshpass`.

- [ ] **Step 2: Write failing test** — `homelab-ops/tests/test_ssh_run.sh` 의 `finish;` 직전에 삽입:

```bash
# password 인증 경로: sshpass -e 사용, 비번은 SSHPASS env(argv 미노출),
# StrictHostKeyChecking=yes 유지.
export SSHPASS_SPY="$(mktemp)"; : > "$SSHPASS_SPY"
: > /tmp/ssh-args 2>/dev/null || true
out="$(HL_SSH_PASS='p@ss w0rd' bin/ssh-run pwhost -- echo hi 2>&1)"
spy="$(cat "$SSHPASS_SPY")"
assert_contains "$spy" "sshpass -e" "password path invokes sshpass -e"
assert_not_contains "$spy" "p@ss w0rd" "password never in sshpass argv"
sa="$(cat /tmp/ssh-args 2>/dev/null || true)"
assert_contains "$sa" "StrictHostKeyChecking=yes" "password path keeps host key check"
assert_contains "$sa" "PubkeyAuthentication=no" "password path disables pubkey"
# 미주입 시 fail-closed
assert_status 3 'env -u HL_SSH_PASS bin/ssh-run pwhost -- echo hi' "password path without HL_SSH_PASS exits 3"
# key 경로 회귀: key 호스트는 기존대로(HL_SSH_KEY 필요)
assert_status 3 'env -u HL_SSH_KEY bin/ssh-run keyhost-notes -- echo hi' "key host still needs HL_SSH_KEY"
rm -f "$SSHPASS_SPY"
```

(전제: `tests/stubs/ssh` 가 호출 인자를 `/tmp/ssh-args` 에 기록하는지 확인. 기록 안 하면 Step 4 직전에 `tests/stubs/ssh` 에 `echo "ssh $*" >> /tmp/ssh-args` 한 줄을 추가하는 하위 단계를 먼저 수행하고 별도 커밋 메시지 없이 본 task 커밋에 포함. `keyhost-notes`·`pwhost` 는 Task 3·4 fixture 에 존재.)

- [ ] **Step 3: Run test to verify it fails**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_ssh_run.sh`
Expected: FAIL — 현재 `ssh-run` 은 맨 위에서 `HL_SSH_KEY` 부재 시 die(exit 3). `pwhost` 는 `HL_SSH_KEY` 없음 → password 단언 이전에 exit 3 → "invokes sshpass -e" FAIL.

- [ ] **Step 4: Implement** — `homelab-ops/bin/ssh-run` 전체를 다음으로 교체:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

target="${1:-}"
[[ -n "$target" ]] || die "usage: ssh-run <target-id> -- <command...>"
shift
[[ "${1:-}" == "--" ]] && shift || die "usage: ssh-run <target-id> -- <command...>"
[[ $# -ge 1 ]] || die "no remote command given"

inv="$("$HERE/inv" get "$target")" || die "no such target: $target"
addr="$(jq -r '.address // empty' <<<"$inv")"
[[ -n "$addr" && "$addr" != "null" ]] || die "target $target has no address in inventory"
user="$(jq -r '.access.ssh.user // "root"' <<<"$inv")"
auth="$(jq -r '.access.ssh.auth // "key"' <<<"$inv")"

if [[ "$auth" == "password" ]]; then
  # 비번은 bitwarden-ops bw-exec 가 HL_SSH_PASS env 로 주입. 미주입 시
  # fail-closed(exit 3). 비번은 SSHPASS env 로만 흐르고 argv 에 안 닿는다.
  [[ -n "${HL_SSH_PASS:-}" ]] || { HL_EXIT=3 die "missing HL_SSH_PASS — bitwarden-ops bw-exec 로 감싸 실행 (참고: \"$HERE/guard\" --plan)"; }
  command -v sshpass >/dev/null 2>&1 || { HL_EXIT=3 die "sshpass 미설치 — password 인증 호스트($target) 조작에 필요"; }
  SSHPASS="$HL_SSH_PASS" sshpass -e ssh \
      -o StrictHostKeyChecking=yes -o BatchMode=no \
      -o PubkeyAuthentication=no -o PreferredAuthentications=password \
      -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
      "${user}@${addr}" -- "$@"
  exit $?
fi

# 키 인증(기본). 키는 bitwarden-ops bw-exec 가 HL_SSH_KEY env 로 주입한다.
# 미주입 시 fail-closed(exit 3) — agent 도 띄우지 않는다.
[[ -n "${HL_SSH_KEY:-}" ]] || { HL_EXIT=3 die "missing HL_SSH_KEY — bitwarden-ops bw-exec 로 감싸 실행 (참고: \"$HERE/guard\" --plan)"; }

# Ephemeral ssh-agent; 키는 env → ssh-add stdin 으로만 흐르고 디스크에 안 닿는다.
# printf '%s\n': ssh-add 는 PEM/OpenSSH 키 끝에 개행이 있어야 파싱한다(없으면
# libcrypto 오류). 키가 이미 개행으로 끝나도 ssh-add 는 중복 개행을 무해 처리.
eval "$(ssh-agent -s)" >/dev/null
cleanup() { ssh-agent -k >/dev/null 2>&1 || true; }
trap cleanup EXIT
printf '%s\n' "$HL_SSH_KEY" | ssh-add - >/dev/null 2>&1 \
  || die "ssh-add failed (could not load key for $target)"

ssh -o StrictHostKeyChecking=yes -o BatchMode=yes \
    -o UserKnownHostsFile="$HOME/.ssh/known_hosts" \
    "${user}@${addr}" -- "$@"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_ssh_run.sh`
Expected: PASS (신규 password 단언 + 기존 key 경로 단언 회귀 없음). 이어 `bash tests/run.sh` → `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-skills
git add homelab-ops/bin/ssh-run homelab-ops/tests/stubs/sshpass homelab-ops/tests/test_ssh_run.sh homelab-ops/tests/stubs/ssh
git commit -m "feat(homelab-ops): ssh-run sshpass -e path for auth=password

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Part B — `mask()` + guard inline sed 에 HL_SSH_PASS/SSHPASS

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (`mask()`)
- Modify: `homelab-ops/bin/guard` (inline `sed -uE` 블록)
- Modify: `homelab-ops/tests/test_mask_parity.sh` (또는 신규 mask 단언)

- [ ] **Step 1: Write failing test** — `homelab-ops/tests/test_mask_parity.sh` 의 `finish;` 직전에 삽입:

```bash
# HL_SSH_PASS / SSHPASS 값이 마스킹되는지(누출 방지).
src="$(printf 'x HL_SSH_PASS=p@ssw0rd y\nSSHPASS=topsecret z\n')"
masked="$(printf '%s' "$src" | (source bin/_lib.sh; mask))"
assert_not_contains "$masked" "p@ssw0rd" "HL_SSH_PASS value masked"
assert_not_contains "$masked" "topsecret" "SSHPASS value masked"
```

(주: `test_mask_parity.sh` 가 `assert_not_contains` 를 쓰려면 `source tests/lib.sh` 가 이미 되어 있어야 함 — 파일 상단에 있음. `mask` 는 `_lib.sh` 함수.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_mask_parity.sh`
Expected: FAIL — 현재 규칙은 `(PVE_TOKEN|HL_SSH_KEY)=` 만 마스킹. `HL_SSH_PASS=p@ssw0rd`/`SSHPASS=topsecret` 그대로 남아 `assert_not_contains` FAIL.

- [ ] **Step 3: Implement (두 곳 byte-identical)** — 다음 한 줄을 `homelab-ops/bin/_lib.sh` 의 `mask()` 와 `homelab-ops/bin/guard` 의 inline `sed -uE` 양쪽에서 동일하게 교체:

기존(양쪽 동일):
```
    -e 's/((PVE_TOKEN|HL_SSH_KEY)=)[^[:space:]]+/\1***MASKED***/g' \
```
신규(양쪽 동일, byte-identical 유지 — `test_mask_parity` 의 규칙목록 동일성 계약):
```
    -e 's/((PVE_TOKEN|HL_SSH_KEY|HL_SSH_PASS|SSHPASS)=)[^[:space:]]+/\1***MASKED***/g' \
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/claude-skills/homelab-ops && bash tests/test_mask_parity.sh`
Expected: PASS — 신규 마스킹 단언 + 기존 "mask() and guard inline sed rule lists are byte-identical" 통과(양쪽 동일 수정이라 parity 유지).

- [ ] **Step 5: 전체 스위트 회귀 확인**

Run: `cd ~/claude-skills/homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Commit**

```bash
cd ~/claude-skills
git add homelab-ops/bin/_lib.sh homelab-ops/bin/guard homelab-ops/tests/test_mask_parity.sh
git commit -m "feat(homelab-ops): mask HL_SSH_PASS/SSHPASS in run logs (parity kept)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: homelab-ops SKILL.md + fleet.example.yaml (Part B 문서)

**Files:**
- Modify: `homelab-ops/SKILL.md`
- Modify: `homelab-ops/inventory/fleet.example.yaml`

- [ ] **Step 1: deps 줄** — `homelab-ops/SKILL.md` 의 `Deps:` 가 있는 문장에서 `ssh`/`ssh-agent` 뒤에 `, \`sshpass\`(패스워드 인증 호스트에서만)` 를 추가.

- [ ] **Step 2: hard rule #2** — `homelab-ops/SKILL.md` Hard rules 2번의 `(\`PVE_TOKEN\`/\`HL_SSH_KEY\`)` 를 `(\`PVE_TOKEN\`/\`HL_SSH_KEY\`/\`HL_SSH_PASS\`)` 로 변경.

- [ ] **Step 3: auth/pass_ref 규약** — Task 3 Step 4 에서 추가한 Credentials 절 인용 블록에 한 줄 더 추가:

```markdown
> - SSH **패스워드** 호스트는 `access.ssh.auth: password` + `pass_ref:
>   "bw://ssh-<id>-pass"` (single-line, `bw-put` tty 경로로 등록 가능).
>   `guard --plan` 은 `HL_SSH_PASS` 를, `ssh-run` 은 `sshpass -e` 를 쓴다.
```

- [ ] **Step 4: example 패스워드 호스트** — `homelab-ops/inventory/fleet.example.yaml` 의 `nas-01` 엔트리를 패스워드 인증 예시로 교체:

```yaml
- id: nas-01
  kind: appliance
  address: 10.0.0.50
  env: prod
  access:
    ssh: { user: admin, auth: password, pass_ref: "bw://ssh-nas-01-pass" }
  tags: [critical]
```

- [ ] **Step 5: docs/skeleton 테스트 회귀 확인**

Run: `cd ~/claude-skills/homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (SKILL.md/example 변경은 stub 테스트에 영향 없음; fixture 가 아닌 example 이므로).

- [ ] **Step 6: Commit**

```bash
cd ~/claude-skills
git add homelab-ops/SKILL.md homelab-ops/inventory/fleet.example.yaml
git commit -m "docs(homelab-ops): document auth/pass_ref + sshpass dep + key /notes

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: 통합 검증 + PR

- [ ] **Step 1: 두 스킬 전체 스위트**

Run:
```bash
cd ~/claude-skills/bitwarden-ops && bash tests/run.sh
cd ~/claude-skills/homelab-ops   && bash tests/run.sh
```
Expected: 양쪽 `ALL TESTS PASSED`.

- [ ] **Step 2: 환경 데이터 누출 점검**

Run: `cd ~/claude-skills && git diff <base>..HEAD | grep -nE '192\.168\.|root@pam!|-----BEGIN' || echo clean`
Expected: `clean` (실 IP·토큰·키 없음 — fixture/example 의 10.0.0.x 만 허용).

- [ ] **Step 3: PR 생성** — gitea-ops 스킬로(별도 세션/플로우, 사용자에게 단발/리뷰루프 모드 확인 후):

```
gitea-pr --title "feat(homelab-ops): SSH-transport 자격 정렬 (키/notes + 패스워드)" --base main --head feat/ssh-transport-credentials --body "<spec 요약 + 검증 결과>"
```
Expected: PR URL 출력. PR #24 와 독립.

---

## Self-Review (작성자 점검 결과)

**1. Spec coverage:**
- §3.1 bw-put --from-file → Task 1. §3.2 notes 규약 → Task 1/3. §3.3 키 정렬(로직0) → Task 3. §3.4 인벤토리 auth/pass_ref → Task 4; ssh-run → Task 6; guard --plan → Task 4; gate → Task 5; mask → Task 7; sshpass dep/문서 → Task 6/8. §5 테스트 → 각 Task RED/GREEN + Task 9 통합. §6 리스크(argv 미노출/StrictHostKeyChecking/마스킹) → Task 6·7 단언으로 커버. 누락 없음.

**2. Placeholder scan:** 모든 코드 step 에 실제 코드 블록·정확 경로·정확 명령·기대 출력 명시. "적절히 처리" 류 없음. Task 6 Step 2 의 `tests/stubs/ssh` 인자기록 전제는 조건부 하위단계로 구체화함.

**3. Type/이름 일관성:** 인벤토리 필드 `access.ssh.auth`(기본 "key")·`pass_ref`·`key_ref`, env 변수 `HL_SSH_PASS`/`HL_SSH_KEY`/`PVE_TOKEN`/`SSHPASS`, fixture id `keyhost-notes`/`pwhost` — Task 3~8 전반 동일 사용. mask 규칙은 두 파일 byte-identical(Task 7) 로 parity 계약 유지.

알려진 한계: Task 3 은 의도적으로 RED 없음(Part A 무-로직-변경, lock 테스트) — spec §3.3 과 일치하며 plan 본문에 명시.
