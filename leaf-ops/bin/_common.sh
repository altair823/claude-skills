# leaf-ops 공통 — 각 스크립트가 source 한다.
#
# 자격증명은 여기서만 읽고 밖으로 내보내지 않는다. curl 에 넘길 때도
# argv 가 아니라 --netrc-file 로 준다. argv 는 /proc 에서 누구나 읽는다.
set -euo pipefail

CONFIG="${LEAF_CONFIG:-$HOME/.config/leaf-ops/config}"

die() { echo "leaf-ops: $*" >&2; exit 1; }

# LEAF_AUTH 는 환경변수가 설정 파일보다 우선한다. 에이전트마다 다른 토큰을
# 주고 싶을 때 쓴다 — 그래야 대시보드의 "올린 주체"가 실제로 누구인지 가린다.
if [ -n "${LEAF_AUTH:-}" ]; then
  _auth="$LEAF_AUTH"
  LEAF_URL="${LEAF_URL:-$( [ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null; echo "${LEAF_URL:-}" )}"
else
  [ -f "$CONFIG" ] || die "설정이 없습니다: $CONFIG (LEAF_URL 과 LEAF_AUTH 를 적으세요)"
  # shellcheck disable=SC1090
  . "$CONFIG"
  _auth="${LEAF_AUTH:-}"
fi
[ -n "${LEAF_URL:-}" ] || die "LEAF_URL 이 비어 있습니다"
[ -n "$_auth" ] || die "LEAF_AUTH 가 비어 있습니다 (형식: 이름:비밀값)"
case "$_auth" in *:*) ;; *) die "LEAF_AUTH 형식이 이름:비밀값 이어야 합니다";; esac

LEAF_URL="${LEAF_URL%/}"
_host=$(printf %s "$LEAF_URL" | sed -E 's#^https?://##; s#/.*##; s#:.*##')

# netrc 를 임시 파일로 만들어 curl 에 넘긴다. 종료 시 지운다.
_netrc=$(mktemp); chmod 600 "$_netrc"
trap 'rm -f "$_netrc"' EXIT
printf 'machine %s login %s password %s\n' \
  "$_host" "${_auth%%:*}" "${_auth#*:}" > "$_netrc"
unset _auth

# leaf_curl <curl 인자...>
leaf_curl() { curl -sS --netrc-file "$_netrc" "$@"; }

# 사이트 이름 규칙은 서버와 같다. 여기서 미리 거르면 400 을 왕복하지 않는다.
valid_site() {
  printf %s "$1" | grep -qE '^[a-z0-9_-]{1,64}$' && [ "$1" != "_token" ]
}
