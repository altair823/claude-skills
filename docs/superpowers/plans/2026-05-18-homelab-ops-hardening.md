# homelab-ops 하드닝 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** homelab-ops의 라우팅을 단일 테이블로 모으고, PVE 비동기 task를 폴링해 감사 기록이 "작업 결과"를 반영하게 하며, 유령 verb를 정리하고, 인벤토리를 `~/.config`에서 자동 발견하고, `backup` verb를 추가한다.

**Architecture:** bash 스킬. `bin/_lib.sh`가 단일 출처 액션 테이블(`ACTIONS`/`ACTION_ALIASES`)과 PVE task 폴링 헬퍼(`pve_wait_task`)를 보유. `bin/guard`/`bin/_backend`/`bin/pve`/`provisioning/phase1`가 이를 소비. 테스트는 `tests/stubs`(offline) + `HOMELAB_INVENTORY_DIR=tests/fixtures` 하니스 기반.

**Tech Stack:** bash, jq, python3+PyYAML, curl(스텁), 기존 assert 하니스(`tests/lib.sh`).

**참고 spec:** `docs/superpowers/specs/2026-05-18-homelab-ops-hardening-design.md`

**구현 순서(바텀업):** D(테이블) → C(유령 verb) → A·B(폴링·감사·phase1) → 인벤토리 발견 → backup. 각 Task는 끝나면 전체 `tests/run.sh`가 녹색이어야 한다(중간 커밋도 회귀 없음).

**경로 주의:** 모든 명령은 repo 루트 `/home/altair823/claude-skills` 에서 실행. 스킬 코드는 `homelab-ops/` 하위. 테스트는 `cd homelab-ops` 후 실행한다.

---

### Task 1: 단일 액션 테이블 + lib 헬퍼 (`_lib.sh`)

D의 토대. grade·transport 단일 출처를 `_lib.sh`에 추가하고 `op_transport`를 테이블 조회로 재작성한다. **`backup`은 아직 테이블에 넣지 않는다**(backend arm이 Task 10에서 추가되므로, 그 전까지 테이블에 있으면 Task 3 패리티 테스트가 실패). `delete`→`destroy` 별칭은 지금 추가.

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (현재 `op_transport` 정의: 51-65행)
- Modify: `homelab-ops/tests/test_lib.sh` (probe 케이스 추가)

- [ ] **Step 1: `_lib.sh`에 테이블 + 헬퍼 추가**

`homelab-ops/bin/_lib.sh`의 기존 `op_transport()` 함수(51-65행, 주석 포함 전체)를 아래로 **교체**한다:

```bash
# ── Single source of truth: action → "<grade> <transport>" ───────────────
#   grade:     safe | caution | destructive
#   transport: none | pve | ssh | guest
#     guest = 대상 kind 가 proxmox-host/vm/lxc 면 pve, 그 외(appliance 등)면 ssh
# guard(등급)·_backend(라우팅)·op_transport(자격)·--plan 이 모두 이 테이블만
# 본다. drift 는 tests/test_action_table.sh 패리티 테스트가 차단한다(과거의
# "3곳 수동 동기" 주석 계약을 대체). 새 verb 는 여기 + backend + (필요시)
# bin/pve verb arm 을 함께 추가하고 패리티 테스트가 녹색인지 확인할 것.
declare -gA ACTIONS=(
  [status]="safe none"        [list]="safe none"      [metrics]="safe none"
  [get]="safe none"           [inventory]="safe none"
  [start]="caution guest"     [stop]="caution guest"  [restart]="caution guest"
  [snapshot]="caution guest"  [pkg-install]="caution ssh"
  [provision]="destructive pve"  [destroy]="destructive guest"
)
declare -gA ACTION_ALIASES=( [delete]="destroy" )

# canon_action <action> -> 별칭 해소(없으면 입력 그대로). 미지의 액션은
# 그대로 통과시켜 deny-by-default 가 등급/거부를 책임진다.
canon_action() {
  local a="${1:?canon_action: action required}"
  echo "${ACTION_ALIASES[$a]:-$a}"
}

# action_grade <action> -> safe|caution|destructive (deny-by-default).
# critical 승급은 적용하지 않는다 — 그건 target 이 필요하므로 guard 소관.
action_grade() {
  local a; a="$(canon_action "${1:?action_grade: action required}")"
  local spec="${ACTIONS[$a]:-}"
  if [[ -n "$spec" ]]; then echo "${spec%% *}"; else echo destructive; fi
}

# op_transport <action> <kind> -> pve | ssh | none  (테이블 둘째 토큰 해석)
op_transport() {
  local a; a="$(canon_action "${1:?op_transport: action required}")"
  local kind="${2:-}" spec t
  spec="${ACTIONS[$a]:-}"
  if [[ -z "$spec" ]]; then echo none; return; fi
  t="${spec##* }"
  case "$t" in
    none|pve|ssh) echo "$t" ;;
    guest) case "$kind" in proxmox-host|vm|lxc) echo pve ;; *) echo ssh ;; esac ;;
    *) echo none ;;
  esac
}
```

`owner_host()` 함수(현재 67-77행)는 **변경하지 않는다**.

- [ ] **Step 2: test_lib.sh에 grade/canon 단언 추가, 실패 확인**

`homelab-ops/tests/test_lib.sh`의 probe heredoc `case "$1" in` 블록(9-18행) 안, `owner)` 라인 다음에 두 줄 추가:

```bash
  grade) action_grade "$2" ;;
  canon) canon_action "$2" ;;
```

그리고 `transport ... unknown action → none` 단언(57행) 다음에 추가:

```bash
assert_eq "safe"        "$(bash bin/_libprobe.sh grade status)"   "action_grade status → safe"
assert_eq "caution"     "$(bash bin/_libprobe.sh grade stop)"     "action_grade stop → caution"
assert_eq "destructive" "$(bash bin/_libprobe.sh grade destroy)"  "action_grade destroy → destructive"
assert_eq "destructive" "$(bash bin/_libprobe.sh grade delete)"   "action_grade delete (alias) → destructive"
assert_eq "destructive" "$(bash bin/_libprobe.sh grade frobnicate)" "unknown action → destructive (deny-default)"
assert_eq "destroy"     "$(bash bin/_libprobe.sh canon delete)"   "canon_action delete → destroy"
assert_eq "frob"        "$(bash bin/_libprobe.sh canon frob)"     "canon_action unknown → passthrough"
```

Run: `cd homelab-ops && bash tests/test_lib.sh`
Expected: FAIL — 새 단언이 `bin/_libprobe.sh`의 옛 복사본을 쓰면 `grade`/`canon` 케이스 없음(빈 출력). (test_lib.sh가 매 실행 시 `/tmp/_libprobe.sh`를 새로 만드므로 실제로는 Step 1 적용 후 통과. 이 Step은 단언을 먼저 추가해 두는 단계 — 다음 Step에서 통과 확인.)

- [ ] **Step 3: 테스트 통과 확인 (기존 transport/owner 단언 회귀 없음 포함)**

Run: `cd homelab-ops && bash tests/test_lib.sh`
Expected: PASS — `PASS test_lib`. 특히 기존 단언이 그대로 통과해야 함:
`transport status proxmox-host → none`, `transport stop vm → pve`,
`transport destroy proxmox-host → pve`, `transport stop appliance → ssh`,
`transport pkg-install vm → ssh`, `transport provision proxmox-host → pve`,
`transport frobnicate vm → none`, `owner vm-100 → pve-01`,
`owner lab-vm-900 → lab-vm-900`.

- [ ] **Step 4: 커밋**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_lib.sh homelab-ops/tests/test_lib.sh
git commit -m "feat(homelab-ops): _lib.sh 단일 액션 테이블 + canon/action_grade, op_transport 테이블화"
```

---

### Task 2: guard를 테이블에 연결 (`GRADE[]` 제거 + 별칭 정규화)

`bin/guard`의 로컬 `GRADE[]`를 제거하고 `action_grade`를 쓰며, 실행 경로에서 입력 액션을 `canon_action`으로 정규화(별칭 `delete`→`destroy`가 동일 등급·경로·감사로 흐르게).

**Files:**
- Modify: `homelab-ops/bin/guard` (`GRADE[]` 5-10행, `guard_grade` 14-29행, main case 71-73행 부근)
- Modify: `homelab-ops/tests/test_guard_grade.sh`

- [ ] **Step 1: test_guard_grade.sh에 별칭/유령verb 단언 추가**

`homelab-ops/tests/test_guard_grade.sh`의 `provision = destructive` 단언(20행) 다음에 추가:

```bash
# delete 는 destroy 의 별칭 → 동일 등급
assert_eq "destructive" "$(bin/guard grade delete vm-100)" "delete (alias) = destructive"
assert_eq "destructive" "$(bin/guard grade delete pve-01)" "delete on critical stays destructive"
# 유령 verb 는 테이블에 없음 → deny-default destructive (광고 제거돼도 안전 거부)
assert_eq "destructive" "$(bin/guard grade kill vm-100)"          "kill = destructive (deny-default)"
assert_eq "destructive" "$(bin/guard grade net-change vm-100)"    "net-change = destructive (deny-default)"
assert_eq "destructive" "$(bin/guard grade storage-remove nas-01)" "storage-remove = destructive (deny-default)"
```

Run: `cd homelab-ops && bash tests/test_guard_grade.sh`
Expected: FAIL — `delete (alias) = destructive` 등에서 현재 guard `GRADE[]`에 `delete`가 destructive로 직접 등록돼 통과할 수도 있으나, `kill`도 `GRADE[]`에 destructive로 있어 통과. **이 Step의 목적은 단언을 먼저 두는 것** — Step 3에서 테이블 기반으로 바뀐 뒤에도 녹색임을 보장.

- [ ] **Step 2: guard에서 GRADE[] 제거, action_grade 사용, 별칭 정규화**

`homelab-ops/bin/guard`에서 `declare -A GRADE=( ... )` 블록(5-10행 전체)을 **삭제**한다. `_bump()`(12행)는 **유지**.

`guard_grade()` 내부에서 등급 산출 라인을 교체한다. 현재(18행 부근):

```bash
  g="${GRADE[$action]:-destructive}"           # deny-by-default
```

를 아래로 교체:

```bash
  g="$(action_grade "$action")"                # deny-by-default (단일 테이블)
```

다음으로, main `*)` 분기에서 액션 파싱 직후 정규화한다. 현재(72-74행):

```bash
  *)
    action="$1"; target="${2:-}"
    [[ -n "$target" ]] || die "usage: guard <action> <target-id> [--approve] [-- <extra>...]"
    shift 2
```

를 아래로 교체:

```bash
  *)
    action="$1"; target="${2:-}"
    [[ -n "$target" ]] || die "usage: guard <action> <target-id> [--approve] [-- <extra>...]"
    shift 2
    orig_action="$action"
    action="$(canon_action "$action")"   # 별칭(delete→destroy) 정규화: 등급·경로·감사 일관
```

그리고 pre-op 스냅샷 헤더(현재 172행 `echo "=== pre-op snapshot $(date -u +%FT%TZ) op=$op ==="`)를 아래로 교체(입력 별칭 흔적을 run-log 헤더에만 남김):

```bash
      echo "=== pre-op snapshot $(date -u +%FT%TZ) op=$op action=$orig_action(→$action) ==="
```

- [ ] **Step 3: 테스트 통과 확인**

Run: `cd homelab-ops && bash tests/test_guard_grade.sh`
Expected: PASS — `PASS test_guard_grade`. 기존 단언(`status pve-01 → safe`, `stop nas-01 → destructive` 등) + 새 별칭/유령verb 단언 모두 녹색.

- [ ] **Step 4: guard 실행 경로 회귀 확인**

Run: `cd homelab-ops && bash tests/test_guard_exec.sh && bash tests/test_guard_plan.sh && bash tests/test_guard_signal.sh`
Expected: PASS ×3. 특히 `test_guard_exec.sh`의 `kill pve-01` 시나리오는 deny-default(destructive+transport-none)로 여전히 exit 10을 내야 한다.

- [ ] **Step 5: 커밋**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/guard homelab-ops/tests/test_guard_grade.sh
git commit -m "feat(homelab-ops): guard 를 단일 테이블에 연결 + delete→destroy 별칭 정규화"
```

---

### Task 3: 패리티 테스트 (드리프트 차단)

테이블↔backend 정합을 CI가 강제. 과거의 "수동 동기" 주석 계약을 대체.

**Files:**
- Create: `homelab-ops/tests/test_action_table.sh`

- [ ] **Step 1: 패리티 테스트 작성**

`homelab-ops/tests/test_action_table.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_backend 2>/dev/null || true
export PVE_TOKEN="stub-token-value"

# 테이블을 셸로 로드해 키를 열거 (probe 패턴 재사용).
cat > /tmp/_tblprobe.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
case "$1" in
  keys)    for k in "${!ACTIONS[@]}"; do echo "$k ${ACTIONS[$k]}"; done ;;
  aliases) for k in "${!ACTION_ALIASES[@]}"; do echo "$k ${ACTION_ALIASES[$k]}"; done ;;
esac
EOF
cp /tmp/_tblprobe.sh bin/_tblprobe.sh
trap 'rm -f bin/_tblprobe.sh' EXIT

# Direction 1: 모든 비-safe 액션은 backend 에서 라우팅되어 "no backend
# mapping" 으로 떨어지지 않는다 (dry-run 안전 계약 하에).
while read -r act grade _trans; do
  [[ "$grade" == "safe" ]] && continue
  o="$(bin/_backend "$act" vm-100 --dry-run -- probe-arg 2>&1 || true)"
  assert_not_contains "$o" "no backend mapping for action '$act'" \
    "table action '$act' is backend-routed"
done < <(bash bin/_tblprobe.sh keys)

# Direction 2: backend 가 디스패치하는 모든 mutating verb 는 테이블에 있다.
tbl_keys="$(bash bin/_tblprobe.sh keys | awk '{print $1}' | sort -u)"
backend_verbs="$(grep -oE '[a-z][a-z-]*:\*' bin/_backend | sed 's/:\*$//' | sort -u)"
for v in $backend_verbs; do
  case " $tbl_keys " in
    *" $v "*) echo "  ok: backend verb '$v' present in ACTIONS" ;;
    *) echo "  FAIL: backend verb '$v' missing from ACTIONS table"; exit 1 ;;
  esac
done

# Direction 3: 모든 별칭은 실재하는 ACTIONS 키를 가리킨다.
while read -r alias target; do
  case " $tbl_keys " in
    *" $target "*) echo "  ok: alias '$alias'→'$target' targets a real action" ;;
    *) echo "  FAIL: alias '$alias' targets non-existent action '$target'"; exit 1 ;;
  esac
done < <(bash bin/_tblprobe.sh aliases)

finish; echo "PASS test_action_table"
```

- [ ] **Step 2: 테스트 실행, 통과 확인**

Run: `cd homelab-ops && bash tests/test_action_table.sh`
Expected: PASS — `PASS test_action_table`. (이 시점 ACTIONS = status/list/metrics/get/inventory/start/stop/restart/snapshot/pkg-install/provision/destroy. backend_verbs = status/metrics/get/start/stop/restart/destroy/snapshot/pkg-install/provision. 모든 backend verb ∈ 테이블; 모든 비-safe 테이블 키가 라우팅됨; 별칭 delete→destroy 존재.)

- [ ] **Step 3: 커밋**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/tests/test_action_table.sh
git commit -m "test(homelab-ops): 액션 테이블↔backend 패리티 테스트 (주석 동기 계약 대체)"
```

---

### Task 4: C — SKILL.md 광고 정정 + TODO.md 후속 항목

유령 verb는 Task 2/3에서 deny-default로 안전 처리됨이 검증됐다. 남은 건 광고 문구를 실제 지원과 일치시키는 문서 작업.

**Files:**
- Modify: `homelab-ops/SKILL.md` (76행 "When to use" 불릿)
- Modify: `homelab-ops/TODO.md`

- [ ] **Step 1: SKILL.md "When to use" 정정**

`homelab-ops/SKILL.md` 76행:

```
- "Destroy/delete/storage/network change" → `"$HL/bin/guard" <verb> <id>` → show the DRY-RUN/impact → re-run with `--approve`
```

를 아래로 교체:

```
- "Destroy/delete X" → `"$HL/bin/guard" destroy <id>` (`delete` = `destroy` 별칭) → show the DRY-RUN/impact → re-run with `--approve`
- storage/network 변경은 **미지원**(Phase 2 후보). 임의 verb 를 던지면 deny-by-default 가 destructive 로 거부한다.
```

- [ ] **Step 2: TODO.md 후속 항목 상태 갱신**

`homelab-ops/TODO.md` 끝에 절 추가:

```markdown

## 진행 상태 (2026-05-18 하드닝 spec)
- guard task 폴링·단일 테이블·유령 verb 정리·인벤토리 발견·`backup` verb 는
  `docs/superpowers/specs/2026-05-18-homelab-ops-hardening-design.md` 로 처리.
- `disk-attach`/`disk-detach`: 코드 경로(#25 SSH 전송)는 구비. **선행 블로커**:
  vault 에 노드 root SSH 키 `bw-put --type note --from-file` 등록 (데이터 작업).
- `remote-migrate`: SKILL.md "Not for: …migration" 정책 변경 결정이 선행.
```

- [ ] **Step 3: 회귀 확인 후 커밋**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`

```bash
cd /home/altair823/claude-skills
git add homelab-ops/SKILL.md homelab-ops/TODO.md
git commit -m "docs(homelab-ops): 광고를 실제 지원과 일치(유령 verb 제거) + TODO 후속 상태"
```

---

### Task 5: `pve_wait_task` 헬퍼 + task-aware 기본 curl 스텁

A·B 토대. PVE task 완료를 폴링하는 단일 출처 헬퍼. 기본 curl 스텁을 task-aware로 만들어 폴링 도입이 다른 테스트를 깨지 않게 한다(스텁은 항상 성공 경로; 실패/타임아웃은 Step의 전용 스텁으로).

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (`owner_host` 다음에 함수 추가)
- Modify: `homelab-ops/tests/stubs/curl`
- Create: `homelab-ops/tests/test_pve_wait.sh`

- [ ] **Step 1: `pve_wait_task` 추가**

`homelab-ops/bin/_lib.sh` 파일 **맨 끝**(`owner_host` 함수 닫는 `}` 다음)에 추가:

```bash

# pve_wait_task <host_id> <upid> -> 0: task exitstatus OK / 1: not OK /
# 75: HOMELAB_TASK_TIMEOUT(기본 600s) 내 미완료. 마지막에 guard 감사 캡처용
# 구조화 라인을 stdout 으로 emit: `HO-TASK upid=<upid> exitstatus=<status>`.
# 상태는 bin/pve 의 api GET 로 폴링(토큰·CA 는 bin/pve 가 재사용; 여기서 시크릿
# 미취급). 폴링 간격은 정수초 HOMELAB_TASK_POLL_INTERVAL(기본 2, 테스트
# 가속용 override).
pve_wait_task() {
  local host="${1:?pve_wait_task: host required}"
  local upid="${2:?pve_wait_task: upid required}"
  local timeout="${HOMELAB_TASK_TIMEOUT:-600}"
  local interval="${HOMELAB_TASK_POLL_INTERVAL:-2}"
  local waited=0 resp st xs
  while :; do
    resp="$("$REPO_ROOT/bin/pve" "$host" api GET "/nodes/${host}/tasks/${upid}/status" 2>/dev/null || true)"
    st="$(jq -r '.data.status // empty' <<<"$resp" 2>/dev/null || true)"
    if [[ "$st" == "stopped" ]]; then
      xs="$(jq -r '.data.exitstatus // "UNKNOWN"' <<<"$resp" 2>/dev/null || echo UNKNOWN)"
      printf 'HO-TASK upid=%s exitstatus=%s\n' "$upid" "$xs"
      [[ "$xs" == "OK" ]] && return 0 || return 1
    fi
    if (( waited >= timeout )); then
      printf 'HO-TASK upid=%s exitstatus=%s\n' "$upid" "TIMEOUT"
      return 75
    fi
    sleep "$interval"
    waited=$(( waited + interval ))
  done
}
```

- [ ] **Step 2: 기본 curl 스텁을 task-aware로 교체**

`homelab-ops/tests/stubs/curl` 전체를 아래로 교체:

```bash
#!/usr/bin/env bash
# Offline Proxmox 스텁. task-aware:
#  - GET .../tasks/<upid>/status      → 즉시 stopped/OK (폴링 성공 경로)
#  - POST/DELETE 비동기 변형 엔드포인트 → UPID 문자열 반환
#  - 그 외(GET /nodes, status, vm-config, clone 외 read) → running 블롭
args="$*"
method="GET"
case "$args" in *" -X "*) method="$(sed -E 's/.* -X ([A-Z]+).*/\1/' <<<"$args")";; esac
url="$(tr ' ' '\n' <<<"$args" | grep -m1 '^https://' || true)"

if [[ "$url" == *"/tasks/"*"/status"* ]]; then
  echo '{"data":{"status":"stopped","exitstatus":"OK"}}'
elif [[ "$method" == "POST" || "$method" == "DELETE" ]] && \
     { [[ "$url" == *"/status/start"*  ]] || [[ "$url" == *"/status/stop"* ]] || \
       [[ "$url" == *"/status/reboot"* ]] || [[ "$url" == *"/snapshot"*    ]] || \
       [[ "$url" == *"/vzdump"*        ]] || [[ "$url" == *"/clone"*       ]] || \
       [[ "$url" == *"/qemu/"* && "$method" == "DELETE" ]] || \
       [[ "$url" == *"/lxc/"*  && "$method" == "DELETE" ]]; }; then
  echo '{"data":"UPID:stub:0000FFFF:00000000:00000000:stubtype:0:root@pam:"}'
else
  echo '{"data":{"status":"running","vmid":100,"name":"stub-vm"}}'
fi
```

- [ ] **Step 3: pve_wait_task 단위 테스트 작성**

`homelab-ops/tests/test_pve_wait.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export PVE_TOKEN="stub-token-value"

cat > /tmp/_waitprobe.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
pve_wait_task "$1" "$2"
EOF
cp /tmp/_waitprobe.sh bin/_waitprobe.sh
trap 'rm -f bin/_waitprobe.sh' EXIT
U="UPID:stub:1:1:1:t:0:root@pam:"

# 성공: 기본 task-aware 스텁은 tasks/status 에 stopped/OK 반환
out="$(bash bin/_waitprobe.sh pve-01 "$U")"; rc=$?
assert_eq "0" "$rc" "OK task → exit 0"
assert_contains "$out" "HO-TASK upid=$U exitstatus=OK" "emits HO-TASK OK line"

# 실패 exitstatus: 전용 스텁 디렉터리로 교체
errd="$(mktemp -d)"
cat > "$errd/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"stopped","exitstatus":"err: volume busy"}}'
EOF
chmod +x "$errd/curl"
set +e
out="$(PATH="$errd:$PATH" bash bin/_waitprobe.sh pve-01 "$U")"; rc=$?
set -e
assert_eq "1" "$rc" "non-OK exitstatus → exit 1"
assert_contains "$out" "exitstatus=err: volume busy" "HO-TASK carries the error exitstatus"
rm -rf "$errd"

# 타임아웃: 항상 running + HOMELAB_TASK_TIMEOUT=0 → 즉시 75
runp="$(mktemp -d)"
cat > "$runp/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"running"}}'
EOF
chmod +x "$runp/curl"
set +e
out="$(HOMELAB_TASK_TIMEOUT=0 PATH="$runp:$PATH" bash bin/_waitprobe.sh pve-01 "$U")"; rc=$?
set -e
assert_eq "75" "$rc" "timeout → exit 75"
assert_contains "$out" "exitstatus=TIMEOUT" "HO-TASK records TIMEOUT, upid preserved"
assert_contains "$out" "upid=$U" "timeout HO-TASK preserves upid"
rm -rf "$runp"

# running→stopped 전이: 카운터 스텁, 정수 간격 1s
trd="$(mktemp -d)"
cat > "$trd/curl" <<'EOF'
#!/usr/bin/env bash
c="${TMP_TR:-/tmp/_tr_count}"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
if (( n >= 2 )); then echo '{"data":{"status":"stopped","exitstatus":"OK"}}'
else echo '{"data":{"status":"running"}}'; fi
EOF
chmod +x "$trd/curl"
: > /tmp/_tr_count
set +e
out="$(HOMELAB_TASK_POLL_INTERVAL=1 TMP_TR=/tmp/_tr_count PATH="$trd:$PATH" bash bin/_waitprobe.sh pve-01 "$U")"; rc=$?
set -e
assert_eq "0" "$rc" "running→stopped → eventual exit 0"
rm -rf "$trd" /tmp/_tr_count

finish; echo "PASS test_pve_wait"
```

- [ ] **Step 4: 실행 + 회귀 확인**

Run: `cd homelab-ops && bash tests/test_pve_wait.sh && bash tests/run.sh`
Expected: `PASS test_pve_wait` 그리고 `ALL TESTS PASSED`. (이 시점 `bin/pve`는 아직 폴링 안 함 → 기본 스텁 변경은 기존 테스트 결과를 바꾸지 않음: GET /nodes·status·vm-config 는 여전히 running 블롭.)

- [ ] **Step 5: 커밋**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_lib.sh homelab-ops/tests/stubs/curl homelab-ops/tests/test_pve_wait.sh
git commit -m "feat(homelab-ops): pve_wait_task 폴링 헬퍼 + task-aware 기본 curl 스텁"
```

---

### Task 6: `bin/pve` mutating verb를 폴링에 연결

start/stop/restart/snapshot/destroy가 UPID를 받으면 완료까지 폴링하고 그 결과를 exit으로 전파.

**Files:**
- Modify: `homelab-ops/bin/pve` (`call()` 다음에 `_run_task` 추가; `action` verb arm 62-69행)
- Modify: `homelab-ops/tests/test_pve.sh` (spy를 task-aware로)

- [ ] **Step 1: test_pve.sh의 inline spy를 task-aware로, 폴링 단언 추가**

`homelab-ops/tests/test_pve.sh`에서 `/tmp/curl-spy` heredoc(19-23행)을 아래로 교체:

```bash
cat > /tmp/curl-spy <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/curl-args
a="$*"
if [[ "$a" == *"/tasks/"*"/status"* ]]; then
  echo '{"data":{"status":"stopped","exitstatus":"OK"}}'
elif [[ "$a" == *"-X POST"* || "$a" == *"-X DELETE"* ]]; then
  echo '{"data":"UPID:stub:1:1:1:t:0:root@pam:"}'
else
  echo '{"data":{"status":"running"}}'
fi
EOF
```

그리고 `lxc action → /lxc/<vmid>` 단언(39-42행) 다음에 추가:

```bash
# mutating verb 가 UPID 를 받으면 task status 를 폴링한다(HO-TASK emit).
out="$(PATH="/tmp/spybin:$PWD/tests/stubs:$PATH" bin/pve pve-01 action stop vm-100)"
assert_contains "$out" "HO-TASK upid=UPID:stub" "pve mutating verb polls task to completion"
grep -q -- '/nodes/pve-01/qemu/100/tasks/UPID' /tmp/curl-args \
  && echo "  ok: task status polled via api GET" \
  || { echo "  FAIL: task status not polled: $(cat /tmp/curl-args)"; exit 1; }
```

- [ ] **Step 2: 실패 확인**

Run: `cd homelab-ops && bash tests/test_pve.sh`
Expected: FAIL — `HO-TASK upid=UPID:stub` 미출력(아직 `bin/pve`가 폴링 안 함).

- [ ] **Step 3: `bin/pve`에 `_run_task` 추가 + verb arm 연결**

`homelab-ops/bin/pve`의 `call()` 함수 닫는 `}`(44행) 다음에 추가:

```bash

# 비동기 변형: UPID 를 받으면 응답을 출력한 뒤 완료까지 폴링.
# host_id 는 이 스크립트 스코프 변수 (5행에서 설정).
_run_task() { # METHOD path [data]
  local resp upid crc=0
  resp="$(call "$@")" || crc=$?
  printf '%s\n' "$resp"
  (( crc != 0 )) && return "$crc"
  upid="$(jq -r 'if (.data|type)=="string" then .data else empty end' <<<"$resp" 2>/dev/null || true)"
  if [[ "$upid" == UPID:* ]]; then pve_wait_task "$host_id" "$upid"; return $?; fi
  return 0
}
```

그리고 `action` verb의 `case "$verb" in` 블록(62-69행)을 아래로 교체:

```bash
    case "$verb" in
      start)    _run_task POST "/nodes/${host_id}/${api_kind}/${vmid}/status/start" ;;
      stop)     _run_task POST "/nodes/${host_id}/${api_kind}/${vmid}/status/stop" ;;
      restart)  _run_task POST "/nodes/${host_id}/${api_kind}/${vmid}/status/reboot" ;;
      snapshot) _run_task POST "/nodes/${host_id}/${api_kind}/${vmid}/snapshot" "snapname=ho-$(date +%s)-$RANDOM" ;;
      destroy)  _run_task DELETE "/nodes/${host_id}/${api_kind}/${vmid}" ;;
      *) die "pve: unknown action verb $verb" ;;
    esac ;;
```

- [ ] **Step 4: 테스트 통과 확인 + pve 회귀**

Run: `cd homelab-ops && bash tests/test_pve.sh`
Expected: PASS — `PASS test_pve`. 기존 단언(api json, status convenience, TLS on, action 경로, ca_path) + 새 폴링 단언 모두 녹색.

- [ ] **Step 5: 전체 회귀**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (특히 `test_guard_exec`는 fake backend 사용 → 폴링 무관, `test_provision` apply 는 기본 task-aware 스텁으로 clone→UPID→폴링 성공).

- [ ] **Step 6: 커밋**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/pve homelab-ops/tests/test_pve.sh
git commit -m "feat(homelab-ops): bin/pve mutating verb 가 PVE task 완료를 폴링(감사=결과)"
```

---

### Task 7: guard 감사 레코드에 `task_upid`·`task_exitstatus` 추가

backend 출력의 `HO-TASK` 라인을 run-log에서 파싱해 감사 레코드에 추가 필드로 보존(추가 전용, 하위호환).

**Files:**
- Modify: `homelab-ops/bin/guard` (init 86행 부근, `_audit()` 89-102행, 최종 audit 직전 207행 부근)
- Create: `homelab-ops/tests/test_guard_task_audit.sh`

- [ ] **Step 1: guard에 필드 init + 캡처 + _audit 확장**

`homelab-ops/bin/guard`의 init 라인(현재 86-87행):

```bash
    grade="unknown"; env_t="unknown"; tags_t="[]"
    inv_json="null"; approver="null"; approved_at="null"; dryrun_hash="null"
```

뒤에 추가:

```bash
    task_upid=""; task_xs=""
```

`_audit()` 함수의 `audit_append \` 인자 목록에서 `--argjson dur "$((end_ms-start_ms))" '` 라인을 아래 2줄로 교체:

```bash
        --arg tu "$task_upid" --arg tx "$task_xs" \
        --argjson dur "$((end_ms-start_ms))" '
```

그리고 JSON 객체 필터에서 `exit:$ex,duration_ms:$dur}'` 를 아래로 교체:

```bash
         exit:$ex,duration_ms:$dur,
         task_upid:($tu|if .=="" then null else . end),
         task_exitstatus:($tx|if .=="" then null else . end)}'
```

최종 실행 후 rc 산출 직후(현재 203-205행 `rc="$(cat ...)"; rm -f "$_rc_file"; set -e` 다음, `_DONE=1` 207행 앞)에 추가:

```bash
    task_upid="$(sed -n 's/^HO-TASK upid=\([^ ]*\).*/\1/p' "$rl" 2>/dev/null | tail -n1 || true)"
    task_xs="$(sed -n 's/^HO-TASK .*exitstatus=\(.*\)$/\1/p' "$rl" 2>/dev/null | tail -n1 || true)"
```

- [ ] **Step 2: 감사 필드 통합 테스트 작성**

`homelab-ops/tests/test_guard_task_audit.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard 2>/dev/null || true
export HOMELAB_SESSION_ID="task-audit-sess"
export PVE_TOKEN="stub-token-value"
export HOMELAB_BACKEND=""        # 실제 _backend → bin/pve → task-aware 스텁
: > logs/audit.jsonl
rm -rf "logs/runs/$HOMELAB_SESSION_ID"

# lab-vm-900: vm/lab → caution+lab, 승인 불필요. guest→pve 전송.
out="$(bin/guard stop lab-vm-900)"
rec="$(tail -1 logs/audit.jsonl)"
assert_eq "stop" "$(jq -r .action <<<"$rec")" "action recorded"
assert_eq "0"    "$(jq -r .exit   <<<"$rec")" "OK task → exit 0 audited"
[[ "$(jq -r .task_upid <<<"$rec")" == UPID:* ]] && echo "  ok: task_upid captured" \
  || { echo "  FAIL: task_upid not captured: $rec"; exit 1; }
assert_eq "OK" "$(jq -r .task_exitstatus <<<"$rec")" "task_exitstatus OK captured"

# 별칭 정규화: guard delete → 감사 action 은 destroy
: > logs/audit.jsonl
bin/guard delete lab-vm-900 --approve >/dev/null 2>&1 || true
assert_eq "destroy" "$(tail -1 logs/audit.jsonl | jq -r .action)" "delete alias audited as destroy"

# fake backend 경로(HO-TASK 없음)는 필드가 null 이고 JSON 유효
export HOMELAB_BACKEND=/tmp/fake-nb
cat > /tmp/fake-nb <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *--dry-run* ]] && { echo "DRYRUN"; exit 0; }
echo "no task here"; exit 0
EOF
chmod +x /tmp/fake-nb
: > logs/audit.jsonl
bin/guard stop lab-vm-900 >/dev/null 2>&1 || true
rec="$(tail -1 logs/audit.jsonl)"
jq -e . >/dev/null <<<"$rec" && echo "  ok: audit record is valid JSON without HO-TASK" \
  || { echo "  FAIL: invalid audit JSON"; exit 1; }
assert_eq "null" "$(jq -r '.task_upid // "null"' <<<"$rec")" "no HO-TASK → task_upid null"

finish; echo "PASS test_guard_task_audit"
```

- [ ] **Step 3: 실행 + 회귀 (기존 감사 테스트 하위호환)**

Run: `cd homelab-ops && bash tests/test_guard_task_audit.sh && bash tests/test_guard_exec.sh && bash tests/test_forensic_sufficiency.sh`
Expected: PASS ×3 (`test_guard_exec`/`test_forensic_sufficiency`는 새 필드를 검사하지 않으므로 추가 전용 변경에 영향 없음; 레코드는 여전히 유효 JSON).

- [ ] **Step 4: 전체 회귀 + 커밋**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/guard homelab-ops/tests/test_guard_task_audit.sh
git commit -m "feat(homelab-ops): 감사 레코드에 task_upid·task_exitstatus (수락 아닌 결과 기록)"
```

---

### Task 8: `provisioning/phase1` clone 폴링 (거짓 CREATED 제거)

clone task 완료·성공 확인 후에만 `CREATED:` 출력.

**Files:**
- Modify: `homelab-ops/provisioning/phase1` (apply 분기 37-42행)
- Modify: `homelab-ops/tests/test_provision.sh`

- [ ] **Step 1: test_provision.sh에 실패-clone 단언 추가**

`homelab-ops/tests/test_provision.sh`의 `apply performs clone` 단언(20-22행) 다음에 추가:

```bash
# clone task 가 실패하면 phase1 은 CREATED 를 찍지 않고 비-0 종료
faild="$(mktemp -d)"
cat > "$faild/curl" <<'EOF'
#!/usr/bin/env bash
a="$*"
if [[ "$a" == *"/tasks/"*"/status"* ]]; then
  echo '{"data":{"status":"stopped","exitstatus":"clone failed: no space"}}'
else echo '{"data":"UPID:stub:1:1:1:qmclone:0:root@pam:"}'; fi
EOF
chmod +x "$faild/curl"
set +e
o="$(PATH="$faild:$PWD/tests/stubs:$PATH" provisioning/phase1 apply pve-01 --from-template 9000 --new-vmid 951 2>&1)"; rc=$?
set -e
[[ "$rc" -ne 0 ]] && echo "  ok: failed clone task → nonzero" || { echo "  FAIL: failed clone returned 0"; exit 1; }
[[ "$o" != *"CREATED"* ]] && echo "  ok: no false CREATED on clone failure" || { echo "  FAIL: false CREATED"; exit 1; }
rm -rf "$faild"
```

- [ ] **Step 2: 실패 확인**

Run: `cd homelab-ops && bash tests/test_provision.sh`
Expected: FAIL — 현재 phase1은 clone 응답을 `>/dev/null`로 버리고 무조건 CREATED → 새 단언 실패.

- [ ] **Step 3: phase1 apply를 폴링으로 교체**

`homelab-ops/provisioning/phase1`의 apply 분기(37-42행 전체):

```bash
if [[ "$mode" == "apply" ]]; then
  "$BIN/pve" "$host" api POST "/nodes/${host}/qemu/${tmpl}/clone" "newid=${newid}&name=${name}" \
    >/dev/null || die "clone failed"
  echo "CREATED: vmid ${newid} (name=${name}) cloned from ${tmpl} on ${host}"
  exit 0
fi
```

를 아래로 교체:

```bash
if [[ "$mode" == "apply" ]]; then
  resp="$("$BIN/pve" "$host" api POST "/nodes/${host}/qemu/${tmpl}/clone" "newid=${newid}&name=${name}")" \
    || die "clone API call failed"
  upid="$(jq -r 'if (.data|type)=="string" then .data else empty end' <<<"$resp" 2>/dev/null || true)"
  [[ "$upid" == UPID:* ]] || die "clone did not return a task UPID: $resp"
  pve_wait_task "$host" "$upid" || die "clone task did not complete OK (vmid ${newid}); see HO-TASK line"
  echo "CREATED: vmid ${newid} (name=${name}) cloned from ${tmpl} on ${host}"
  exit 0
fi
```

(`phase1`은 7행에서 `../bin/_lib.sh`를 source 하므로 `pve_wait_task` 사용 가능.)

- [ ] **Step 4: 통과 + 회귀 확인**

Run: `cd homelab-ops && bash tests/test_provision.sh`
Expected: PASS — `PASS test_provision`. `dry-run` 단언은 불변(phase1 dry-run은 clone 미호출), `apply performs clone`는 기본 task-aware 스텁(clone→UPID, tasks/status→stopped/OK)으로 통과, 새 실패-clone 단언 통과.

- [ ] **Step 5: 전체 회귀 + 커밋**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`

```bash
cd /home/altair823/claude-skills
git add homelab-ops/provisioning/phase1 homelab-ops/tests/test_provision.sh
git commit -m "fix(homelab-ops): phase1 이 clone task 완료를 폴링 — 거짓 CREATED 제거"
```

---

### Task 9: 인벤토리 3단계 발견 (`bin/inv`)

`HOMELAB_INVENTORY_DIR` → `~/.config/homelab-ops` → repo `inventory/`. 첫 매치(=`fleet.yaml` 존재) 승. 셋 다 없으면 후보 경로 포함 명확한 에러.

**Files:**
- Modify: `homelab-ops/bin/inv` (6-8행 INV_DIR 결정)
- Modify: `homelab-ops/tests/test_inv.sh`

- [ ] **Step 1: test_inv.sh에 발견 우선순위 단언 추가**

`homelab-ops/tests/test_inv.sh`의 `override also redirects groups.yaml` 단언과 `rm -rf "$_tmpinv"`(46-47행) 다음에 추가:

```bash
# env 미설정: XDG(~/.config/homelab-ops) 자동 발견
_xdg="$(mktemp -d)"
mkdir -p "$_xdg/homelab-ops"
cat > "$_xdg/homelab-ops/fleet.yaml" <<'EOF'
- id: xdg-host
  kind: proxmox-host
  address: 10.7.7.7
  env: lab
EOF
echo '{}' > "$_xdg/homelab-ops/groups.yaml"
got="$(env -u HOMELAB_INVENTORY_DIR XDG_CONFIG_HOME="$_xdg" bin/inv list)"
assert_eq "xdg-host" "$got" "env unset → XDG ~/.config/homelab-ops auto-discovered"

# XDG 부재 + repo inventory/ 존재 → repo 로 폴백
_emptyxdg="$(mktemp -d)"
mkdir -p homelab-ops-inv-probe
# repo inventory/ 는 운영자-로컬·gitignored 라 없을 수 있으니 임시 생성/정리
_made_repo_inv=0
if [[ ! -f inventory/fleet.yaml ]]; then
  mkdir -p inventory
  cat > inventory/fleet.yaml <<'EOF'
- id: repo-host
  kind: proxmox-host
  address: 10.6.6.6
  env: lab
EOF
  echo '{}' > inventory/groups.yaml
  _made_repo_inv=1
fi
got="$(env -u HOMELAB_INVENTORY_DIR XDG_CONFIG_HOME="$_emptyxdg" bin/inv list)"
[[ -n "$got" ]] && echo "  ok: XDG absent → repo inventory/ fallback" \
  || { echo "  FAIL: repo fallback failed"; exit 1; }
[[ "$_made_repo_inv" -eq 1 ]] && rm -f inventory/fleet.yaml inventory/groups.yaml
rmdir homelab-ops-inv-probe 2>/dev/null || true

# 셋 다 부재 → 후보 경로를 담은 명확한 에러로 exit 1
errout="$(env -u HOMELAB_INVENTORY_DIR XDG_CONFIG_HOME="$_emptyxdg" HOME="$_emptyxdg" \
  bash -c 'cd "$1"; rm -f inventory/fleet.yaml; bin/inv list' _ "$PWD" 2>&1 || true)"
assert_contains "$errout" "homelab-ops" "no-inventory error mentions config path"
rm -rf "$_xdg" "$_emptyxdg"
```

> 주: repo `inventory/`는 gitignored·운영자-로컬이라 깨끗한 체크아웃엔 없음. 위 단언은 없으면 임시로 만들고 끝나면 지운다. "셋 다 부재" 단언은 `inventory/fleet.yaml`을 확실히 제거한 서브셸에서 검증.

- [ ] **Step 2: 실패 확인**

Run: `cd homelab-ops && bash tests/test_inv.sh`
Expected: FAIL — 현재 `bin/inv`는 env 미설정 시 무조건 repo `inventory/`만 봄 → XDG 자동 발견 단언 실패.

- [ ] **Step 3: `bin/inv` 발견 로직 교체**

`homelab-ops/bin/inv`의 INV_DIR 결정부(현재 6-8행):

```bash
INV_DIR="${HOMELAB_INVENTORY_DIR:-$REPO_ROOT/inventory}"
FLEET="$INV_DIR/fleet.yaml"
GROUPS_FILE="$INV_DIR/groups.yaml"
```

를 아래로 교체:

```bash
# 인벤토리 발견(첫 매치 승, 매치 = 그 디렉터리에 fleet.yaml 존재):
#  1. $HOMELAB_INVENTORY_DIR  — 명시 override(테스트 fixture 경로). 설정 시
#     무조건 사용(존재 검사 없이 — 명시 의도 존중; 부재면 y2j 가 명확히 실패).
#  2. ${XDG_CONFIG_HOME:-~/.config}/homelab-ops  — 운영자-로컬 정식 위치.
#  3. $REPO_ROOT/inventory  — 레거시·예시·테스트 호환.
_xdg_inv="${XDG_CONFIG_HOME:-$HOME/.config}/homelab-ops"
if [[ -n "${HOMELAB_INVENTORY_DIR:-}" ]]; then
  INV_DIR="$HOMELAB_INVENTORY_DIR"
elif [[ -f "$_xdg_inv/fleet.yaml" ]]; then
  INV_DIR="$_xdg_inv"
elif [[ -f "$REPO_ROOT/inventory/fleet.yaml" ]]; then
  INV_DIR="$REPO_ROOT/inventory"
else
  die "no inventory found. Tried: \$HOMELAB_INVENTORY_DIR (unset), $_xdg_inv/fleet.yaml, $REPO_ROOT/inventory/fleet.yaml — copy $REPO_ROOT/inventory/fleet.example.yaml (and groups.example.yaml) to $_xdg_inv/"
fi
FLEET="$INV_DIR/fleet.yaml"
GROUPS_FILE="$INV_DIR/groups.yaml"
```

- [ ] **Step 4: 통과 + 회귀 확인**

Run: `cd homelab-ops && bash tests/test_inv.sh`
Expected: PASS — `PASS test_inv`. 기존 `HOMELAB_INVENTORY_DIR overrides`(branch 1) 단언 불변 + 새 XDG/폴백/에러 단언 통과.

- [ ] **Step 5: 전체 회귀 + 커밋**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (run.sh가 `HOMELAB_INVENTORY_DIR=tests/fixtures` 설정 → branch 1 → 다른 테스트 영향 없음).

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/inv homelab-ops/tests/test_inv.sh
git commit -m "feat(homelab-ops): 인벤토리 3단계 발견(env→~/.config→repo)"
```

---

### Task 10: `backup` verb (vzdump)

테이블에 `backup` 추가 + `_backend` arm + `bin/pve backup` sub. caution·transport pve. vzdump도 UPID → `pve_wait_task` 재사용.

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (ACTIONS 테이블에 backup 추가)
- Modify: `homelab-ops/bin/_backend` (case에 `backup:*)` arm)
- Modify: `homelab-ops/bin/pve` (sub case에 `backup)`)
- Create: `homelab-ops/tests/test_backup.sh`

- [ ] **Step 1: 테이블에 backup 등록**

`homelab-ops/bin/_lib.sh`의 `ACTIONS` 배열에서 이 줄:

```bash
  [provision]="destructive pve"  [destroy]="destructive guest"
```

를 아래로 교체:

```bash
  [backup]="caution pve"
  [provision]="destructive pve"  [destroy]="destructive guest"
```

- [ ] **Step 2: `_backend`에 backup arm 추가**

`homelab-ops/bin/_backend`의 `pkg-install:*)` arm(31-35행) **앞**에 추가:

```bash
  backup:*)
    if [[ $dry -eq 1 ]]; then
      echo "DRY-RUN: would vzdump $target (vmid=$(jq -r '.vmid // "?"' <<<"$inv")) storage=${1:-<none>} mode=${2:-snapshot} compress=${3:-zstd}"; exit 0
    fi
    "$HERE/pve" "$(owner_host "$target")" backup "$target" "$@" ;;
```

- [ ] **Step 3: `bin/pve`에 backup sub 추가**

`homelab-ops/bin/pve`의 `case "$sub" in` 에서 `action)` arm(51행) **앞**에 추가:

```bash
  backup)
    tgt="${3:?target}"; storage="${4:?storage}"
    mode="${5:-snapshot}"; compress="${6:-zstd}"
    tinv="$("$HERE/inv" get "$tgt")" || die "pve: no such target: $tgt"
    vmid="$(jq -r '.vmid // empty' <<<"$tinv")"
    [[ -n "$vmid" ]] || die "pve backup: target '$tgt' has no vmid in inventory"
    _run_task POST "/nodes/${host_id}/vzdump" \
      "vmid=${vmid}&storage=${storage}&mode=${mode}&compress=${compress}" ;;
```

- [ ] **Step 4: backup 테스트 작성**

`homelab-ops/tests/test_backup.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend 2>/dev/null || true
export PVE_TOKEN="stub-token-value"

# 등급: backup = caution
assert_eq "caution" "$(bin/guard grade backup vm-100)" "backup graded caution"

# dry-run: 실행 없이 대상/스토리지/모드 출력, exit 0
out="$(bin/_backend backup vm-100 --dry-run -- local-zfs snapshot zstd)"
assert_contains "$out" "DRY-RUN: would vzdump vm-100" "backup dry-run announces target"
assert_contains "$out" "storage=local-zfs" "backup dry-run echoes storage"
assert_status 0 'bin/_backend backup vm-100 --dry-run -- local-zfs' "backup dry-run exits 0"

# caution+prod(vm-100) → 승인 없이는 exit 10 (dry-run 표시)
set +e; o="$(bin/guard backup vm-100 -- local-zfs 2>&1)"; rc=$?; set -e
assert_eq "10" "$rc" "backup on prod needs --approve"
assert_contains "$o" "DRY-RUN" "backup prod shows dry-run"

# caution+lab(lab-vm-900) + 승인 경로: vzdump POST + UPID 폴링
out="$(bin/guard backup lab-vm-900 -- local-zfs snapshot zstd)"
assert_contains "$out" "HO-TASK upid=UPID:stub" "backup polls vzdump task"

# 자격 게이트: backup transport=pve → PVE_TOKEN 없으면 exit 3
assert_status 3 'env -u PVE_TOKEN bin/guard backup lab-vm-900 -- local-zfs' "backup without PVE_TOKEN exits 3"

# --plan: backup → 소유 호스트 PVE_TOKEN ref
assert_eq "PVE_TOKEN=bw://Proxmox pve-01/api-token" "$(bin/guard --plan backup vm-100)" "backup --plan → owner PVE_TOKEN"

finish; echo "PASS test_backup"
```

- [ ] **Step 5: 실행 + 패리티/회귀 확인**

Run: `cd homelab-ops && bash tests/test_backup.sh && bash tests/test_action_table.sh && bash tests/run.sh`
Expected: `PASS test_backup`, `PASS test_action_table`(이제 backup이 테이블+backend 양쪽 → 패리티 통과), `ALL TESTS PASSED`.

- [ ] **Step 6: 커밋**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_lib.sh homelab-ops/bin/_backend homelab-ops/bin/pve homelab-ops/tests/test_backup.sh
git commit -m "feat(homelab-ops): backup verb (vzdump, caution/pve, UPID 폴링)"
```

---

### Task 11: SKILL.md 인벤토리·backup 문서화 + 최종 회귀

다음 세션의 Claude가 안내 없이 인벤토리 위치를 알도록 SKILL.md를 갱신하고, backup·task 폴링 동작을 문서화.

**Files:**
- Modify: `homelab-ops/SKILL.md`

- [ ] **Step 1: SKILL.md "First-time setup" + 발견 순서**

`homelab-ops/SKILL.md`의 "Inventory & TLS" 첫 불릿(현재 22-27행, `inventory/{fleet.yaml,groups.yaml}` 설명 ~ `HOMELAB_INVENTORY_DIR overrides...`)을 아래로 교체:

```
- **Inventory 발견 순서**(첫 매치 승, 매치=그 디렉터리에 `fleet.yaml`):
  1. `$HOMELAB_INVENTORY_DIR` (명시 override; 테스트가 `tests/fixtures/` 지정)
  2. `${XDG_CONFIG_HOME:-~/.config}/homelab-ops/` ← **운영자-로컬 정식 위치**
  3. `$REPO_ROOT/inventory/` (레거시·예시·테스트 호환)
  **First-time setup:** `inventory/{fleet,groups}.example.yaml` 를
  `~/.config/homelab-ops/{fleet,groups}.yaml` 로 복사해 편집(레포 밖이라
  백업 용이; repo `inventory/` 도 여전히 동작). 셋 다 없으면 `bin/inv` 가
  세 후보 경로를 출력하고 종료한다. A `proxmox-host` entry's `id` MUST
  equal the real PVE node name (API paths are `/nodes/<id>/...`).
```

- [ ] **Step 2: SKILL.md "When to use"에 backup + task 폴링 한 줄**

`homelab-ops/SKILL.md` "When to use" 절에서 `"Start/stop/restart/snapshot X"` 불릿 다음에 추가:

```
- "Back up X (vzdump)" → `"$HL/bin/guard" backup <id> -- <storage> [mode] [compress]` (caution; prod ⇒ `--approve`)
```

그리고 같은 절 끝(`"What happened..."` 불릿 다음)에 추가:

```
- PVE 변경(start/stop/restart/snapshot/destroy/backup/provision)은 task UPID
  완료까지 폴링되어 감사 `exit`/`task_exitstatus` 가 **실제 결과**를 반영한다
  (타임아웃 시 exit 75 + `task_upid` 보존). 기본 한도 `HOMELAB_TASK_TIMEOUT`
  600s.
```

- [ ] **Step 3: 전체 회귀 (모든 테스트)**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` — 다음 전부 PASS:
test_action_table, test_backup, test_forensic_sufficiency, test_forensics,
test_guard_exec, test_guard_grade, test_guard_plan, test_guard_signal,
test_guard_task_audit, test_harness, test_inv, test_lib, test_mask_parity,
test_provision, test_pve, test_pve_wait, test_ssh_run.

- [ ] **Step 4: spec 대비 커버리지 자체 점검**

`docs/superpowers/specs/2026-05-18-homelab-ops-hardening-design.md`를 다시 읽고 각 절이 Task로 커버되는지 확인:
D=Task1-3, C=Task2-4, A·B(pve_wait_task=T5, pve=T6, 감사=T7, phase1=T8),
인벤토리=Task9, backup=Task10, SKILL/TODO=Task4·11, 후속항목=Task4.
누락 발견 시 Task 추가 후 보완.

- [ ] **Step 5: 최종 커밋**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/SKILL.md
git commit -m "docs(homelab-ops): 인벤토리 발견 순서·backup·task 폴링 문서화"
```

---

## 완료 기준 (Definition of Done)

- `cd homelab-ops && bash tests/run.sh` → `ALL TESTS PASSED` (17개 테스트).
- 라우팅 등급/전송이 `_lib.sh` `ACTIONS` 단일 출처; 패리티 테스트가 드리프트 차단.
- `delete`는 `destroy` 별칭(등급·경로·감사 동일, 감사 `action`=`destroy`).
- 유령 verb(`kill`/`net-change`/`storage-remove`)는 deny-default destructive, SKILL.md 미광고.
- PVE 변경·clone·vzdump가 task 완료까지 폴링; 감사에 `task_upid`·`task_exitstatus`; 타임아웃 exit 75.
- `provisioning/phase1`이 clone 실패 시 `CREATED` 안 찍고 비-0.
- `bin/inv`가 `~/.config/homelab-ops` 자동 발견; 셋 다 없으면 후보 경로 에러; SKILL.md 명문화.
- `guard backup <id> -- <storage>` 동작(caution, prod=approve, UPID 폴링).
- 후속 항목(disk-attach/remote-migrate)이 블로커와 함께 TODO.md/spec에 기록.
