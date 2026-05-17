# homelab-ops → bitwarden-ops 위임 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** homelab-ops에서 자체 Bitwarden 로직(`bin/bw-resolve`)을 제거하고, credential은 bitwarden-ops `bw-exec`가 env로 주입한 값을 소비하도록 전환한다.

**Architecture:** homelab-ops는 Bitwarden 동작을 정의하지 않는다. (A) 언락/세션은 SKILL.md가 Claude에게 bitwarden-ops 스킬을 호출하도록 지시. (B) 시크릿 해결은 `bw-exec PVE_TOKEN=bw://... HL_SSH_KEY=bw://... -- guard <op>` 명령줄 합성으로 위임. `guard --plan <op>`이 inventory만 읽어 필요한 `NAME=bw://ref` 매핑을 산출(시크릿 미접근). transport(pve/ssh) 결정은 `_lib.sh`의 공유 헬퍼로 단일화해 `_backend`·게이트·`--plan`이 같은 판단을 쓴다.

**Tech Stack:** bash, jq, GNU sed, 기존 stub 기반 오프라인 테스트 하네스(`tests/run.sh`).

스펙: `docs/superpowers/specs/2026-05-17-homelab-ops-bitwarden-ops-delegation-design.md`

---

## File Structure

- `homelab-ops/bin/_lib.sh` — 공유 헬퍼 `op_transport`, `owner_host` 추가; `mask()`에 `PVE_TOKEN=`/`HL_SSH_KEY=` 규칙 추가
- `homelab-ops/bin/_backend` — `_owner_host`/transport 분기를 공유 헬퍼로 교체 (drift 제거)
- `homelab-ops/bin/guard` — `--plan` 모드 신설; `BW_SESSION` 게이트를 transport 기준 `PVE_TOKEN`/`HL_SSH_KEY` 게이트로 교체; inline sed 마스킹 규칙 추가
- `homelab-ops/bin/pve` — `token_ref`+`bw-resolve` 제거, `PVE_TOKEN` env 소비
- `homelab-ops/bin/ssh-run` — `BW_SESSION` 게이트+`key_ref`+`bw-resolve --ssh` 제거, `HL_SSH_KEY` env 소비
- `homelab-ops/bin/bw-resolve` — **삭제**
- `homelab-ops/tests/test_bw_resolve.sh` — **삭제**
- `homelab-ops/tests/stubs/bw` — **삭제**
- `homelab-ops/tests/test_guard_plan.sh` — **신설**
- `homelab-ops/tests/{test_lib,test_pve,test_ssh_run,test_guard_exec,test_guard_signal,test_forensic_sufficiency,test_provision,test_harness}.sh` — env 주입 모델로 갱신
- `homelab-ops/SKILL.md` — credential 절 재작성
- inventory — **변경 없음**

모든 작업은 `homelab-ops/` 디렉터리 기준. 테스트는 항상 `cd homelab-ops && bash tests/run.sh` 로 전체 실행.

---

### Task 1: `_lib.sh`에 공유 헬퍼 `op_transport` / `owner_host` 추가

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (끝에 함수 추가)
- Test: `homelab-ops/tests/test_lib.sh`

- [ ] **Step 1: 실패하는 테스트 추가**

`homelab-ops/tests/test_lib.sh`의 `_libprobe.sh` here-doc 안 `case "$1" in` 에 두 case를 추가한다. 기존:

```bash
  runlog) run_log_path "op-1" ;;
esac
```

를 다음으로 교체:

```bash
  runlog) run_log_path "op-1" ;;
  transport) op_transport "$2" "$3" ;;
  owner) owner_host "$2" ;;
esac
```

그리고 `finish; echo "PASS test_lib"` 바로 위에 다음 블록을 추가:

```bash
assert_eq "none" "$(bash bin/_libprobe.sh transport status proxmox-host)" "status → none"
assert_eq "pve"  "$(bash bin/_libprobe.sh transport stop vm)"            "stop vm → pve"
assert_eq "pve"  "$(bash bin/_libprobe.sh transport destroy proxmox-host)" "destroy host → pve"
assert_eq "ssh"  "$(bash bin/_libprobe.sh transport stop appliance)"     "stop appliance → ssh"
assert_eq "ssh"  "$(bash bin/_libprobe.sh transport pkg-install vm)"     "pkg-install → ssh"
assert_eq "pve"  "$(bash bin/_libprobe.sh transport provision proxmox-host)" "provision → pve"
assert_eq "none" "$(bash bin/_libprobe.sh transport frobnicate vm)"      "unknown action → none"
assert_eq "pve-01"     "$(bash bin/_libprobe.sh owner vm-100)"    "owner_host: child → parent host"
assert_eq "lab-vm-900" "$(bash bin/_libprobe.sh owner lab-vm-900)" "owner_host: orphan → itself"
```

- [ ] **Step 2: 실패 확인**

Run: `cd homelab-ops && bash tests/test_lib.sh`
Expected: FAIL — `op_transport: command not found` (또는 빈 출력으로 assert 실패)

- [ ] **Step 3: 헬퍼 구현**

`homelab-ops/bin/_lib.sh` 파일 끝(`run_log_path` 함수 정의 뒤)에 추가:

```bash

# op_transport <action> <kind> -> pve | ssh | none
# bin/_backend 의 디스패치 결정을 그대로 미러링하는 단일 출처. _backend·guard
# 게이트·guard --plan 이 모두 이 함수를 거쳐 같은 판단을 쓴다 (drift 방지).
op_transport() {
  local action="${1:?op_transport: action required}" kind="${2:-}"
  case "$action" in
    status|metrics|get) echo none ;;
    start|stop|restart|destroy|snapshot)
      case "$kind" in proxmox-host|vm|lxc) echo pve ;; *) echo ssh ;; esac ;;
    pkg-install) echo ssh ;;
    provision)   echo pve ;;
    *)           echo none ;;
  esac
}

# owner_host <target> -> 그 target 을 children 으로 가진 첫 Proxmox 호스트 id,
# 없으면 target 자신. (bin/_backend 의 기존 _owner_host 와 동일 로직)
owner_host() {
  local target="${1:?owner_host: target required}" x
  for x in $("$REPO_ROOT/bin/inv" list); do
    if "$REPO_ROOT/bin/inv" children "$x" | grep -qx "$target"; then
      echo "$x"; return 0
    fi
  done
  echo "$target"
}
```

- [ ] **Step 4: 통과 확인**

Run: `cd homelab-ops && bash tests/test_lib.sh`
Expected: PASS — 새 assert 9개 모두 `ok:`, `PASS test_lib`

- [ ] **Step 5: 전체 스위트 회귀 확인**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 6: 커밋**

```bash
git add homelab-ops/bin/_lib.sh homelab-ops/tests/test_lib.sh
git commit -m "feat(homelab-ops): op_transport/owner_host 공유 헬퍼 추가

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `_backend`가 공유 헬퍼를 쓰도록 리팩터 (drift 제거)

**Files:**
- Modify: `homelab-ops/bin/_backend`
- Test: 기존 `tests/test_guard_exec.sh`, `tests/test_provision.sh` (회귀)

- [ ] **Step 1: `_owner_host` 정의 제거**

`homelab-ops/bin/_backend`에서 다음 블록을 삭제:

```bash
# First Proxmox host whose children include $target, else $target itself.
_owner_host() {
  local x
  for x in $("$HERE/inv" list); do
    if "$HERE/inv" children "$x" | grep -qx "$target"; then echo "$x"; return; fi
  done
  echo "$target"
}
```

- [ ] **Step 2: transport 분기와 호출부를 헬퍼로 교체**

`homelab-ops/bin/_backend`에서:

```bash
    if [[ "$kind" == proxmox-host || "$kind" == vm || "$kind" == lxc ]]; then
      "$HERE/pve" "$(_owner_host)" action "$action" "$target" "$@"
    else
      "$HERE/ssh-run" "$target" -- "$action" "$@"
    fi ;;
```

를 다음으로 교체:

```bash
    if [[ "$(op_transport "$action" "$kind")" == pve ]]; then
      "$HERE/pve" "$(owner_host "$target")" action "$action" "$target" "$@"
    else
      "$HERE/ssh-run" "$target" -- "$action" "$@"
    fi ;;
```

(`_lib.sh`는 `_backend` 상단에서 이미 source 되므로 헬퍼는 사용 가능.)

- [ ] **Step 3: 회귀 테스트**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (동작 동등 — 출력·경로 변화 없음)

- [ ] **Step 4: 커밋**

```bash
git add homelab-ops/bin/_backend
git commit -m "refactor(homelab-ops): _backend 가 op_transport/owner_host 공유 헬퍼 사용

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: 영향받는 테스트에 `PVE_TOKEN`/`HL_SSH_KEY` export 선반영 (additive)

이 단계는 코드 변경 없이 테스트에 새 env 를 **기존 `BW_SESSION` 옆에 추가**한다. 옛 코드는 새 env 를 무시하므로 스위트는 계속 녹색이며, 이후 코드 변경 task 가 task 별로 녹색을 유지하게 한다.

**Files:**
- Modify: `tests/test_pve.sh`, `tests/test_ssh_run.sh`, `tests/test_guard_exec.sh`, `tests/test_guard_signal.sh`, `tests/test_forensic_sufficiency.sh`, `tests/test_provision.sh`

- [ ] **Step 1: pve 토큰 소비 테스트에 PVE_TOKEN 추가**

다음 4개 파일에서 `export BW_SESSION="stub-session"` 줄 **바로 아래**에 한 줄을 추가:

`tests/test_pve.sh`, `tests/test_guard_exec.sh`, `tests/test_guard_signal.sh`, `tests/test_forensic_sufficiency.sh`, `tests/test_provision.sh` —

추가할 줄:

```bash
export PVE_TOKEN="stub-token-value"
```

(`test_provision.sh`는 `export BW_SESSION="stub-session"` 줄 아래에 추가.)

- [ ] **Step 2: ssh 키 소비 테스트에 HL_SSH_KEY 추가**

`tests/test_ssh_run.sh`에서 `export BW_SESSION="stub-session"` 줄 바로 아래에 추가:

```bash
export HL_SSH_KEY="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nSTUBKEY-ssh-nas-01\n-----END OPENSSH PRIVATE KEY-----')"
```

(마커 `STUBKEY-ssh-nas-01`은 같은 파일의 디스크 누출 스캔 `grep -rqI "STUBKEY-ssh-nas-01"`이 검사하는 문자열과 일치시켜, 새 모델에서도 키가 디스크에 안 닿는지 계속 검증되게 한다.)

- [ ] **Step 3: 스위트 녹색 확인 (additive, 동작 무변)**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 4: 커밋**

```bash
git add homelab-ops/tests/test_pve.sh homelab-ops/tests/test_ssh_run.sh homelab-ops/tests/test_guard_exec.sh homelab-ops/tests/test_guard_signal.sh homelab-ops/tests/test_forensic_sufficiency.sh homelab-ops/tests/test_provision.sh
git commit -m "test(homelab-ops): PVE_TOKEN/HL_SSH_KEY env 선반영 (전환용, additive)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `guard --plan <action> <target>` read-only 계획 모드

**Files:**
- Modify: `homelab-ops/bin/guard`
- Test: `homelab-ops/tests/test_guard_plan.sh` (신설)

- [ ] **Step 1: 실패하는 테스트 작성**

새 파일 `homelab-ops/tests/test_guard_plan.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard 2>/dev/null || true

# 안전 등급 op 는 credential 불필요 → 빈 출력
out="$(bin/guard --plan status vm-100)"
assert_eq "" "$out" "safe op → empty plan"

# critical bump 으로 caution 이지만 transport none → 빈 출력
out="$(bin/guard --plan status pve-01)"
assert_eq "" "$out" "status on critical (caution, transport none) → empty plan"

# vm action → 소유 Proxmox 호스트의 api token_ref
out="$(bin/guard --plan stop vm-100)"
assert_eq "PVE_TOKEN=bw://Proxmox pve-01/api-token" "$out" "vm stop → owner host PVE_TOKEN ref"

# appliance action → 그 target 의 ssh key_ref
out="$(bin/guard --plan stop nas-01)"
assert_eq "HL_SSH_KEY=bw://ssh-nas-01" "$out" "appliance stop → HL_SSH_KEY ref"

# pkg-install → ssh transport
out="$(bin/guard --plan pkg-install vm-100)"
assert_eq "HL_SSH_KEY=bw://ssh-vm-100" "$out" "pkg-install → HL_SSH_KEY ref"

# provision → 호스트 자신의 token_ref
out="$(bin/guard --plan provision pve-01)"
assert_eq "PVE_TOKEN=bw://Proxmox pve-01/api-token" "$out" "provision → host PVE_TOKEN ref"

# --plan 은 어떤 시크릿에도 접근하지 않는다: bw 가 PATH 에 없어도 동작
out="$(env -u BW_SESSION PATH="/usr/bin:/bin" bash bin/guard --plan stop vm-100 2>/dev/null || true)"
assert_eq "PVE_TOKEN=bw://Proxmox pve-01/api-token" "$out" "--plan resolves without any bw/session"

# 잘못된 사용
assert_status 1 'bin/guard --plan' "no args → usage error"

finish; echo "PASS test_guard_plan"
```

- [ ] **Step 2: 실패 확인**

Run: `cd homelab-ops && bash tests/test_guard_plan.sh`
Expected: FAIL — `guard`가 `--plan`을 모르는 action 으로 처리 (deny-by-default → 다른 경로/에러)

- [ ] **Step 3: `--plan` case arm 구현**

`homelab-ops/bin/guard`의 `case "${1:-}" in` 에서 `"")` arm 과 `*)` arm 사이에 다음 arm 을 추가한다. 즉:

```bash
  "")
    die "usage: guard <action> <target-id> [--approve] [-- <extra>...]" ;;
```

바로 뒤, `*)` 앞에 삽입:

```bash
  --plan)
    # read-only: inventory 만 읽어 op 가 필요로 하는 NAME=bw://ref 를 출력.
    # 어떤 시크릿에도 접근하지 않는다 (safe).
    [[ $# -ge 3 ]] || die "usage: guard --plan <action> <target-id>"
    pa="$2"; pt="$3"
    pgrade="$(guard_grade "$pa" "$pt")"        # target 존재도 검증; 없으면 die
    [[ "$pgrade" == "safe" ]] && exit 0        # safe op 는 credential 불필요
    pinv="$("$HERE/inv" get "$pt")" || exit $?
    pkind="$(jq -r '.kind // ""' <<<"$pinv")"
    case "$(op_transport "$pa" "$pkind")" in
      pve)
        pref="$("$HERE/inv" get "$(owner_host "$pt")" \
                | jq -r '.access.api.token_ref // empty')"
        [[ -n "$pref" ]] && printf 'PVE_TOKEN=%s\n' "$pref" ;;
      ssh)
        pref="$(jq -r '.access.ssh.key_ref // empty' <<<"$pinv")"
        [[ -n "$pref" ]] && printf 'HL_SSH_KEY=%s\n' "$pref" ;;
    esac
    exit 0 ;;
```

- [ ] **Step 4: 통과 확인**

Run: `cd homelab-ops && bash tests/test_guard_plan.sh`
Expected: PASS — 모든 assert `ok:`, `PASS test_guard_plan`

- [ ] **Step 5: 전체 스위트**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (additive — 기존 동작 무영향)

- [ ] **Step 6: 커밋**

```bash
git add homelab-ops/bin/guard homelab-ops/tests/test_guard_plan.sh
git commit -m "feat(homelab-ops): guard --plan — op 가 필요한 bw://ref 산출 (read-only)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `BW_SESSION` 게이트를 transport 기준 credential 게이트로 교체

**Files:**
- Modify: `homelab-ops/bin/guard` (87–91행 부근), `homelab-ops/tests/test_guard_exec.sh`
- Test: `tests/test_guard_exec.sh`, 전체 스위트

- [ ] **Step 1: 게이트 교체**

`homelab-ops/bin/guard`에서 다음 블록(현재 87–91행):

```bash
    # BW_SESSION gate for everything except safe.
    if [[ "$grade" != "safe" && -z "${BW_SESSION:-}" ]]; then
      _DONE=1; _audit 3 || echo "homelab-ops: AUDIT FAILED op=$op rc=3" >&2
      HL_EXIT=3 die "locked vault: BW_SESSION not set"
    fi
```

를 다음으로 교체:

```bash
    # Credential gate: 비-safe op 는 그 op 의 transport(pve|ssh)가 요구하는
    # credential env 가 있어야 한다. transport none(예: critical 로 caution 이 된
    # status — _backend 는 inv resolve 만 함)은 시크릿이 필요 없으므로 통과.
    # credential 은 bitwarden-ops bw-exec 가 주입 (homelab-ops 는 bw 를 모른다).
    _t="$(op_transport "$action" "$(jq -r '.kind // ""' <<<"$inv_json")")"
    if [[ "$grade" != "safe" ]]; then
      _gate_var=""
      [[ "$_t" == "pve" && -z "${PVE_TOKEN:-}"  ]] && _gate_var="PVE_TOKEN"
      [[ "$_t" == "ssh" && -z "${HL_SSH_KEY:-}" ]] && _gate_var="HL_SSH_KEY"
      if [[ -n "$_gate_var" ]]; then
        _DONE=1; _audit 3 || echo "homelab-ops: AUDIT FAILED op=$op rc=3" >&2
        HL_EXIT=3 die "missing $_gate_var — bitwarden-ops bw-exec 로 감싸 실행하세요: bw-exec \"\$('$HERE/guard' --plan $action $target)\" -- '$HERE/guard' $action $target"
      fi
    fi
```

- [ ] **Step 2: test_guard_exec 의 locked-vault assert 갱신**

`homelab-ops/tests/test_guard_exec.sh`에서:

```bash
# non-safe requires BW_SESSION
assert_status 3 'env -u BW_SESSION bin/guard stop lab-vm-900' "stop without BW_SESSION exits 3"
```

를 다음으로 교체 (`stop lab-vm-900`: kind=vm → transport pve → PVE_TOKEN 필요):

```bash
# non-safe op requires its transport credential (here: pve → PVE_TOKEN)
assert_status 3 'env -u PVE_TOKEN bin/guard stop lab-vm-900' "stop without PVE_TOKEN exits 3"
# transport-none op (status on critical = caution) is NOT blocked by the
# credential gate (no transport secret needed). pve-01 is prod+critical, so it
# still hits the *unrelated* pre-existing prod-approval gate → exit 10, NOT the
# credential gate's exit 3. exit 10 ≠ 3 proves the credential gate passed it.
assert_status 10 'env -u PVE_TOKEN -u HL_SSH_KEY bin/guard status pve-01' "caution+transport-none passes credential gate (no credential needed)"
```

> 주: 픽스처에서 `critical` 태그 호스트(`pve-01`,`nas-01`)는 모두 `env: prod`라 caution+transport-none 이 exit 0 에 도달할 수 없다(항상 prod-승인 게이트 exit 10 선행). credential 게이트가 막지 않았음(≠3)을 exit 10 으로 검증한다.

- [ ] **Step 3: 통과 확인**

Run: `cd homelab-ops && bash tests/test_guard_exec.sh`
Expected: PASS (`PVE_TOKEN`은 Task 3 에서 export 됨; `status pve-01`은 transport none 으로 credential 불필요)

- [ ] **Step 4: 전체 스위트**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (`BW_SESSION`은 아직 테스트에서 export 되지만 게이트가 더는 보지 않음 — 무해)

- [ ] **Step 5: 커밋**

```bash
git add homelab-ops/bin/guard homelab-ops/tests/test_guard_exec.sh
git commit -m "feat(homelab-ops): guard 게이트를 transport 기준 PVE_TOKEN/HL_SSH_KEY 로 교체

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `pve` — `PVE_TOKEN` env 소비, `bw-resolve` 제거

**Files:**
- Modify: `homelab-ops/bin/pve` (11–14행), `homelab-ops/tests/test_pve.sh`

- [ ] **Step 1: pve 토큰 소스 교체**

`homelab-ops/bin/pve`에서 다음 블록(현재 11–14행):

```bash
token_ref="$(jq -r '.access.api.token_ref // empty' <<<"$inv")"
[[ -n "$token_ref" ]] || die "host $host_id has no access.api.token_ref"

token="$("$HERE/bw-resolve" "$token_ref")" || exit $?   # propagates exit 3 if vault locked
```

를 다음으로 교체:

```bash
# 토큰은 bitwarden-ops bw-exec 가 PVE_TOKEN env 로 주입한다. homelab-ops 는
# bw 를 직접 다루지 않는다. 미주입 시 fail-closed(exit 3).
[[ -n "${PVE_TOKEN:-}" ]] || { HL_EXIT=3 die "missing PVE_TOKEN — bitwarden-ops bw-exec 로 감싸 실행 (참고: \"$HERE/guard\" --plan)"; }
token="$PVE_TOKEN"
```

(`base="https://${addr}:8006/api2/json"` 줄은 그대로 둔다.)

- [ ] **Step 2: test_pve 의 locked-vault assert 갱신**

`homelab-ops/tests/test_pve.sh`에서:

```bash
# locked vault: pve must refuse (it resolves a token via bw-resolve)
assert_status 3 'env -u BW_SESSION bin/pve pve-01 status' "pve without BW_SESSION exits 3"
```

를 다음으로 교체:

```bash
# no token injected: pve must refuse (exit 3)
assert_status 3 'env -u PVE_TOKEN bin/pve pve-01 status' "pve without PVE_TOKEN exits 3"
```

- [ ] **Step 3: 통과 확인**

Run: `cd homelab-ops && bash tests/test_pve.sh`
Expected: PASS (`PVE_TOKEN`은 Task 3 에서 export; curl 은 stub; 토큰 값 검증 없음)

- [ ] **Step 4: 전체 스위트**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (`test_provision` apply 경로의 실 pve 호출도 `PVE_TOKEN` 으로 동작 — Task 3 에서 export 됨)

- [ ] **Step 5: 커밋**

```bash
git add homelab-ops/bin/pve homelab-ops/tests/test_pve.sh
git commit -m "feat(homelab-ops): pve 가 PVE_TOKEN env 소비, bw-resolve 의존 제거

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: `ssh-run` — `HL_SSH_KEY` env 소비, `bw-resolve --ssh` 제거

**Files:**
- Modify: `homelab-ops/bin/ssh-run`, `homelab-ops/tests/test_ssh_run.sh`

- [ ] **Step 1: ssh-run 키 소스·게이트 교체**

`homelab-ops/bin/ssh-run`에서 현재 11–27행 블록:

```bash
# Locked-vault default: refuse before doing anything (fail fast, exit 3),
# consistent with bw-resolve/pve. Also avoids spawning an agent when locked.
[[ -n "${BW_SESSION:-}" ]] || { HL_EXIT=3 die "locked vault: BW_SESSION not set"; }

inv="$("$HERE/inv" get "$target")" || die "no such target: $target"
addr="$(jq -r '.address // empty' <<<"$inv")"
[[ -n "$addr" && "$addr" != "null" ]] || die "target $target has no address in inventory"
user="$(jq -r '.access.ssh.user // "root"' <<<"$inv")"
key_ref="$(jq -r '.access.ssh.key_ref // empty' <<<"$inv")"
[[ -n "$key_ref" ]] || die "target $target has no access.ssh.key_ref"

# Ephemeral ssh-agent; key piped from bw-resolve into ssh-add stdin. No disk.
eval "$(ssh-agent -s)" >/dev/null
cleanup() { ssh-agent -k >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$HERE/bw-resolve" --ssh "$key_ref" | ssh-add - >/dev/null 2>&1 \
  || die "ssh-add failed (could not load key for $target)"
```

를 다음으로 교체:

```bash
# 키는 bitwarden-ops bw-exec 가 HL_SSH_KEY env 로 주입한다. 미주입 시
# fail-closed(exit 3) — agent 도 띄우지 않는다.
[[ -n "${HL_SSH_KEY:-}" ]] || { HL_EXIT=3 die "missing HL_SSH_KEY — bitwarden-ops bw-exec 로 감싸 실행 (참고: \"$HERE/guard\" --plan)"; }

inv="$("$HERE/inv" get "$target")" || die "no such target: $target"
addr="$(jq -r '.address // empty' <<<"$inv")"
[[ -n "$addr" && "$addr" != "null" ]] || die "target $target has no address in inventory"
user="$(jq -r '.access.ssh.user // "root"' <<<"$inv")"

# Ephemeral ssh-agent; 키는 env → ssh-add stdin 으로만 흐르고 디스크에 안 닿는다.
# printf '%s\n': ssh-add 는 PEM/OpenSSH 키 끝에 개행이 있어야 파싱한다(없으면
# libcrypto 오류). 키가 이미 개행으로 끝나도 ssh-add 는 중복 개행을 무해 처리.
eval "$(ssh-agent -s)" >/dev/null
cleanup() { ssh-agent -k >/dev/null 2>&1 || true; }
trap cleanup EXIT
printf '%s\n' "$HL_SSH_KEY" | ssh-add - >/dev/null 2>&1 \
  || die "ssh-add failed (could not load key for $target)"
```

> **회차1 리뷰 정정 (C1):** 초안은 `printf '%s'`(개행 제거)였으나, 이는
> bitwarden-ops 의 password/notes *필드* byte-consistency 수정 논리를 키에
> 잘못 적용한 것. 실제 `ssh-add` 는 PEM/OpenSSH 키 말미 개행을 요구하므로
> `printf '%s\n'` 가 옳다. 아래 Step 의 `ssh-add` 스텁도 "스트림이 개행으로
> 끝나고 BEGIN/END PRIVATE KEY 블록을 포함" 을 검증하도록 강화해 이 회귀를
> 실제로 커버한다(기존 스텁은 입력을 무시해 false negative 였음).

- [ ] **Step 2: test_ssh_run 의 locked-vault assert 갱신**

`homelab-ops/tests/test_ssh_run.sh`에서:

```bash
# locked vault refusal (key resolved via bw-resolve --ssh)
assert_status 3 'env -u BW_SESSION bin/ssh-run nas-01 -- uname -a' "ssh-run without BW_SESSION exits 3"
```

를 다음으로 교체:

```bash
# no key injected: ssh-run must refuse before spawning an agent (exit 3)
assert_status 3 'env -u HL_SSH_KEY bin/ssh-run nas-01 -- uname -a' "ssh-run without HL_SSH_KEY exits 3"
```

- [ ] **Step 3: 통과 확인**

Run: `cd homelab-ops && bash tests/test_ssh_run.sh`
Expected: PASS — ssh stub 출력 확인, `STUBKEY-ssh-nas-01`가 `$TMPDIR`/`logs` 에 없음(디스크 누출 없음), `PASS test_ssh_run`

- [ ] **Step 4: 전체 스위트**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 5: 커밋**

```bash
git add homelab-ops/bin/ssh-run homelab-ops/tests/test_ssh_run.sh
git commit -m "feat(homelab-ops): ssh-run 이 HL_SSH_KEY env 소비, bw-resolve 의존 제거

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: 마스킹에 `PVE_TOKEN=`/`HL_SSH_KEY=` 규칙 추가

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (`mask()`), `homelab-ops/bin/guard` (inline sed), `homelab-ops/tests/test_lib.sh`

- [ ] **Step 1: 실패하는 테스트 추가**

`homelab-ops/tests/test_lib.sh`의 `_libprobe.sh` here-doc `case "$1" in` 에 case 추가. 기존:

```bash
  mask_hard) printf 'Authorization: Bearer SECRETBEARER123\n-----BEGIN OPENSSH PRIVATE KEY-----\nKEYBODYLINE0000\n-----END OPENSSH PRIVATE KEY-----\n{"password":"pw-secret-val"}\n' | mask ;;
```

바로 아래에 추가:

```bash
  mask_env) printf 'PVE_TOKEN=ptokVALUE123 HL_SSH_KEY=hkeyVALUE456\n' | mask ;;
```

그리고 `finish; echo "PASS test_lib"` 위에 추가:

```bash
menv="$(bash bin/_libprobe.sh mask_env)"
[[ "$menv" != *ptokVALUE123* ]] && echo "  ok: PVE_TOKEN value masked" \
  || { echo "  FAIL: PVE_TOKEN leaked"; exit 1; }
[[ "$menv" != *hkeyVALUE456* ]] && echo "  ok: HL_SSH_KEY value masked" \
  || { echo "  FAIL: HL_SSH_KEY leaked"; exit 1; }
assert_contains "$menv" "MASKED" "env-token inputs produce mask markers"
```

- [ ] **Step 2: 실패 확인**

Run: `cd homelab-ops && bash tests/test_lib.sh`
Expected: FAIL — `ptokVALUE123` 가 마스킹되지 않아 leak

- [ ] **Step 3: `mask()`에 규칙 추가**

`homelab-ops/bin/_lib.sh`의 `mask()` 안에서:

```bash
    -e 's/(BW_SESSION=)[^[:space:]]+/\1***MASKED***/g' \
```

바로 아래 줄을 추가:

```bash
    -e 's/((PVE_TOKEN|HL_SSH_KEY)=)[^[:space:]]+/\1***MASKED***/g' \
```

- [ ] **Step 4: guard inline sed 에 동일 규칙 추가**

`homelab-ops/bin/guard`의 액션 파이프라인 `sed -uE` 블록에서:

```bash
        -e 's/(BW_SESSION=)[^[:space:]]+/\1***MASKED***/g' \
```

바로 아래에 추가:

```bash
        -e 's/((PVE_TOKEN|HL_SSH_KEY)=)[^[:space:]]+/\1***MASKED***/g' \
```

- [ ] **Step 5: 통과 확인**

Run: `cd homelab-ops && bash tests/test_lib.sh`
Expected: PASS — `PVE_TOKEN value masked`, `HL_SSH_KEY value masked`, `PASS test_lib`

- [ ] **Step 6: 전체 스위트**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 7: 커밋**

```bash
git add homelab-ops/bin/_lib.sh homelab-ops/bin/guard homelab-ops/tests/test_lib.sh
git commit -m "feat(homelab-ops): 포렌식 마스킹에 PVE_TOKEN=/HL_SSH_KEY= 규칙 추가

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `bw-resolve`·`bw` 스텁·전환용 `BW_SESSION` export 제거

**Files:**
- Delete: `homelab-ops/bin/bw-resolve`, `homelab-ops/tests/test_bw_resolve.sh`, `homelab-ops/tests/stubs/bw`
- Modify: `homelab-ops/tests/test_harness.sh`, 그리고 Task 3 에서 손댄 6개 테스트의 `export BW_SESSION` 줄 제거

- [ ] **Step 1: 파일 삭제**

```bash
cd homelab-ops
git rm bin/bw-resolve tests/test_bw_resolve.sh tests/stubs/bw
```

- [ ] **Step 2: test_harness 에서 bw 스텁 단언 제거**

`homelab-ops/tests/test_harness.sh`에서 다음 블록을 삭제:

```bash
# stubs must be deterministic and on PATH via run.sh; check shape directly:
PATH="$PWD/tests/stubs:$PATH"
out="$(bw get password "x" --session s)"
[[ "$out" == "stub-secret-x" ]] || { echo "FAIL: bw stub"; exit 1; }
```

(`finish`/`echo "PASS test_harness"` 는 유지.)

- [ ] **Step 3: 전환용 `export BW_SESSION` 줄 제거**

다음 6개 파일에서 `export BW_SESSION="stub-session"` 줄을 **삭제**한다 (Task 3 에서 추가한 `PVE_TOKEN`/`HL_SSH_KEY` export 는 유지):

`tests/test_pve.sh`, `tests/test_ssh_run.sh`, `tests/test_guard_exec.sh`, `tests/test_guard_signal.sh`, `tests/test_forensic_sufficiency.sh`, `tests/test_provision.sh`

- [ ] **Step 4: 전체 스위트**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` — `test_bw_resolve` 가 사라지고 나머지 전부 통과 (어떤 코드도 `bw`/`BW_SESSION`/`bw-resolve` 에 더는 의존하지 않음)

- [ ] **Step 5: 잔존 참조 없음 확인**

Run: `cd homelab-ops && grep -rn "bw-resolve\|BW_SESSION\|stubs/bw" bin tests | grep -v Binary || echo "CLEAN"`
Expected: `CLEAN` (어떤 매치도 없음)

- [ ] **Step 6: 커밋**

```bash
git add -A homelab-ops/tests homelab-ops/bin
git commit -m "refactor(homelab-ops): bw-resolve·bw 스텁·전환용 BW_SESSION 제거

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: `SKILL.md` credential 절 재작성

**Files:**
- Modify: `homelab-ops/SKILL.md`

- [ ] **Step 1: description frontmatter 갱신**

`homelab-ops/SKILL.md`의 `description:` 줄에서 마지막 문장:

```
Credentials are `bw://` references resolved in-memory at call time, never on disk.
```

을 다음으로 교체:

```
Credentials are `bw://` references; resolution is delegated to the bitwarden-ops skill via `bw-exec`, never reimplemented here and never on disk.
```

- [ ] **Step 2: Deps 줄에서 bw CLI 제거**

본문 첫 단락의:

```
Deps: `bash`, `jq`, `python3`+PyYAML, `curl`, `ssh`/`ssh-agent`, Bitwarden `bw` CLI.
```

을 다음으로 교체:

```
Deps: `bash`, `jq`, `python3`+PyYAML, `curl`, `ssh`/`ssh-agent`. Credential resolution is delegated to the **bitwarden-ops** skill (`bw-exec`); homelab-ops itself never calls `bw`.
```

- [ ] **Step 3: "Session setup" 절 교체**

다음 절 전체:

```
## Session setup (the user does this once per session)
```sh
export BW_SESSION="$(bw unlock --raw)"   # the user types the master password — never Claude
export HOMELAB_SESSION_ID="sess-$(date -u +%Y%m%dT%H%M%SZ)"
```
No `BW_SESSION` ⇒ every mutating command refuses to start (exit 3, "locked vault").
```

을 다음으로 교체:

````
## Credentials — delegated to bitwarden-ops (homelab-ops never touches `bw`)
homelab-ops holds only `bw://` references (in inventory). Resolution is delegated
to the **bitwarden-ops** skill:

1. Ensure the vault is unlocked: invoke the bitwarden-ops skill (its `bw-unlock`
   / session persistence). The user types the master password — never Claude.
2. For any mutating op, ask guard which refs it needs, then wrap the real run
   with bitwarden-ops `bw-exec` so the secret is injected into the env and never
   enters Claude's context, argv, disk, or logs:

```sh
export HOMELAB_SESSION_ID="sess-$(date -u +%Y%m%dT%H%M%SZ)"
plan="$("$HL/bin/guard" --plan <action> <target>)"   # e.g. PVE_TOKEN=bw://...
bw-exec "$plan" -- "$HL/bin/guard" <action> <target> [--approve]
```

`guard --plan` is read-only (inventory only, no secret access); empty output ⇒
a safe op that needs no credential. A non-safe op whose transport credential is
absent refuses to start (exit 3) and prints the exact `bw-exec` line to use.
````

- [ ] **Step 4: Hard rule 2 교체**

```
2. **BW_SESSION required for any change.** Unset ⇒ guard refuses (exit 3, "locked vault"). Ask the user to `bw unlock`; never see, store, or handle the master password.
```

을 다음으로 교체:

```
2. **Credential injected via bitwarden-ops for any change.** A non-safe op whose transport credential (`PVE_TOKEN`/`HL_SSH_KEY`) is absent refuses (exit 3). Resolve refs with `guard --plan` and wrap the run in bitwarden-ops `bw-exec`; never see, store, or handle the master password, and never reimplement `bw` here.
```

- [ ] **Step 5: Hard rule 6 교체**

```
6. **Credentials are references.** Inventory holds `bw://` refs only. Resolution is in-memory via `bin/bw-resolve` (used internally by guard); never write a secret to disk or echo it unmasked.
```

을 다음으로 교체:

```
6. **Credentials are references, resolved by bitwarden-ops.** Inventory holds `bw://` refs only. Resolution is delegated to the bitwarden-ops skill via `bw-exec` (env injection, in-memory); homelab-ops defines no `bw` behavior. Never write a secret to disk or echo it unmasked.
```

- [ ] **Step 6: 검증 — bw unlock/BW_SESSION/bw-resolve 잔존 없음**

Run: `cd homelab-ops && grep -n "bw unlock\|BW_SESSION\|bw-resolve" SKILL.md || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 7: 전체 스위트 (문서 변경이지만 확인)**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`

- [ ] **Step 8: 커밋**

```bash
git add homelab-ops/SKILL.md
git commit -m "docs(homelab-ops): credential 절을 bitwarden-ops 위임으로 재작성

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: 최종 검증

**Files:** 없음 (검증·요약)

- [ ] **Step 1: 전체 스위트 최종 실행**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (test_bw_resolve 제외, test_guard_plan 포함 — 전부 PASS)

- [ ] **Step 2: bitwarden 잔존 0 확인**

Run: `cd homelab-ops && grep -rn "bw-resolve\|BW_SESSION\|bw unlock\|stubs/bw" bin tests SKILL.md provisioning || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 3: 스펙 커버리지 자기 점검**

스펙의 각 "파일별 변경" 항목이 Task 로 구현됐는지 대조:
- bw-resolve/test/stub 삭제 → Task 9 ✓
- pve PVE_TOKEN → Task 6 ✓
- ssh-run HL_SSH_KEY → Task 7 ✓
- guard 게이트 교체 + --plan → Task 5, 4 ✓
- _lib.sh 마스킹 → Task 8 ✓
- SKILL.md 재작성 → Task 10 ✓
- inventory 무변경 → 전 Task 미수정 ✓
- 테스트 갱신 → Task 3,5,6,7,8,9 ✓

- [ ] **Step 4: 작업 완료 보고**

브랜치 `feat/homelab-ops-bitwarden-delegation` 에 모든 커밋 존재. PR 생성/머지는 사용자 지시 시에만.

---

## Self-Review

**1. Spec coverage:** 스펙의 모든 "파일별 변경"·"부트스트랩 해법"·"보안 불변식"이 Task 1–10 에 매핑됨 (Task 11 Step 3 에서 대조). `guard --plan`(부트스트랩 해법) = Task 4. transport 단일화(drift 방지) = Task 1–2. 누락 없음.

**2. Placeholder scan:** 모든 step 에 실제 코드/명령/기대 출력 포함. "적절히 처리" 류 문구 없음. TBD/TODO 없음.

**3. Type/계약 일관성:** 환경변수명 `PVE_TOKEN`·`HL_SSH_KEY` 가 guard(--plan 출력·게이트), pve, ssh-run, mask, 테스트 전반에서 동일. 헬퍼명 `op_transport`·`owner_host` 가 Task 1 정의 이후 _backend·guard 에서 일관 사용. `guard --plan` 출력 형식 `NAME=bw://ref`(한 줄당 한 매핑) 이 Task 4 정의와 SKILL.md(Task 10)·게이트 메시지에서 일치.

**4. 녹색 유지:** Task 3 가 새 env 를 additive 로 선반영해 코드 변경(5–8) 동안 매 Task 끝에서 `tests/run.sh` 녹색. Task 9 에서 전환용 잔재 일괄 제거. 각 Task 가 자신이 만지는 테스트를 갱신 후 실행.
