#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"; echo '[]' > "$BW_STUB_DB"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT

out="$(BW_SESSION=x bash bin/bw-sync)"
assert_contains "$out" "동기화 완료" "announces sync"
[[ -f "$BW_STUB_DB.synced" ]] && echo "  ok: bw sync invoked" \
  || { echo "  FAIL: bw sync not invoked"; exit 1; }

rm -f "$BW_STUB_DB.synced"
assert_status 3 'env -u BW_SESSION bash bin/bw-sync' "locked vault → exit 3"
[[ ! -f "$BW_STUB_DB.synced" ]] && echo "  ok: no sync when locked" \
  || { echo "  FAIL: synced without session"; exit 1; }
assert_status 3 'BW_SESSION=x BW_STUB_STATUS=locked bash bin/bw-sync' "expired session → exit 3"

finish
echo "PASS test_sync"
