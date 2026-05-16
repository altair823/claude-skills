# shellcheck shell=bash
# Shared helpers for bitwarden-ops. Sourced by every bin/ script, not executed.
# Requires: bw, jq. Single rule: a secret value never reaches Claude/argv/disk/log.
set -euo pipefail

die() { echo "bitwarden-ops: $*" >&2; exit "${BW_EXIT:-1}"; }

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

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "필수 명령 없음: $c"
  done
}

# Refuse before doing anything if the vault is locked (no session via env OR file).
require_session() {
  [[ -n "${BW_SESSION:-}" ]] || BW_EXIT=3 die \
    "locked vault: 세션 없음 — 사용자가 본인 터미널에서 'bw-unlock' 실행 (또는 export BW_SESSION=\"\$(bw unlock --raw)\")"
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

# Session-file fallback (design: 2026-05-16-bitwarden-ops-session-persistence).
# env-wins: only when BW_SESSION is empty do we adopt a non-empty session file.
# Runs at source time so every bin/* script (incl. bw-status, which reads
# BW_SESSION directly) benefits with no per-script change. `-s` treats an
# empty file as absent. $(<file) is used (no pipeline under pipefail).
# Note: BW_SESSION="" (set but empty) is treated the same as unset — the file
# is adopted. Use `env -u BW_SESSION` to explicitly suppress the file fallback.
if [[ -z "${BW_SESSION:-}" ]]; then
  _bwo_cd="$(bwo_cache_dir)"
  if [[ -n "$_bwo_cd" && -s "$_bwo_cd/session" ]]; then
    # -s is stat-based: a non-empty file can still be unreadable (foreign owner,
    # NFS, container). Without this guard $(<file) would fail under errexit and
    # abort the sourcing script with a bare shell error instead of a clear one.
    [[ -r "$_bwo_cd/session" ]] || BW_EXIT=3 die \
      "세션 파일 읽기 불가: $_bwo_cd/session (권한/소유 오류) — bw-unlock 재실행"
    export BW_SESSION="$(<"$_bwo_cd/session")"
  fi
  unset _bwo_cd
fi
