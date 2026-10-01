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
  # username, password, notes는 예약어다. username과 password는 로그인 값이 있으면 그것을,
  # 비어 있으면 같은 이름의 사용자 정의 필드를 쓴다(bw-get).
  case "$REF_FIELD" in
    ""|password) REF_KIND=password ;;
    notes)       REF_KIND=notes ;;
    username)    REF_KIND=username ;;
    *)           REF_KIND=field ;;
  esac
}

# 항목 JSON에서 종류 이름(kind)과 쓸 수 있는 참조 이름 목록(refs)을 구하는 jq 정의.
# 이름만 다루고 값은 출력하지 않는다. bw-get 오류 메시지와 bw-ls가 함께 쓴다.
BWO_JQ_DEFS='
def kind: {"1":"login","2":"note","3":"card","4":"identity","5":"ssh"}[.type|tostring] // "type\(.type)";
def refs: [ (if (.login.username // "") != "" then "username" else empty end),
            (if (.login.password // "") != "" then "password" else empty end),
            (if (.notes // "") != "" then "notes" else empty end),
            (.fields[]?.name) ];
'

# bw_call <실패 메시지> <bw 인자...>: bw를 실행하고 stdout을 그대로 내보낸다.
# 읽기 명령 전용이다. 실패하면 같은 명령을 한 번 더 실행하므로 create나 edit에 쓰면 두 번 실행된다.
# 실패하면 원인을 알기 위해 같은 명령을 한 번 더 실행해 stderr만 받는다(stdout은 버린다).
# 잠긴 금고나 만료된 세션은 exit 3, 검색 결과가 여럿이면 그 사실을, 나머지는 주어진 메시지를 출력한다.
# 사용: out="$(bw_call "<메시지>" get item X)" || exit $?
bw_call() {
  local msg="$1" err; shift
  # 세션 키는 export된 BW_SESSION 환경변수로 bw에 넘긴다. --session 인자로 주면 ps에 보인다.
  # --nointeraction: 세션이 만료되었을 때 bw가 마스터 비밀번호를 묻지 않고 실패하게 한다.
  bw "$@" --nointeraction 2>/dev/null && return 0
  err="$(bw "$@" --nointeraction 2>&1 >/dev/null || true)"
  case "$err" in
    *[Ll]ocked*|*"not logged in"*)
      BW_EXIT=3 die "locked vault: 세션이 만료되었거나 금고가 잠겨 있습니다. 사용자가 본인 터미널에서 'bw-unlock'을 실행해야 합니다." ;;
    *"More than one"*)
      die "검색 결과가 여러 항목입니다. bw-ls로 정확한 항목 이름을 확인하세요." ;;
  esac
  die "$msg"
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
