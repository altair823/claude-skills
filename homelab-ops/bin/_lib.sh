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
