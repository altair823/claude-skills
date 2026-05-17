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
    -e 's/((PVE_TOKEN|HL_SSH_KEY|HL_SSH_PASS|SSHPASS)=)[^[:space:]]+/\1***MASKED***/g' \
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
#   transport: none | pve | ssh | guest
#     guest = 대상 kind 가 proxmox-host/vm/lxc 면 pve, 그 외(appliance 등)면 ssh
# guard(등급)·_backend(라우팅)·op_transport(자격)·--plan 이 모두 이 테이블만
# 본다. drift 는 tests/test_action_table.sh 패리티 테스트가 차단할 예정(Task 3)이다(과거의
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
