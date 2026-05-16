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
