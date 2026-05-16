#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

cat > bin/_probe <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
case "$1" in
  parse) parse_ref "$2"; echo "$REF_ITEM|$REF_FIELD|$REF_KIND" ;;
  session) require_session; echo "session-ok" ;;
  mask) printf 'BW_SESSION=abc123 plain\n' | mask ;;
esac
EOF
chmod +x bin/_probe
trap 'rm -f bin/_probe' EXIT

assert_eq "i||password" "$(BW_SESSION=x bash bin/_probe parse 'bw://i')" "ref item-only → password"
assert_eq "i|api|field" "$(BW_SESSION=x bash bin/_probe parse 'bw://i/api')" "ref item/field → field"
assert_eq "i|notes|notes" "$(BW_SESSION=x bash bin/_probe parse 'bw://i/notes')" "ref notes → notes"
assert_status 1 'BW_SESSION=x bash bin/_probe parse plainstring' "non-bw:// ref rejected"
assert_status 3 'env -u BW_SESSION bash bin/_probe session' "locked vault → exit 3"
assert_eq "session-ok" "$(BW_SESSION=x bash bin/_probe session)" "BW_SESSION set → ok"
assert_not_contains "$(BW_SESSION=x bash bin/_probe mask)" "abc123" "mask hides BW_SESSION value"

finish
echo "PASS test_common"
