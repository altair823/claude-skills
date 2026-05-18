# shellcheck shell=bash
# Sourced by every bin/ command. Not a standalone executable.
# NOTE: REPO_ROOT uses BASH_SOURCE; do not symlink this file (a symlink would
# misresolve REPO_ROOT). Callers reach it via the repo's real bin/ path.
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

# Mask secret-shaped content on a text stream (last defense before run-log writes).
# GNU sed. Rules: full PEM private-key blocks, BW_SESSION=, Authorization headers
# (Bearer/Token/etc), JSON/kv token|password|secret|api-token, PVEAPIToken=, and
# long base64 blobs. Conservative — prefer over-masking to a leak.
mask() {
  sed -E \
    -e '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/{ s/.*/***MASKED-PRIVATE-KEY***/ }' \
    -e 's/(BW_SESSION=)[^[:space:]]+/\1***MASKED***/g' \
    -e 's/((PVE_TOKEN|PDM_TOKEN|HL_SSH_KEY|HL_SSH_PASS|SSHPASS)=)[^[:space:]]+/\1***MASKED***/g' \
    -e 's/(Authorization:[[:space:]]*[A-Za-z]+[[:space:]]+)[^[:space:]]+/\1***MASKED***/gI' \
    -e 's/(("?)(token|password|secret|api[_-]?token)("?)[[:space:]]*[:=][[:space:]]*"?)[^",[:space:]]+/\1***MASKED***/gI' \
    -e 's/(PVEAPIToken[^=]*=)[^[:space:]]+/\1***MASKED***/g' \
    -e 's/[A-Za-z0-9+\/]{40,}={0,2}/***MASKED-BLOB***/g'
}

# Append exactly one JSON object to the append-only audit log.
# Usage: audit_append <jq-args...> '<jq-filter producing the object>'
# Fails LOUD (die) if jq errors — a missing/garbled audit record is never silent.
# The filter MUST produce exactly one object; partial writes on jq error are not prevented.
audit_append() {
  mkdir -p "$(dirname "$AUDIT_LOG")"
  jq -c -n "$@" >> "$AUDIT_LOG" || die "audit_append: jq failed (args: $*)"
}

run_log_path() { # <op-id> -> path (creates session run dir)
  [[ -n "${1:-}" ]] || die "run_log_path: op-id required"
  mkdir -p "$RUNS_DIR/$HOMELAB_SESSION_ID"
  echo "$RUNS_DIR/$HOMELAB_SESSION_ID/$1.log"
}

# ── Single source of truth: action → "<grade> <transport>" ───────────────
#   grade:     safe | caution | destructive
#   transport: none | pve | ssh | guest | host-ssh | pdm
#     guest    = 대상 kind 가 proxmox-host/vm/lxc 면 pve, 그 외(appliance 등)면 ssh
#     host-ssh = owner_host(target) 에 root SSH (자격·실행 대상이 owner 노드)
#     pdm      = kind:pdm 인벤토리 엔트리 경유 (bin/pdm, PDM_TOKEN)
# guard(등급)·_backend(라우팅)·op_transport(자격)·--plan 이 모두 이 테이블만
# 본다. drift 는 tests/test_action_table.sh 패리티 테스트가 차단한다(과거의
# "3곳 수동 동기" 주석 계약을 대체). 새 verb 는 여기 + backend + (필요시)
# bin/pve verb arm 을 함께 추가하고 패리티 테스트가 녹색인지 확인할 것.
declare -gA ACTIONS=(
  [status]="safe none"        [list]="safe none"      [metrics]="safe none"
  [get]="safe none"           [inventory]="safe none"
  [start]="caution guest"     [stop]="caution guest"  [restart]="caution guest"
  [snapshot]="caution guest"  [pkg-install]="caution ssh"
  [backup]="caution pve"
  [disk-attach]="destructive host-ssh"  [disk-detach]="destructive host-ssh"
  [provision]="destructive pve"  [destroy]="destructive guest"
)
declare -gA ACTION_ALIASES=( [delete]="destroy" )

# 테스트 전용 확장점: ACTIONS 에 probe 액션을 병합. 안전장치 2겹 —
#  (1) 테스트 하니스 sentinel _HL_TEST_HARNESS 와 _HL_EXTRA_ACTIONS 가 동시
#      존재할 때만 동작(운영자 env 우발/악의 주입 차단).
#  (2) key 는 반드시 __probe_ prefix — 실 액션(stop/destroy/...) 의 grade·
#      transport 를 절대 덮어쓸 수 없음(Rule 4 우회 불가, safe-by-construction).
# 운영 경로에서는 sentinel unset → 완전 무영향(패리티/단일출처 계약 불변).
if [[ -n "${_HL_TEST_HARNESS:-}" && -n "${_HL_EXTRA_ACTIONS:-}" ]]; then
  _IFS_SAVE="$IFS"; IFS=';'
  for _kv in $_HL_EXTRA_ACTIONS; do
    case "${_kv%%=*}" in
      __probe_*) ACTIONS["${_kv%%=*}"]="${_kv#*=}" ;;
      *) echo "homelab-ops: _HL_EXTRA_ACTIONS 는 __probe_ prefix 키만 허용 (무시: ${_kv%%=*})" >&2 ;;
    esac
  done
  IFS="$_IFS_SAVE"; unset _kv _IFS_SAVE
fi

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

# op_transport <action> <kind> -> pve | ssh | host-ssh | pdm | none  (테이블 둘째 토큰 해석)
op_transport() {
  local a; a="$(canon_action "${1:?op_transport: action required}")"
  local kind="${2:-}" spec t
  spec="${ACTIONS[$a]:-}"
  if [[ -z "$spec" ]]; then echo none; return; fi
  t="${spec##* }"
  case "$t" in
    none|pve|ssh|host-ssh|pdm) echo "$t" ;;
    guest) case "$kind" in proxmox-host|vm|lxc) echo pve ;; *) echo ssh ;; esac ;;
    *) echo none ;;
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

# pdm_entry -> 인벤토리의 유일한 kind:pdm 엔트리 id. 0개/2개 이상이면 die.
# remote-migrate transport(pdm) 의 자격·base URL 해석 단일 출처.
pdm_entry() {
  local x k hits=()
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
  [[ "$timeout"  =~ ^[0-9]+$ ]] || die "pve_wait_task: HOMELAB_TASK_TIMEOUT must be a non-negative integer (got: $timeout)"
  [[ "$interval" =~ ^[0-9]+$ ]] || die "pve_wait_task: HOMELAB_TASK_POLL_INTERVAL must be a non-negative integer (got: $interval)"
  while :; do
    resp="$("$REPO_ROOT/bin/pve" "$host" api GET "/nodes/${host}/tasks/${upid}/status" 2>/dev/null || true)"
    st="$(jq -r '.data.status // empty' <<<"$resp" 2>/dev/null || true)"
    if [[ "$st" == "stopped" ]]; then
      xs="$(jq -r '.data.exitstatus // "UNKNOWN"' <<<"$resp" 2>/dev/null || echo UNKNOWN)"
      printf 'HO-TASK upid=%s exitstatus=%s\n' "$upid" "$xs"
      if [[ "$xs" == "OK" ]]; then return 0; else return 1; fi
    fi
    if (( waited >= timeout )); then
      printf 'HO-TASK upid=%s exitstatus=%s\n' "$upid" "TIMEOUT"
      return 75
    fi
    sleep "$interval"
    waited=$(( waited + interval ))
  done
}

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
  tsp="$("$REPO_ROOT/bin/inv" get "$(pdm_entry)" 2>/dev/null | jq -r '.access.api.task_status_path // "/tasks"' 2>/dev/null || true)"
  tsp="${tsp:-/tasks}"
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
