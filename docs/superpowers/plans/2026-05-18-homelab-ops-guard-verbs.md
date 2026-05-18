# homelab-ops guard verb 확장 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 단일 출처 `ACTIONS` 테이블에 transport 어휘 `host-ssh`·`pdm` 를 추가하고 그 위에 `disk-attach`/`disk-detach`/`disk-grow`/`remote-migrate` 4 verb + 인터럽트-UPID 캡처를 구현한다.

**Architecture:** 하드닝(PR#26)에서 확립된 "단일 출처 `_lib.sh` ACTIONS 테이블 + 패리티 테스트 + `*_wait_task` 폴링 + guard 감사" 패턴을 계승·확장. transport 인프라를 먼저 깔고(바텀업) 그 위에 verb 를 쌓는다. 전부 offline stub-driven 테스트.

**Tech Stack:** bash, jq, curl(스텁), 기존 assert 하니스(`tests/lib.sh`), 기존 probe 패턴(heredoc→`bin/_*probe.sh`→trap).

**참고 spec:** `docs/superpowers/specs/2026-05-18-homelab-ops-guard-verbs-design.md`

**경로 규약:** 모든 git/명령은 repo 루트 `/home/altair823/claude-skills` 기준. 스킬 코드는 `homelab-ops/`. 테스트는 `cd /home/altair823/claude-skills/homelab-ops && bash tests/<f>.sh`. 커밋은 `git -C /home/altair823/claude-skills ...`.

**전제 상태(하드닝 머지 후, 검증된 현재 코드):**
- `_lib.sh`: `op_transport` 는 `t="${spec##* }"; case "$t" in none|pve|ssh) echo "$t";; guest) ...;; *) echo none; esac`. `ACTIONS` 에 backup 까지 존재. `pve_wait_task` 존재(HO-TASK emit, 0/1/75, `HOMELAB_TASK_TIMEOUT`/`HOMELAB_TASK_POLL_INTERVAL`). `owner_host`, `canon_action`, `action_grade` 존재.
- `guard`: 자격 게이트(`_t="$(op_transport ...)"`, `pve`→PVE_TOKEN / `ssh`→HL_SSH_KEY|HL_SSH_PASS), `--plan`(동일 분기), `_finish_trap`(INT/TERM 단일-기록), post-hoc HO-TASK 파싱(정상 경로만).
- `_backend`: `case "$action:$kind"` 별 arm, `*) die "no backend mapping for action '$action' on kind '$kind'"`.
- `tests/test_action_table.sh`: 패리티 3방향 + vacuous-가드 + `_FAILS`/`finish`. `tests/lib.sh`: PATH 에 `tests/stubs`, `HOMELAB_INVENTORY_DIR=tests/fixtures`.

**구현 순서:** Phase 1 transport 인프라(Task 1–3) → Phase 2 인터럽트-UPID(Task 4) → Phase 3 disk-attach/detach(Task 5–6) → Phase 4 disk-grow(Task 7–8) → Phase 5 remote-migrate(Task 9–11) → Phase 6 문서·최종(Task 12). 각 Task 종료 시 `tests/run.sh` 전부 녹색.

**verb↔ACTIONS 등록 타이밍 규약(하드닝 교훈):** 어떤 verb 도 그 `_backend` arm 이 생기기 전에는 `ACTIONS` 에 넣지 않는다(넣으면 패리티 direction-1 이 즉시 실패). 각 verb 의 ACTIONS 등록 + `_backend` arm + (필요 시 `bin/pdm` sub) 은 같은 Task 에서 함께 추가하고 패리티 녹색을 확인한다.

---

### Task 1: `op_transport` 가 `host-ssh`·`pdm` 토큰을 인식 + `pdm_entry` 헬퍼 + 픽스처

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (`op_transport` 90–96행 부근; `owner_host` 다음에 헬퍼 추가)
- Modify: `homelab-ops/tests/test_lib.sh` (probe heredoc + 단언)
- Modify: `homelab-ops/tests/fixtures/fleet.yaml` (`kind: pdm` 엔트리 추가)

- [ ] **Step 1: 픽스처에 PDM 엔트리 추가**

`homelab-ops/tests/fixtures/fleet.yaml` 끝에 추가:

```yaml

- id: pdm-01
  kind: pdm
  address: 10.0.0.9
  env: prod
  access:
    api: { token_ref: "bw://Proxmox-Datacenter-Manager pdm-01/api-token", ca_path: "" }
  tags: []
```

- [ ] **Step 2: test_lib.sh 에 실패 단언 추가**

`homelab-ops/tests/test_lib.sh` 의 probe heredoc `case "$1" in` 안 `owner)` arm 다음에 두 줄 추가:

```bash
  oti)     ACTIONS[__zz]="$2"; op_transport __zz "${3:-}" ;;
  pdment)  pdm_entry ;;
```

그리고 기존 `transport ... unknown action → none` 단언 블록 다음에 추가:

```bash
assert_eq "host-ssh" "$(bash bin/_libprobe.sh oti 'destructive host-ssh' vm)"   "op_transport: host-ssh token → host-ssh"
assert_eq "pdm"      "$(bash bin/_libprobe.sh oti 'destructive pdm' vm)"          "op_transport: pdm token → pdm"
assert_eq "pve"      "$(bash bin/_libprobe.sh oti 'caution guest' vm)"            "op_transport: guest+vm still → pve (regression)"
assert_eq "ssh"      "$(bash bin/_libprobe.sh oti 'caution guest' appliance)"     "op_transport: guest+appliance still → ssh (regression)"
assert_eq "none"     "$(bash bin/_libprobe.sh oti 'safe none' vm)"                "op_transport: none token still → none (regression)"
assert_eq "pdm-01"   "$(bash bin/_libprobe.sh pdment)"                            "pdm_entry → the single kind:pdm id"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_lib.sh`
Expected: FAIL — `op_transport: host-ssh token → host-ssh` 가 빈 출력(현재 `*) echo none`), `pdm_entry` 케이스 없음.

- [ ] **Step 3: `op_transport` 토큰 확장 + `pdm_entry` 추가**

`homelab-ops/bin/_lib.sh` 의 `op_transport` `case "$t" in` 블록(현재):

```bash
  case "$t" in
    none|pve|ssh) echo "$t" ;;
    guest) case "$kind" in proxmox-host|vm|lxc) echo pve ;; *) echo ssh ;; esac ;;
    *) echo none ;;
  esac
```

를 아래로 교체(주석의 transport 어휘도 갱신):

```bash
  case "$t" in
    none|pve|ssh|host-ssh|pdm) echo "$t" ;;
    guest) case "$kind" in proxmox-host|vm|lxc) echo pve ;; *) echo ssh ;; esac ;;
    *) echo none ;;
  esac
```

그리고 `op_transport` 위 주석 라인 `#   transport: none | pve | ssh | guest` 를 아래로 교체:

```bash
#   transport: none | pve | ssh | guest | host-ssh | pdm
#     guest    = 대상 kind 가 proxmox-host/vm/lxc 면 pve, 그 외(appliance 등)면 ssh
#     host-ssh = owner_host(target) 에 root SSH (자격·실행 대상이 owner 노드)
#     pdm      = kind:pdm 인벤토리 엔트리 경유 (bin/pdm, PDM_TOKEN)
```

(주석에 이미 `guest = ...` 줄이 따로 있으면 중복 없이 위 3줄로 정리.)

`homelab-ops/bin/_lib.sh` 의 `owner_host()` 함수 닫는 `}` 다음에 추가:

```bash

# pdm_entry -> 인벤토리의 유일한 kind:pdm 엔트리 id. 0개/2개 이상이면 die.
# remote-migrate transport(pdm) 의 자격·base URL 해석 단일 출처.
pdm_entry() {
  local ids x k hits=()
  for x in $("$REPO_ROOT/bin/inv" list); do
    k="$("$REPO_ROOT/bin/inv" get "$x" | jq -r '.kind // ""')"
    [[ "$k" == "pdm" ]] && hits+=("$x")
  done
  case "${#hits[@]}" in
    1) echo "${hits[0]}" ;;
    0) die "no kind:pdm inventory entry (remote-migrate 는 PDM 엔트리 필요)" ;;
    *) die "multiple kind:pdm inventory entries (${hits[*]}) — 정확히 1개여야 함" ;;
  esac
}
```

- [ ] **Step 4: 테스트 통과 + 전체 회귀**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_lib.sh && bash tests/run.sh`
Expected: `PASS test_lib` 그리고 `ALL TESTS PASSED`. (픽스처에 pdm-01 추가는 `assert_contains` 기반 test_inv 등에 영향 없음 — list 멤버십·children 루프 무관. 확인.)

- [ ] **Step 5: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/bin/_lib.sh homelab-ops/tests/test_lib.sh homelab-ops/tests/fixtures/fleet.yaml
git -C /home/altair823/claude-skills commit -m "feat(homelab-ops): op_transport 가 host-ssh·pdm 토큰 인식 + pdm_entry 헬퍼 + pdm 픽스처"
```

---

### Task 2: guard 자격 게이트 + `--plan` 이 `host-ssh`(owner_host ssh)·`pdm`(PDM_TOKEN) 산출

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (`ACTION_ALIASES` 다음에 `_HL_EXTRA_ACTIONS` 훅)
- Modify: `homelab-ops/bin/guard` (`--plan` case 40–62행; 자격 게이트 130–146행)
- Modify: `homelab-ops/tests/test_guard_plan.sh`

- [ ] **Step 1: `_lib.sh` 에 테스트 전용 ACTIONS 확장 훅 추가**

테스트가 임의 액션의 transport(`host-ssh`/`pdm`)를 강제하려면 probe 용 ACTIONS 엔트리가 필요하다. `guard` 는 항상 `_lib.sh` 를 source 하므로, `_lib.sh` 에 env 기반 확장 훅을 둔다(운영 경로에서는 env unset → 무영향, 단일출처/패리티 계약 불변).

`homelab-ops/bin/_lib.sh` 의 `declare -gA ACTION_ALIASES=( [delete]="destroy" )` 줄 **다음**(`canon_action` 정의 앞)에 추가:

```bash
# 테스트 전용 확장점: _HL_EXTRA_ACTIONS="k=grade transport;k2=..." 이면 ACTIONS 에
# 병합. 운영 경로에서는 unset 이라 무영향(패리티/단일출처 계약은 unset 기준).
if [[ -n "${_HL_EXTRA_ACTIONS:-}" ]]; then
  _IFS_SAVE="$IFS"; IFS=';'
  for _kv in $_HL_EXTRA_ACTIONS; do ACTIONS["${_kv%%=*}"]="${_kv#*=}"; done
  IFS="$_IFS_SAVE"; unset _kv _IFS_SAVE
fi
```

- [ ] **Step 2: `_planprobe` 래퍼 + 실패 단언을 test_guard_plan.sh 에 추가**

`homelab-ops/tests/test_guard_plan.sh` 의 `chmod +x bin/guard 2>/dev/null || true` 줄 **다음**에 추가:

```bash
# 테스트 전용 래퍼: probe 액션을 _HL_EXTRA_ACTIONS 로 주입한 뒤 guard 실행.
cat > bin/_planprobe <<'EOF'
#!/usr/bin/env bash
export _HL_EXTRA_ACTIONS="__probe_hostssh=destructive host-ssh;__probe_pdm=destructive pdm"
exec "$(dirname "$0")/guard" "$@"
EOF
chmod +x bin/_planprobe
trap 'rm -f bin/_planprobe' EXIT
```

`homelab-ops/tests/test_guard_plan.sh` 의 마지막 `finish; echo "PASS test_guard_plan"` 줄 **직전**에 추가:

```bash
# host-ssh transport: owner_host(vm-100)=pve-01 의 ssh key_ref 산출(target 의 게 아님)
out="$(bin/_planprobe --plan __probe_hostssh vm-100 2>/dev/null || true)"
assert_eq "HL_SSH_KEY=bw://ssh-pve-01" "$out" "--plan host-ssh → owner_host ssh key_ref"
# pdm transport: kind:pdm 엔트리의 api token_ref 산출
out="$(bin/_planprobe --plan __probe_pdm vm-100 2>/dev/null || true)"
assert_eq "PDM_TOKEN=bw://Proxmox-Datacenter-Manager pdm-01/api-token" "$out" "--plan pdm → pdm entry api token_ref"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_guard_plan.sh`
Expected: FAIL — `--plan host-ssh → owner_host ssh key_ref` 등이 빈 출력(guard `--plan` 의 `case "$ptrans"` 에 host-ssh/pdm arm 부재 → 아무것도 안 찍음).

- [ ] **Step 3: guard `--plan` 에 host-ssh·pdm 분기 추가**

`homelab-ops/bin/guard` 의 `--plan` `case "$ptrans" in` 에서 `ssh)` arm 다음, `none)` arm 앞에 추가:

```bash
      host-ssh)
        pho="$("$HERE/inv" get "$(owner_host "$pt")")" || exit $?
        phauth="$(jq -r '.access.ssh.auth // "key"' <<<"$pho")"
        if [[ "$phauth" == "password" ]]; then
          pref="$(jq -r '.access.ssh.pass_ref // empty' <<<"$pho")"
          [[ -n "$pref" ]] && printf 'HL_SSH_PASS=%s\n' "$pref"
        else
          pref="$(jq -r '.access.ssh.key_ref // empty' <<<"$pho")"
          [[ -n "$pref" ]] && printf 'HL_SSH_KEY=%s\n' "$pref"
        fi ;;
      pdm)
        pref="$("$HERE/inv" get "$(pdm_entry)" \
                | jq -r '.access.api.token_ref // empty')"
        [[ -n "$pref" ]] && printf 'PDM_TOKEN=%s\n' "$pref" ;;
```

- [ ] **Step 4: guard 자격 게이트에 host-ssh·pdm 추가**

`homelab-ops/bin/guard` 의 자격 게이트 블록. 현재:

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
```

를 아래로 교체(이후 `if [[ -n "$_gate_var" ]]; then ...` 블록은 그대로 유지):

```bash
    _t="$(op_transport "$action" "$(jq -r '.kind // ""' <<<"$inv_json")")"
    _auth="$(jq -r '.access.ssh.auth // "key"' <<<"$inv_json")"
    # host-ssh: 자격 대상이 owner_host(target). pdm: kind:pdm 엔트리.
    if [[ "$_t" == "host-ssh" ]]; then
      _hoinv="$("$HERE/inv" get "$(owner_host "$target")" 2>/dev/null || echo '{}')"
      _auth="$(jq -r '.access.ssh.auth // "key"' <<<"$_hoinv")"
    fi
    if [[ "$grade" != "safe" ]]; then
      _gate_var=""
      [[ "$_t" == "pve" && -z "${PVE_TOKEN:-}" ]] && _gate_var="PVE_TOKEN"
      [[ "$_t" == "pdm" && -z "${PDM_TOKEN:-}" ]] && _gate_var="PDM_TOKEN"
      if [[ "$_t" == "ssh" || "$_t" == "host-ssh" ]]; then
        if [[ "$_auth" == "password" ]]; then
          [[ -z "${HL_SSH_PASS:-}" ]] && _gate_var="HL_SSH_PASS"
        else
          [[ -z "${HL_SSH_KEY:-}" ]] && _gate_var="HL_SSH_KEY"
        fi
      fi
```

- [ ] **Step 5: 통과 + 전체 회귀**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_guard_plan.sh && bash tests/run.sh`
Expected: `PASS test_guard_plan` (신규 host-ssh/pdm 단언 + 기존 전부) 그리고 `ALL TESTS PASSED`.

- [ ] **Step 6: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/bin/_lib.sh homelab-ops/bin/guard homelab-ops/tests/test_guard_plan.sh
git -C /home/altair823/claude-skills commit -m "feat(homelab-ops): guard 자격게이트·--plan 이 host-ssh(owner_host ssh)·pdm(PDM_TOKEN) 산출"
```

---

### Task 3: `bin/pdm` 클라이언트 + `pdm_wait_task`

**Files:**
- Create: `homelab-ops/bin/pdm`
- Modify: `homelab-ops/bin/_lib.sh` (`pve_wait_task` 다음에 `pdm_wait_task`)
- Create: `homelab-ops/tests/stubs/_pdmcurl` (참고용 — 실제 스텁은 테스트가 PATH 로 주입)
- Create: `homelab-ops/tests/test_pdm.sh`

- [ ] **Step 1: `bin/pdm` 작성 (bin/pve CA/fail-closed 패턴 미러)**

`homelab-ops/bin/pdm` 생성:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

sub="${1:-}"
[[ -n "$sub" ]] || die "usage: pdm {api <METHOD> <path> [data]}"

# PDM 엔드포인트는 유일한 kind:pdm 인벤토리 엔트리에서 해석 (단일 출처).
pe="$("$HERE/inv" get "$(pdm_entry)")" || exit $?
addr="$(jq -r '.address // empty' <<<"$pe")"
[[ -n "$addr" && "$addr" != "null" ]] || die "pdm entry has no address in inventory"
[[ -n "${PDM_TOKEN:-}" ]] || { HL_EXIT=3 die "missing PDM_TOKEN — bitwarden-ops bw-exec 로 감싸 실행 (참고: \"$HERE/guard\" --plan)"; }
token="$PDM_TOKEN"
# base URL: address 에 :port 포함 가능. base_path 는 인벤토리 override 가능,
# 기본은 PDM API 의 /api2/json. (운영자 PDM 버전에 맞춰 base_path 조정.)
bp="$(jq -r '.access.api.base_path // "/api2/json"' <<<"$pe")"
base="https://${addr}${bp}"

# Per-entry CA (bin/pve 와 동일 규칙): 선언+미독출 시 fail-closed.
ca_path="$(jq -r '.access.api.ca_path // empty' <<<"$pe")"
ca_opt=()
if [[ -n "$ca_path" && "$ca_path" != "null" ]]; then
  [[ "$ca_path" == "~"* ]] && ca_path="${ca_path/#\~/$HOME}"
  [[ "$ca_path" != /* ]] && ca_path="$REPO_ROOT/$ca_path"
  [[ -r "$ca_path" ]] || die "ca_path not readable: $ca_path (pdm entry)"
  ca_opt=(--cacert "$ca_path")
fi

call() { # METHOD path [data]
  local m="$1" p="$2" d="${3:-}"
  if [[ -n "$d" ]]; then
    curl -sS --fail-with-body ${ca_opt[@]+"${ca_opt[@]}"} -X "$m" \
      -H "Authorization: PVEAPIToken=${token}" --data "$d" "${base}${p}"
  else
    curl -sS --fail-with-body ${ca_opt[@]+"${ca_opt[@]}"} -X "$m" \
      -H "Authorization: PVEAPIToken=${token}" "${base}${p}"
  fi
}

case "$sub" in
  api) call "${2:?METHOD}" "${3:?path}" "${4:-}" ;;
  *)   die "pdm: unknown subcommand $sub" ;;
esac
```

> 고수준 `remote-migrate` sub 는 Task 9 에서 추가(엔드포인트 확정 지점). Task 3 은 범용 `api` 와 폴링 토대만.

- [ ] **Step 2: test_pdm.sh 작성 (실패 확인용)**

`homelab-ops/tests/test_pdm.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/pdm 2>/dev/null || true
export PDM_TOKEN="stub-pdm-token"

# 범용 api: curl 스텁이 결정적 JSON 반환
sp="$(mktemp -d)"
cat > "$sp/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/pdm-curl-args
echo '{"data":{"ok":true}}'
EOF
chmod +x "$sp/curl"; : > /tmp/pdm-curl-args
out="$(PATH="$sp:$PWD/tests/stubs:$PATH" bin/pdm api GET /version)"
assert_contains "$out" '"ok"' "pdm api GET returns json"
grep -q -- 'https://10.0.0.9/api2/json/version' /tmp/pdm-curl-args \
  && echo "  ok: pdm base URL from inventory entry" \
  || { echo "  FAIL: pdm base URL wrong: $(cat /tmp/pdm-curl-args)"; exit 1; }
grep -q -- 'PVEAPIToken=stub-pdm-token' /tmp/pdm-curl-args \
  && echo "  ok: pdm token header" || { echo "  FAIL: pdm token header"; exit 1; }
grep -q -- '-k' /tmp/pdm-curl-args && { echo "FAIL: pdm used -k"; exit 1; } || echo "  ok: TLS verification on"

# 미주입 PDM_TOKEN → exit 3
assert_status 3 'env -u PDM_TOKEN bin/pdm api GET /version' "pdm without PDM_TOKEN exits 3"

# pdm_wait_task: OK / 실패 / 타임아웃
cat > /tmp/_pdmwait.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
pdm_wait_task "$1"
EOF
cp /tmp/_pdmwait.sh bin/_pdmwait.sh
trap 'rm -f bin/_pdmwait.sh "$sp"/* ; rmdir "$sp" 2>/dev/null || true' EXIT
T="PDM-task:stub:1"

okd="$(mktemp -d)"
cat > "$okd/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"stopped","exitstatus":"OK"}}'
EOF
chmod +x "$okd/curl"
set +e
out="$(PDM_TOKEN=x PATH="$okd:$PWD/tests/stubs:$PATH" bash bin/_pdmwait.sh "$T")"; rc=$?
set -e
assert_eq "0" "$rc" "pdm_wait_task OK → 0"
assert_contains "$out" "HO-TASK upid=$T exitstatus=OK" "pdm_wait_task emits HO-TASK OK"

errd="$(mktemp -d)"
cat > "$errd/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"stopped","exitstatus":"migrate failed"}}'
EOF
chmod +x "$errd/curl"
set +e
out="$(PDM_TOKEN=x PATH="$errd:$PWD/tests/stubs:$PATH" bash bin/_pdmwait.sh "$T")"; rc=$?
set -e
assert_eq "1" "$rc" "pdm_wait_task non-OK → 1"
assert_contains "$out" "exitstatus=migrate failed" "pdm_wait_task carries error xs"

rund="$(mktemp -d)"
cat > "$rund/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"running"}}'
EOF
chmod +x "$rund/curl"
set +e
out="$(HOMELAB_TASK_TIMEOUT=0 PDM_TOKEN=x PATH="$rund:$PWD/tests/stubs:$PATH" bash bin/_pdmwait.sh "$T")"; rc=$?
set -e
assert_eq "75" "$rc" "pdm_wait_task timeout → 75"
assert_contains "$out" "exitstatus=TIMEOUT" "pdm_wait_task TIMEOUT preserves task id"
rm -rf "$okd" "$errd" "$rund"

finish; echo "PASS test_pdm"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_pdm.sh`
Expected: FAIL — `pdm_wait_task` 미정의(`bin/_pdmwait.sh` 가 함수 못 찾음).

- [ ] **Step 3: `pdm_wait_task` 추가**

`homelab-ops/bin/_lib.sh` 의 `pve_wait_task` 함수 닫는 `}` **다음**에 추가:

```bash

# pdm_wait_task <task-id> -> 0: OK / 1: not OK / 75: 타임아웃.
# pve_wait_task 와 동일 계약(HO-TASK emit, HOMELAB_TASK_TIMEOUT/INTERVAL).
# 상태는 bin/pdm api GET 로 폴링. PDM task 상태 경로는 base_path 와 함께
# 인벤토리 access.api.task_status_path (기본 /tasks) 로 override 가능 —
# 운영자 PDM 버전에 맞춰 조정(known-unknown, spec §5).
pdm_wait_task() {
  local tid="${1:?pdm_wait_task: task-id required}"
  local timeout="${HOMELAB_TASK_TIMEOUT:-600}"
  local interval="${HOMELAB_TASK_POLL_INTERVAL:-2}"
  local waited=0 resp st xs tsp
  [[ "$timeout"  =~ ^[0-9]+$ ]] || die "pdm_wait_task: HOMELAB_TASK_TIMEOUT must be a non-negative integer (got: $timeout)"
  [[ "$interval" =~ ^[0-9]+$ ]] || die "pdm_wait_task: HOMELAB_TASK_POLL_INTERVAL must be a non-negative integer (got: $interval)"
  tsp="$("$REPO_ROOT/bin/inv" get "$(pdm_entry)" | jq -r '.access.api.task_status_path // "/tasks"')"
  while :; do
    resp="$("$REPO_ROOT/bin/pdm" api GET "${tsp}/${tid}/status" 2>/dev/null || true)"
    st="$(jq -r '.data.status // empty' <<<"$resp" 2>/dev/null || true)"
    if [[ "$st" == "stopped" ]]; then
      xs="$(jq -r '.data.exitstatus // "UNKNOWN"' <<<"$resp" 2>/dev/null || echo UNKNOWN)"
      printf 'HO-TASK upid=%s exitstatus=%s\n' "$tid" "$xs"
      if [[ "$xs" == "OK" ]]; then return 0; else return 1; fi
    fi
    if (( waited >= timeout )); then
      printf 'HO-TASK upid=%s exitstatus=%s\n' "$tid" "TIMEOUT"
      return 75
    fi
    sleep "$interval"
    waited=$(( waited + interval ))
  done
}
```

- [ ] **Step 4: 통과 + 전체 회귀**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_pdm.sh && bash tests/run.sh`
Expected: `PASS test_pdm` 그리고 `ALL TESTS PASSED`.

- [ ] **Step 5: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/bin/pdm homelab-ops/bin/_lib.sh homelab-ops/tests/test_pdm.sh
git -C /home/altair823/claude-skills commit -m "feat(homelab-ops): bin/pdm 클라이언트 + pdm_wait_task (pve_wait_task 동일 계약)"
```

---

### Task 4: 인터럽트-UPID 캡처 (`_finish_trap` 의 `$rl` 스크레이프)

**Files:**
- Modify: `homelab-ops/bin/guard` (`_finish_trap` 106–113행)
- Create: `homelab-ops/tests/test_guard_intr_upid.sh`

- [ ] **Step 1: test_guard_intr_upid.sh 작성 (실패 확인)**

`homelab-ops/tests/test_guard_intr_upid.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard 2>/dev/null || true
export HOMELAB_SESSION_ID="intr-upid-sess"
export PVE_TOKEN="stub-token-value"
: > logs/audit.jsonl
rm -rf "logs/runs/$HOMELAB_SESSION_ID"

# 느린 백엔드: UPID 가 든 raw 응답을 출력한 뒤 폴링처럼 장시간 sleep.
# 정상 종료 직전 HO-TASK 라인은 만들지 않음 → 인터럽트 경로의 raw-UPID
# 스크레이프(우선순위 2)만 검증.
cat > /tmp/slow-upid-backend <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *--dry-run* ]] && { echo "DRYRUN"; exit 0; }
[[ "$1" == status ]] && { echo '{"state":"pre"}'; exit 0; }
echo '{"data":"UPID:stub:DEADBEEF:0:0:t:0:root@pam:"}'
sleep 30
EOF
chmod +x /tmp/slow-upid-backend
export HOMELAB_BACKEND=/tmp/slow-upid-backend

# lab-vm-900: caution+lab → 승인 불필요, 백그라운드 파이프라인 진입.
bin/guard stop lab-vm-900 >/dev/null 2>&1 &
gpid=$!
sleep 2                       # 백엔드가 UPID 라인을 run-log 에 쓸 시간
kill -TERM "$gpid" 2>/dev/null || true
wait "$gpid" 2>/dev/null; rc=$?

rec="$(tail -1 logs/audit.jsonl)"
assert_eq "143" "$(jq -r .exit <<<"$rec")" "TERM 경로 exit 143 감사 1건"
n="$(wc -l < logs/audit.jsonl)"
assert_eq "1" "$n" "감사 레코드 정확히 1건(갭/중복 없음)"
assert_eq "UPID:stub:DEADBEEF:0:0:t:0:root@pam:" "$(jq -r .task_upid <<<"$rec")" \
  "인터럽트 경로에서 raw UPID 가 감사 task_upid 에 캡처됨"
assert_eq "null" "$(jq -r '.task_exitstatus // "null"' <<<"$rec")" \
  "결과 미상 → task_exitstatus null (정직한 표현)"

finish; echo "PASS test_guard_intr_upid"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_guard_intr_upid.sh`
Expected: FAIL — `task_upid` 가 `null`(현재 INT/TERM 경로는 HO-TASK 파싱 미실행).

- [ ] **Step 2: `_finish_trap` 에 raw-UPID 스크레이프 추가**

`homelab-ops/bin/guard` 의 `_finish_trap()` 현재:

```bash
    _finish_trap() { # <exit-code>
      local _frc="$1"
      if [[ -z "${_DONE:-}" ]]; then
        _DONE=1
        _audit "$_frc" || echo "homelab-ops: AUDIT FAILED op=$op rc=$_frc" >&2
      fi
      [[ -n "${_rc_file:-}" ]] && rm -f "$_rc_file" 2>/dev/null || true
    }
```

를 아래로 교체:

```bash
    _finish_trap() { # <exit-code>
      local _frc="$1"
      if [[ -z "${_DONE:-}" ]]; then
        # best-effort: 인터럽트 등으로 정상 경로의 HO-TASK 파싱이 실행되지
        # 않았어도, run-log 에서 task_upid 를 복구해 감사 정확성을 높인다.
        # 우선순위 1: HO-TASK 라인 / 2: backend 응답의 raw {"data":"UPID:..."}.
        # 실패해도 감사 1건 보장(Rule 5)을 절대 훼손하지 않는다(|| true).
        if [[ -z "$task_upid" && -n "${rl:-}" && -f "${rl:-/nonexistent}" ]]; then
          task_upid="$(sed -n 's/^HO-TASK upid=\([^ ]*\).*/\1/p' "$rl" 2>/dev/null | tail -n1 || true)"
          task_xs="$(sed -n 's/^HO-TASK .*exitstatus=\(.*\)$/\1/p' "$rl" 2>/dev/null | tail -n1 || true)"
          if [[ -z "$task_upid" ]]; then
            task_upid="$(grep -o 'UPID:[^"]*' "$rl" 2>/dev/null | tail -n1 || true)"
          fi
        fi
        _DONE=1
        _audit "$_frc" || echo "homelab-ops: AUDIT FAILED op=$op rc=$_frc" >&2
      fi
      [[ -n "${_rc_file:-}" ]] && rm -f "$_rc_file" 2>/dev/null || true
    }
```

> `task_upid`/`task_xs`/`rl` 는 exec arm 스코프 변수로 trap 정의 시점 이전에 init(`task_upid=""; task_xs=""`)되며 `rl` 은 백그라운드 파이프라인 전 설정됨. 스크레이프는 `task_upid` 가 비었을 때만 수행 → 정상 경로의 post-hoc 파싱 결과를 덮어쓰지 않음. `task_exitstatus` 는 raw-UPID 만 찾은 경우 빈 문자열 유지 → `_audit` jq 가 `null` 로 기록(설계대로 "수락됐으나 결과 미상").

- [ ] **Step 3: 통과 + 회귀 (정상 경로 무영향 확인)**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_guard_intr_upid.sh && bash tests/test_guard_task_audit.sh && bash tests/test_guard_exec.sh && bash tests/test_forensic_sufficiency.sh && bash tests/run.sh`
Expected: 전부 PASS, 최종 `ALL TESTS PASSED`. (`test_guard_task_audit` 의 정상 경로 `task_upid` 캡처가 회귀 없이 유지 — 스크레이프는 `task_upid` 빈 경우만.)

- [ ] **Step 4: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/bin/guard homelab-ops/tests/test_guard_intr_upid.sh
git -C /home/altair823/claude-skills commit -m "feat(homelab-ops): 인터럽트 경로 감사에 raw UPID 캡처(_finish_trap $rl 스크레이프)"
```

---

### Task 5: `disk-attach` / `disk-detach` — ACTIONS + `_backend` arm + by-id/serial 안전

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (`ACTIONS` 테이블)
- Modify: `homelab-ops/bin/_backend` (신규 arm)
- Modify: `homelab-ops/tests/fixtures/fleet.yaml` (게스트 disk serial 필드)
- Create: `homelab-ops/tests/test_disk_attach.sh`

- [ ] **Step 1: 픽스처에 disk serial 추가**

`homelab-ops/tests/fixtures/fleet.yaml` 의 `lab-vm-900` 엔트리 `tags: []` 줄 **앞**에 추가(인덴트 2칸):

```yaml
  disks:
    - serial: "WD-LABDISK-001"
```

- [ ] **Step 2: test_disk_attach.sh 작성 (실패 확인)**

`homelab-ops/tests/test_disk_attach.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend 2>/dev/null || true
export PVE_TOKEN="stub-token-value" HL_SSH_KEY="stub-key"

# 등급: disk-attach / disk-detach = destructive
assert_eq "destructive" "$(bin/guard grade disk-attach lab-vm-900)" "disk-attach destructive"
assert_eq "destructive" "$(bin/guard grade disk-detach lab-vm-900)" "disk-detach destructive"

# by-id 강제: /dev/sdX 거부 (dry-run 에서도)
o="$(bin/_backend disk-attach lab-vm-900 --dry-run -- --by-id /dev/sdb 2>&1 || true)"
assert_contains "$o" "by-id" "non-by-id 경로 거부 메시지"
assert_not_contains "$o" "qm set" "거부 시 qm 명령 미형성"

# serial 미선언 게스트(vm-100, disks 없음) → 거부
o="$(bin/_backend disk-attach vm-100 --dry-run -- --by-id /dev/disk/by-id/wwn-0xLAB 2>&1 || true)"
assert_contains "$o" "serial" "serial 미선언 게스트 거부"

# dry-run 정상: by-id + serial 선언된 lab-vm-900, 미적용·명령 echo·exit 0
o="$(bin/_backend disk-attach lab-vm-900 --dry-run -- --by-id /dev/disk/by-id/wwn-0xLAB --index 1 2>&1)"
assert_contains "$o" "DRY-RUN" "attach dry-run 헤더"
assert_contains "$o" "qm set 900 -scsi1 /dev/disk/by-id/wwn-0xLAB,backup=0,iothread=1" "attach 명령 형성(echo만)"
assert_status 0 'bin/_backend disk-attach lab-vm-900 --dry-run -- --by-id /dev/disk/by-id/wwn-0xLAB' "attach dry-run exit 0"

# detach dry-run
o="$(bin/_backend disk-detach lab-vm-900 --dry-run -- --index 1 2>&1)"
assert_contains "$o" "qm set 900 -delete scsi1" "detach 명령 형성(echo만)"

# transport host-ssh: PVE_TOKEN 무관, owner_host 의 HL_SSH_KEY 게이트
assert_eq "destructive host-ssh" "$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[disk-attach]}"')" "ACTIONS[disk-attach]=destructive host-ssh"
assert_status 3 'env -u HL_SSH_KEY -u HL_SSH_PASS PVE_TOKEN=x bin/guard disk-attach lab-vm-900 -- --by-id /dev/disk/by-id/wwn-0xLAB' "host-ssh 게이트: owner_host ssh 자격 없으면 exit 3"

finish; echo "PASS test_disk_attach"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_disk_attach.sh`
Expected: FAIL — 등급 deny-default 는 destructive 라 통과할 수 있으나 `_backend` arm 부재로 by-id/serial/dry-run 단언 실패.

- [ ] **Step 3: ACTIONS 등록 + `_backend` arm 추가**

`homelab-ops/bin/_lib.sh` 의 `ACTIONS` 에서 `[backup]="caution pve"` 줄 다음에 추가:

```bash
  [disk-attach]="destructive host-ssh"  [disk-detach]="destructive host-ssh"
```

`homelab-ops/bin/_backend` 의 `backup:*)` arm 다음, `pkg-install:*)` arm 앞에 추가:

```bash
  disk-attach:*|disk-detach:*)
    # 인자 파싱: --by-id <id> --index <N> --bus <bus(기본 scsi)>
    byid=""; idx=""; bus="scsi"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --by-id) byid="${2:-}"; shift 2 ;;
        --index) idx="${2:-}"; shift 2 ;;
        --bus)   bus="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
    done
    vmid="$(jq -r '.vmid // empty' <<<"$inv")"
    [[ -n "$vmid" ]] || die "disk-*: target '$target' has no vmid"
    if [[ "$action" == "disk-attach" ]]; then
      [[ "$byid" == /dev/disk/by-id/* ]] \
        || die "disk-attach: --by-id 는 /dev/disk/by-id/... 안정 경로만 허용 (받음: '${byid:-<none>}'). /dev/sdX 등 비안정 경로 거부."
      # serial opt-in 강제: 인벤토리에 disks[].serial 선언이 없으면 거부.
      sercount="$(jq -r '[.disks[]?.serial] | length' <<<"$inv")"
      [[ "$sercount" -ge 1 ]] \
        || die "disk-attach: 게스트 '$target' 인벤토리에 disks[].serial 미선언 — 명시적 opt-in 필요(아무 디스크나 패스스루 차단)"
      idx="${idx:-1}"
      cmd="qm set $vmid -${bus}${idx} ${byid},backup=0,iothread=1"
    else
      [[ -n "$idx" ]] || die "disk-detach: --index <N> 필요"
      cmd="qm set $vmid -delete ${bus}${idx}"
    fi
    if [[ $dry -eq 1 ]]; then
      echo "DRY-RUN: would (on $(owner_host "$target")) $cmd"
      [[ "$action" == "disk-attach" ]] && echo "  serial 대조: 인벤토리 declared serial 과 노드 by-id 실제 serial 을 적용 시 대조(불일치 거부)"
      exit 0
    fi
    "$HERE/ssh-run" "$(owner_host "$target")" -- "$cmd" ;;
```

> 적용(비-dry-run) 경로의 serial 실대조는 `ssh-run` 으로 노드에서 `lsblk -ndo SERIAL <by-id>` 결과를 받아 인벤토리 declared serial 과 비교하는 단계가 필요하나, 이는 노드 root SSH 런타임(블로커)에서만 의미가 있고 stub 으로는 명령 형성까지만 검증한다. 명령 형성·dry-run·게이트가 본 Task 범위. 실대조 enforcement 는 Task 6 에서 ssh-run 출력 파싱으로 추가.

- [ ] **Step 4: 통과 + 패리티/회귀**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_disk_attach.sh && bash tests/test_action_table.sh && bash tests/run.sh`
Expected: `PASS test_disk_attach`, `PASS test_action_table`(disk-attach/detach 가 테이블+backend 양쪽 → 패리티 통과), `ALL TESTS PASSED`.

- [ ] **Step 5: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/bin/_lib.sh homelab-ops/bin/_backend homelab-ops/tests/fixtures/fleet.yaml homelab-ops/tests/test_disk_attach.sh
git -C /home/altair823/claude-skills commit -m "feat(homelab-ops): disk-attach/detach verb (host-ssh, by-id 강제·serial opt-in, dry-run)"
```

---

### Task 6: `disk-attach` 적용 경로 serial 실대조 (ssh-run 출력 파싱)

**Files:**
- Modify: `homelab-ops/bin/_backend` (`disk-attach` 비-dry 경로)
- Modify: `homelab-ops/tests/test_disk_attach.sh`

- [ ] **Step 1: test 에 serial 대조 단언 추가**

`homelab-ops/tests/test_disk_attach.sh` 의 `finish;` 줄 앞에 추가:

```bash
# 적용 경로 serial 실대조: 노드의 실제 serial 이 인벤토리 declared 와
# 불일치하면 qm set 전에 거부. ssh stub 가 SERIAL 질의에 응답.
sd="$(mktemp -d)"
cat > "$sd/ssh" <<'EOF'
#!/usr/bin/env bash
# 인자에 lsblk ... SERIAL 가 있으면 mismatched serial 반환, 아니면 통과
for a in "$@"; do case "$a" in *SERIAL*|*lsblk*) echo "WRONG-SERIAL-999"; exit 0;; esac; done
echo "stub-ssh-applied"
EOF
chmod +x "$sd/ssh"
set +e
o="$(PATH="$sd:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-attach lab-vm-900 -- --by-id /dev/disk/by-id/wwn-0xLAB --index 1 2>&1)"; rc=$?
set -e
assert_contains "$o" "serial" "serial 불일치 시 거부 메시지"
[[ "$rc" -ne 0 ]] && echo "  ok: serial 불일치 → 비-0, qm set 미실행" || { echo "  FAIL: serial 불일치인데 진행됨"; exit 1; }
rm -rf "$sd"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_disk_attach.sh`
Expected: FAIL — 현재 비-dry 경로는 serial 대조 없이 바로 `ssh-run ... qm set`.

- [ ] **Step 2: `_backend` disk-attach 비-dry 경로에 serial 대조 삽입**

`homelab-ops/bin/_backend` 의 disk-* arm 마지막 줄(현재):

```bash
    "$HERE/ssh-run" "$(owner_host "$target")" -- "$cmd" ;;
```

를 아래로 교체:

```bash
    if [[ "$action" == "disk-attach" ]]; then
      # 적용 전 serial 실대조: 노드에서 by-id 장치의 실제 serial 조회 후
      # 인벤토리 declared serial 집합과 비교. 불일치 시 qm set 전에 거부.
      declared="$(jq -r '[.disks[]?.serial] | join(" ")' <<<"$inv")"
      actual="$("$HERE/ssh-run" "$(owner_host "$target")" -- \
                "lsblk -ndo SERIAL $byid 2>/dev/null | head -n1" 2>/dev/null || true)"
      actual="$(echo "$actual" | tr -d '[:space:]')"
      case " $declared " in
        *" $actual "*) : ;;  # 일치
        *) die "disk-attach: serial 불일치 — 노드 실측 '$actual' 가 인벤토리 declared [$declared] 에 없음. 패스스루 거부." ;;
      esac
    fi
    "$HERE/ssh-run" "$(owner_host "$target")" -- "$cmd" ;;
```

- [ ] **Step 3: 통과 + 회귀**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_disk_attach.sh && bash tests/run.sh`
Expected: `PASS test_disk_attach` (serial 불일치 거부 포함) 그리고 `ALL TESTS PASSED`.

- [ ] **Step 4: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/bin/_backend homelab-ops/tests/test_disk_attach.sh
git -C /home/altair823/claude-skills commit -m "feat(homelab-ops): disk-attach 적용 전 serial 실대조(노드 lsblk vs 인벤토리 declared)"
```

---

### Task 7: `disk-grow` — ACTIONS + `_backend` arm + 레이아웃 자동탐지/dry-run

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (`ACTIONS`)
- Modify: `homelab-ops/bin/_backend` (신규 arm)
- Create: `homelab-ops/tests/test_disk_grow.sh`

- [ ] **Step 1: test_disk_grow.sh 작성 (실패 확인)**

`homelab-ops/tests/test_disk_grow.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend 2>/dev/null || true
export HL_SSH_KEY="stub-key"

assert_eq "destructive" "$(bin/guard grade disk-grow lab-vm-900)" "disk-grow destructive"
assert_eq "destructive host-ssh" "$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[disk-grow]}"')" "ACTIONS[disk-grow]=destructive host-ssh"

# guest-agent 통한 탐지 stub: qm guest exec 가 lsblk/pvs/lvs/findmnt JSON 반환
gd="$(mktemp -d)"
cat > "$gd/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *lsblk* ]]; then
  echo '{"out-data":"{\"blockdevices\":[{\"name\":\"sda\",\"type\":\"disk\",\"children\":[{\"name\":\"sda3\",\"type\":\"part\",\"fstype\":\"LVM2_member\"}]}]}","exitcode":0}'
elif [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* || "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}],\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$gd/ssh"
PV="PATH=$gd:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

# dry-run: 탐지 레이아웃 + 명령 시퀀스 echo, 미적용·exit 0, PVE-디스크 범위밖 명시
o="$(eval "$PV bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1")"
assert_contains "$o" "DRY-RUN" "disk-grow dry-run 헤더"
assert_contains "$o" "growpart" "시퀀스에 growpart"
assert_contains "$o" "pvresize" "시퀀스에 pvresize"
assert_contains "$o" "lvextend -l +100%FREE vg0/root" "시퀀스에 lvextend(탐지된 vg/lv)"
assert_contains "$o" "resize2fs" "ext4 → resize2fs 분기"
assert_contains "$o" "PVE 레벨 가상디스크" "범위밖(게스트 내부 전용) 명시"
assert_status 0 "$(printf '%s ' $PV) bin/_backend disk-grow lab-vm-900 --dry-run --" "disk-grow dry-run exit 0"

# guest-agent 실패 → 거부 (qm guest exec 비-0)
fd="$(mktemp -d)"
cat > "$fd/ssh" <<'EOF'
#!/usr/bin/env bash
echo "QEMU guest agent is not running" >&2; exit 1
EOF
chmod +x "$fd/ssh"
set +e
o="$(PATH="$fd:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1)"; rc=$?
set -e
assert_contains "$o" "guest" "guest-agent 실패 사유"
[[ "$rc" -ne 0 ]] && echo "  ok: guest-agent 실패 → 거부(추측 실행 없음)" || { echo "  FAIL: guest-agent 실패인데 진행"; exit 1; }
rm -rf "$gd" "$fd"

finish; echo "PASS test_disk_grow"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_disk_grow.sh`
Expected: FAIL — `_backend` disk-grow arm 부재.

- [ ] **Step 2: ACTIONS 등록 + `_backend` disk-grow arm 추가**

`homelab-ops/bin/_lib.sh` 의 `ACTIONS` 에서 `[disk-attach]=...  [disk-detach]=...` 줄 다음에 추가:

```bash
  [disk-grow]="destructive host-ssh"
```

`homelab-ops/bin/_backend` 의 `disk-attach:*|disk-detach:*)` arm 다음에 추가:

```bash
  disk-grow:*)
    lv=""
    while [[ $# -gt 0 ]]; do
      case "$1" in --lv) lv="${2:-}"; shift 2 ;; *) shift ;; esac
    done
    vmid="$(jq -r '.vmid // empty' <<<"$inv")"
    [[ -n "$vmid" ]] || die "disk-grow: target '$target' has no vmid"
    oh="$(owner_host "$target")"
    _ga() { # <remote shell cmd> -> guest-exec out-data, die if exitcode!=0/agent down
      local raw od ec
      raw="$("$HERE/ssh-run" "$oh" -- "qm guest exec $vmid -- $*" 2>&1)" \
        || die "disk-grow: qm guest exec 실패(게스트 guest-agent 미동작?): $raw"
      ec="$(jq -r '.exitcode // 1' <<<"$raw" 2>/dev/null || echo 1)"
      [[ "$ec" == "0" ]] || die "disk-grow: 게스트 명령 비-0 (exitcode=$ec): $*"
      od="$(jq -r '."out-data" // ""' <<<"$raw" 2>/dev/null || echo "")"
      printf '%s' "$od"
    }
    # 탐지 (read-only, dry/apply 공통)
    fm="$(_ga findmnt -J)"
    fstype="$(jq -r '.filesystems[]? | select(.target=="/") | .fstype' <<<"$fm" 2>/dev/null | head -n1)"
    mnt="/"
    rpt="$(_ga pvs --reportformat json; true)"
    lvline="$(_ga lvs --reportformat json)"
    if [[ -z "$lv" ]]; then
      lv="$(jq -r '[.report[]?.lv[]?] | if length==1 then (.[0]|.vg_name+"/"+.lv_name) else "" end' <<<"$lvline" 2>/dev/null)"
      [[ -n "$lv" ]] || die "disk-grow: 단일 LV 자동탐지 실패(다중/비표준) — --lv <vg/lv> 명시 필요"
    fi
    case "$fstype" in
      ext4) fscmd="resize2fs /dev/${lv}" ;;
      xfs)  fscmd="xfs_growfs ${mnt}" ;;
      *)    die "disk-grow: 미지원 FS '$fstype' (ext4/xfs 만 지원)" ;;
    esac
    pvname="$(jq -r '[.report[]?.pv[]?.pv_name]|.[0]//""' <<<"$rpt" 2>/dev/null)"
    pvname="${pvname:-/dev/sda3}"
    disk="$(echo "$pvname" | sed -E 's#([0-9]+)$##')"
    partnum="$(echo "$pvname" | sed -E 's#.*[^0-9]([0-9]+)$#\1#')"
    seq1="growpart ${disk} ${partnum}"
    seq2="pvresize ${pvname}"
    seq3="lvextend -l +100%FREE ${lv}"
    if [[ $dry -eq 1 ]]; then
      echo "DRY-RUN: disk-grow $target (vmid=$vmid via $oh, guest-agent)"
      echo "  주의: PVE 레벨 가상디스크 확장은 본 verb 범위 밖(게스트 내부 전용) — PVE 디스크는 사전 확장 전제"
      echo "  탐지: PV=$pvname LV=$lv FS=$fstype mnt=$mnt"
      echo "  시퀀스: $seq1 && $seq2 && $seq3 && $fscmd"
      exit 0
    fi
    _ga $seq1 >/dev/null
    _ga $seq2 >/dev/null
    _ga $seq3 >/dev/null
    _ga $fscmd >/dev/null
    echo "GROWN: $target $lv ($fstype) extended on $oh" ;;
```

- [ ] **Step 3: 통과 + 패리티/회귀**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_disk_grow.sh && bash tests/test_action_table.sh && bash tests/run.sh`
Expected: `PASS test_disk_grow`, `PASS test_action_table`, `ALL TESTS PASSED`.

- [ ] **Step 4: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/bin/_lib.sh homelab-ops/bin/_backend homelab-ops/tests/test_disk_grow.sh
git -C /home/altair823/claude-skills commit -m "feat(homelab-ops): disk-grow verb (host-ssh→qm guest exec, 레이아웃 자동탐지, dry-run 시퀀스)"
```

---

### Task 8: `disk-grow` 다중-LV 모호성 + 미지원 FS 거부 강화 테스트

**Files:**
- Modify: `homelab-ops/tests/test_disk_grow.sh`

- [ ] **Step 1: 엣지 케이스 단언 추가**

`homelab-ops/tests/test_disk_grow.sh` 의 `finish;` 줄 앞에 추가:

```bash
# 다중 LV → --lv 미지정 시 거부
md="$(mktemp -d)"
cat > "$md/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *findmnt* ]]; then echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *lvs* ]]; then echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"},{\"lv_name\":\"data\",\"vg_name\":\"vg0\"}],\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
else echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'; fi
EOF
chmod +x "$md/ssh"
set +e
o="$(PATH="$md:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1)"; rc=$?
set -e
assert_contains "$o" "--lv" "다중 LV → --lv 명시 요구 메시지"
[[ "$rc" -ne 0 ]] && echo "  ok: 다중 LV 모호 → 거부" || { echo "  FAIL: 다중 LV인데 진행"; exit 1; }
# --lv 명시하면 통과
o="$(PATH="$md:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-grow lab-vm-900 --dry-run -- --lv vg0/data 2>&1)"
assert_contains "$o" "lvextend -l +100%FREE vg0/data" "--lv 명시 시 그 LV 사용"

# 미지원 FS(btrfs) 거부
bd="$(mktemp -d)"
cat > "$bd/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *findmnt* ]]; then echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"fstype\":\"btrfs\"}]}","exitcode":0}'
elif [[ "$all" == *lvs* ]]; then echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}],\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
else echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'; fi
EOF
chmod +x "$bd/ssh"
set +e
o="$(PATH="$bd:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1)"; rc=$?
set -e
assert_contains "$o" "미지원 FS" "btrfs 거부"
[[ "$rc" -ne 0 ]] && echo "  ok: 미지원 FS → 거부" || { echo "  FAIL: btrfs인데 진행"; exit 1; }
rm -rf "$md" "$bd"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_disk_grow.sh && bash tests/run.sh`
Expected: `PASS test_disk_grow` (엣지 포함) 그리고 `ALL TESTS PASSED`.

- [ ] **Step 2: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/tests/test_disk_grow.sh
git -C /home/altair823/claude-skills commit -m "test(homelab-ops): disk-grow 다중-LV 모호성·미지원 FS 거부 커버"
```

---

### Task 9: `remote-migrate` — ACTIONS + `bin/pdm` 고수준 sub + `_backend` arm (dry-run)

**Files:**
- Modify: `homelab-ops/bin/_lib.sh` (`ACTIONS`)
- Modify: `homelab-ops/bin/pdm` (고수준 `remote-migrate` sub)
- Modify: `homelab-ops/bin/_backend` (신규 arm)
- Create: `homelab-ops/tests/test_remote_migrate.sh`

> **known-unknown 게이트(spec §5):** PDM 원격 마이그레이션 API 의 정확한 path/payload 는 운영자 PDM 버전에 따라 다르다. 본 Task 는 `bin/pdm` 의 인벤토리-구성형 path(`access.api.migrate_path`, 기본 아래)로 구현하고 stub 으로 **계약**(POST 발행 → task id → `pdm_wait_task` → HO-TASK → guard 감사)을 검증한다. 실 path 확정 불가 시 컨트롤러에 보고하고 spec fallback(remote-migrate 분리 보류, 나머지 3 항목으로 PR) 결정을 위임한다 — 임의 추정 금지.

- [ ] **Step 1: test_remote_migrate.sh 작성 (실패 확인)**

`homelab-ops/tests/test_remote_migrate.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend bin/pdm 2>/dev/null || true
export PDM_TOKEN="stub-pdm-token"

assert_eq "destructive" "$(bin/guard grade remote-migrate lab-vm-900)" "remote-migrate destructive"
assert_eq "destructive pdm" "$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[remote-migrate]}"')" "ACTIONS[remote-migrate]=destructive pdm"

# dry-run: 미적용, source/target/vmid/storage/online echo, exit 0
o="$(bin/_backend remote-migrate lab-vm-900 --dry-run -- --to pve-01 --target-storage local:local-zfs --online 2>&1)"
assert_contains "$o" "DRY-RUN" "remote-migrate dry-run 헤더"
assert_contains "$o" "vmid=900" "vmid echo"
assert_contains "$o" "to=pve-01" "target node echo"
assert_contains "$o" "online" "online echo"
assert_status 0 'bin/_backend remote-migrate lab-vm-900 --dry-run -- --to pve-01' "dry-run exit 0"

# 적용: bin/pdm 가 POST 발행하고 task id 반환 → pdm_wait_task 폴링 → HO-TASK
sp="$(mktemp -d)"
cat > "$sp/curl" <<'EOF'
#!/usr/bin/env bash
a="$*"
echo "$a" >> /tmp/rm-curl-args
if [[ "$a" == *"/status"* ]]; then echo '{"data":{"status":"stopped","exitstatus":"OK"}}'
else echo '{"data":"PDM-task:stub:42"}'; fi
EOF
chmod +x "$sp/curl"; : > /tmp/rm-curl-args
out="$(PATH="$sp:$PWD/tests/stubs:$PATH" bin/_backend remote-migrate lab-vm-900 -- --to pve-01 2>&1)"
assert_contains "$out" "HO-TASK upid=PDM-task:stub:42 exitstatus=OK" "remote-migrate 가 PDM task 폴링"
grep -q -- '-X POST' /tmp/rm-curl-args && echo "  ok: POST 발행" || { echo "  FAIL: POST 미발행"; exit 1; }
rm -rf "$sp"

# 자격 게이트: PDM_TOKEN 없으면 exit 3
assert_status 3 'env -u PDM_TOKEN bin/guard remote-migrate lab-vm-900 -- --to pve-01' "remote-migrate without PDM_TOKEN exits 3"
# --plan → PDM_TOKEN ref
assert_eq "PDM_TOKEN=bw://Proxmox-Datacenter-Manager pdm-01/api-token" "$(bin/guard --plan remote-migrate lab-vm-900)" "--plan remote-migrate → PDM_TOKEN ref"

finish; echo "PASS test_remote_migrate"
```

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_remote_migrate.sh`
Expected: FAIL — ACTIONS/`_backend`/`bin/pdm` remote-migrate 미구현.

- [ ] **Step 2: ACTIONS + `bin/pdm` 고수준 sub + `_backend` arm**

`homelab-ops/bin/_lib.sh` 의 `ACTIONS` 에서 `[disk-grow]="destructive host-ssh"` 줄 다음에 추가:

```bash
  [remote-migrate]="destructive pdm"
```

`homelab-ops/bin/pdm` 의 `case "$sub" in` 에서 `api)` arm 다음에 추가:

```bash
  remote-migrate)
    # 인자: <vmid> <to-node> [target-storage] [online(0/1)] [source-node]
    vmid="${2:?vmid}"; to="${3:?to-node}"; tstor="${4:-}"; online="${5:-0}"; src="${6:-}"
    # PDM 원격 마이그레이션 API path 는 인벤토리 구성형(운영자 PDM 버전 의존,
    # spec §5 known-unknown). 기본값은 PVE 노드 remote_migrate 형태.
    mp="$(jq -r --arg s "$src" '.access.api.migrate_path
          // ("/nodes/"+$s+"/qemu/{vmid}/remote_migrate")' <<<"$pe")"
    mp="${mp//\{vmid\}/$vmid}"
    d="target=${to}&online=${online}"
    [[ -n "$tstor" ]] && d="${d}&target-storage=${tstor}"
    resp="$(call POST "$mp" "$d")" || return $?
    printf '%s\n' "$resp"
    tid="$(jq -r 'if (.data|type)=="string" then .data else empty end' <<<"$resp" 2>/dev/null || true)"
    [[ -n "$tid" ]] || die "remote-migrate: PDM 가 task id 를 반환하지 않음: $resp"
    pdm_wait_task "$tid" ;;
```

`homelab-ops/bin/_backend` 의 `disk-grow:*)` arm 다음, `pkg-install:*)` 앞에 추가:

```bash
  remote-migrate:*)
    to=""; tstor=""; online=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --to) to="${2:-}"; shift 2 ;;
        --target-storage) tstor="${2:-}"; shift 2 ;;
        --online) online=1; shift ;;
        *) shift ;;
      esac
    done
    vmid="$(jq -r '.vmid // empty' <<<"$inv")"
    [[ -n "$vmid" ]] || die "remote-migrate: target '$target' has no vmid"
    [[ -n "$to" ]] || die "remote-migrate: --to <target-node> 필요"
    src="$(owner_host "$target")"
    if [[ $dry -eq 1 ]]; then
      echo "DRY-RUN: remote-migrate $target vmid=$vmid src=$src to=$to storage=${tstor:-<same>} online=$([[ $online -eq 1 ]] && echo true || echo false)"
      echo "  (PDM 경유; 실 PDM API path 는 인벤토리 access.api.migrate_path 로 확정 — spec §5)"
      exit 0
    fi
    "$HERE/pdm" remote-migrate "$vmid" "$to" "$tstor" "$online" "$src" ;;
```

- [ ] **Step 3: 통과 + 패리티/회귀**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/test_remote_migrate.sh && bash tests/test_action_table.sh && bash tests/run.sh`
Expected: `PASS test_remote_migrate`, `PASS test_action_table`(remote-migrate 테이블+backend), `ALL TESTS PASSED`.

> 패리티 direction-2 는 `_backend` 에서 `[a-z][a-z-]*:\*` 로 verb 추출 → `remote-migrate:*` 매치(하이픈 포함 패턴). ACTIONS 에 `remote-migrate` 존재하므로 통과. `bin/pdm` 의 `remote-migrate)` sub 는 _backend arm 이 아니므로 패리티 grep 대상 아님(정상).

- [ ] **Step 4: 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/bin/_lib.sh homelab-ops/bin/pdm homelab-ops/bin/_backend homelab-ops/tests/test_remote_migrate.sh
git -C /home/altair823/claude-skills commit -m "feat(homelab-ops): remote-migrate verb (pdm transport, PDM task 폴링, dry-run)"
```

---

### Task 10: `bin/pdm` known-unknown 게이트 확인 (실 path 확정 또는 fallback 보고)

**Files:** (코드 변경 없음 — 검증·보고 Task)

- [ ] **Step 1: PDM API path 확정 시도**

다음을 수행하고 결과를 **컨트롤러에 보고**(이 Task 는 코드 변경이 아니라 결정 게이트):

1. `homelab-ops/bin/pdm` 와 `pdm_wait_task` 의 인벤토리 구성점 3개를 명시: `access.api.base_path`(기본 `/api2/json`), `access.api.task_status_path`(기본 `/tasks`), `access.api.migrate_path`(기본 `/nodes/{src}/qemu/{vmid}/remote_migrate`).
2. 운영자 PDM 버전의 API 문서(또는 PDM `/api2/json` 디스커버리)로 위 3개의 실제 값을 확인 가능한지 판단. **확인 가능**하면: `homelab-ops/inventory/fleet.example.yaml` 의 `kind: pdm` 예시 엔트리 주석에 확정값을 기록(운영자가 실 인벤토리에 반영). 코드는 이미 구성형이라 변경 불필요. **확인 불가**(문서 부재·환경 접근 불가)하면: spec §5 fallback 발동 권고를 컨트롤러에 보고 — remote-migrate 관련(Task 9 커밋)을 별도 보류 처리할지 결정 위임. 임의 추정값 커밋 금지.

- [ ] **Step 2: 결과 보고**

Status 와 함께: 확정값(있으면) / 또는 "PDM path 확정 불가 → fallback 결정 필요" 를 명확히 보고. (코드/테스트는 Task 9 에서 이미 계약 검증됨 — 본 Task 는 실 path 정합성 결정 게이트일 뿐, 커밋 없음.)

---

### Task 11: `fleet.example.yaml` 에 `kind: pdm` + disk serial 예시

**Files:**
- Modify: `homelab-ops/inventory/fleet.example.yaml`

- [ ] **Step 1: 예시 인벤토리에 PDM 엔트리 + serial 예시 추가**

`homelab-ops/inventory/fleet.example.yaml` 끝에 추가(주석 포함):

```yaml

# PDM (Proxmox Datacenter Manager) — remote-migrate transport 의 단일 출처.
# 정확히 1개. address 에 :port 포함 가능. base_path/task_status_path/
# migrate_path 는 운영자 PDM 버전에 맞춰 조정(미지정 시 아래 기본값).
- id: pdm-01
  kind: pdm
  address: pdm.example.lan:8443
  env: prod
  access:
    api:
      token_ref: "bw://Proxmox-Datacenter-Manager pdm-01/api-token"
      ca_path: "inventory/ca/pdm-01-ca.pem"
      # base_path: "/api2/json"
      # task_status_path: "/tasks"
      # migrate_path: "/nodes/{src}/qemu/{vmid}/remote_migrate"
  tags: []
```

그리고 기존 예시 게스트(vm 엔트리) 하나에 disk-attach serial opt-in 예시 주석 추가 — 해당 vm 엔트리의 `access:` 줄 앞에 추가:

```yaml
  # disk-attach 물리 패스스루를 허용할 디스크의 안정 식별 serial (opt-in).
  # 미선언 시 disk-attach 거부(아무 디스크나 패스스루 차단).
  disks:
    - serial: "CHANGE-ME-DISK-SERIAL"
```

- [ ] **Step 2: 회귀 (예시 파일은 테스트 미사용 — 단순 확인) + 커밋**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (fleet.example.yaml 은 테스트가 안 읽음 — 회귀 불변 확인).

```bash
git -C /home/altair823/claude-skills add homelab-ops/inventory/fleet.example.yaml
git -C /home/altair823/claude-skills commit -m "docs(homelab-ops): fleet.example 에 kind:pdm 엔트리 + disk serial opt-in 예시"
```

---

### Task 12: SKILL.md 문서화(경계 완화·신규 verb·transport) + TODO.md + 최종 회귀/spec 커버리지

**Files:**
- Modify: `homelab-ops/SKILL.md`
- Modify: `homelab-ops/TODO.md`

- [ ] **Step 1: SKILL.md frontmatter description 에 신규 verb**

`homelab-ops/SKILL.md` 3행 `description:` 의 `start/stop/restart/snapshot, destroy, backup, or Phase-1 provisioning (clone)` 를 아래로 교체:

```
start/stop/restart/snapshot, destroy, backup, disk-attach/detach, disk-grow, PDM remote-migrate, or Phase-1 provisioning (clone)
```

- [ ] **Step 2: "Not for:" 경계 완화 + When to use 불릿**

`homelab-ops/SKILL.md` 의 `Not for:` 줄(현재 `Not for: non-Proxmox virt, Proxmox cluster/HA/migration (targets are independent hosts), or IaC (Phase 2, not yet).`)을 아래로 교체:

```
Not for: non-Proxmox virt, intra-cluster HA·live-migration·로컬 클러스터 migration, or IaC (Phase 2, not yet). (PDM 경유 노드 간 `remote-migrate` 는 지원 — 독립 노드 대상.)
```

`homelab-ops/SKILL.md` "When to use" 의 `"Provision a VM"` 불릿 앞에 추가:

```
- "물리 디스크 attach/detach (by-id)" → `"$HL/bin/guard" disk-attach <guest> -- --by-id /dev/disk/by-id/<id> [--index N]` (destructive; by-id 강제·serial opt-in)
- "게스트 디스크 확장" → `"$HL/bin/guard" disk-grow <guest> [-- --lv <vg/lv>]` (destructive; qm guest exec, 게스트 내부 LVM/FS 만 — PVE 가상디스크 사전 확장 전제)
- "노드 간 이전 (PDM)" → `"$HL/bin/guard" remote-migrate <guest> -- --to <node> [--target-storage <map>] [--online]` (destructive; PDM 경유)
```

`homelab-ops/SKILL.md` Inventory 절의 발견 순서 블록 다음(Per-host CA 불릿 앞)에 추가:

```
- **PDM 엔트리.** `remote-migrate` 는 인벤토리에 `kind: pdm` 엔트리(정확히 1개:
  `address`[:port], `access.api.token_ref`→`PDM_TOKEN`, `ca_path`, 선택
  `base_path`/`task_status_path`/`migrate_path`)가 필요하다. `bin/pdm` 가 단일
  출처로 해석.
- **host-ssh transport.** `disk-attach`/`disk-detach`/`disk-grow` 는 게스트가
  target 이지만 **owner Proxmox 노드에 root SSH** 로 실행(`qm set`/`qm guest
  exec`). 자격은 owner_host 엔트리의 `access.ssh`. disk-attach 는 게스트
  엔트리 `disks[].serial` opt-in 선언 필요.
```

- [ ] **Step 3: TODO.md 갱신 (#2/#4 해소·PDM-disk-attach future-probe·런타임 블로커)**

`homelab-ops/TODO.md` 의 `## 진행 상태 (2026-05-18 하드닝 spec)` 절 끝에 추가:

```markdown

## 진행 상태 (2026-05-18 guard verb 확장 spec)
- `disk-attach`/`disk-detach`(host-ssh, by-id 강제+serial opt-in)·`disk-grow`
  (host-ssh→qm guest exec)·`remote-migrate`(pdm)·인터럽트-UPID 캡처는
  `docs/superpowers/specs/2026-05-18-homelab-ops-guard-verbs-design.md` 로 처리.
  → TODO #2(disk-attach), #4(disk-grow) 코드/stub 완결.
- **런타임 블로커(코드 아님, 운영자 데이터 작업)**: owner 노드 root SSH 자격
  vault 등록(disk-*); 대상 게스트 guest-agent 동작(disk-grow); 인벤토리
  `kind: pdm` 엔트리 작성(remote-migrate; PDM 토큰은 보유).
- **PDM-disk-attach future-probe**: PDM 노드 연결 자격이 root@pam 이면 임의
  fs 경로 패스스루가 PDM 경유로 풀릴 가능성 — host-ssh 가 known-correct
  기본, PDM 경로는 실측 후 검토.
- **PDM API path known-unknown**: `bin/pdm` 의 base_path/task_status_path/
  migrate_path 는 인벤토리 구성형. 운영자 PDM 버전으로 실값 확정 필요
  (Task 10 게이트 결과 반영).
```

- [ ] **Step 4: 최종 전체 회귀 + spec 커버리지 자체 점검**

Run: `cd /home/altair823/claude-skills/homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` — 다음 포함:
test_action_table, test_backup, test_disk_attach, test_disk_grow, test_forensic_sufficiency, test_forensics, test_guard_exec, test_guard_grade, test_guard_intr_upid, test_guard_plan, test_guard_signal, test_guard_task_audit, test_harness, test_inv, test_lib, test_mask_parity, test_pdm, test_provision, test_pve, test_pve_wait, test_remote_migrate, test_ssh_run.

`docs/superpowers/specs/2026-05-18-homelab-ops-guard-verbs-design.md` 를 다시 읽고 각 절↔Task 매핑 확인:
- §1 transport 인프라 = Task 1–3
- §2 인터럽트-UPID = Task 4
- §3 disk-attach/detach = Task 5–6
- §4 disk-grow = Task 7–8
- §5 remote-migrate = Task 9–10(+11 예시)
- §SKILL.md 경계/문서 = Task 12
- 후속(TODO 기록) = Task 12
누락 발견 시 Task 추가.

- [ ] **Step 5: 최종 커밋**

```bash
git -C /home/altair823/claude-skills add homelab-ops/SKILL.md homelab-ops/TODO.md
git -C /home/altair823/claude-skills commit -m "docs(homelab-ops): 경계 완화(PDM remote-migrate)·신규 verb·transport 문서화 + TODO 갱신"
```

---

## 완료 기준 (Definition of Done)

- `cd homelab-ops && bash tests/run.sh` → `ALL TESTS PASSED` (~22 test 파일, 신규 5: test_pdm, test_guard_intr_upid, test_disk_attach, test_disk_grow, test_remote_migrate).
- 단일 출처 `ACTIONS` 에 `disk-attach`/`disk-detach`/`disk-grow`/`remote-migrate` 등록, transport 어휘 `host-ssh`/`pdm` 1급, 패리티 테스트가 드리프트 차단.
- 자격 게이트·`--plan` 이 `host-ssh`→owner_host ssh ref, `pdm`→`PDM_TOKEN` 정확 산출, 부재 시 exit 3.
- disk-attach: by-id 강제·serial opt-in·적용 전 serial 실대조·dry-run 미적용. disk-detach: destructive·dry-run. disk-grow: 자동탐지·다중LV/미지원FS 거부·guest-agent 의존·dry-run 시퀀스·PVE-디스크 범위밖 명시. remote-migrate: pdm 경유·PDM task 폴링·dry-run.
- 인터럽트(INT/TERM) 시 감사 1건 + raw UPID 캡처(`task_exitstatus` null), 정상 경로 회귀 없음.
- `bin/pdm` PDM path 구성점이 인벤토리화, Task 10 게이트에서 실값 확정/또는 fallback 보고.
- SKILL.md 경계 완화·신규 verb·transport·인벤토리 문서화, TODO.md 갱신, 후속/런타임 블로커 명문화.
