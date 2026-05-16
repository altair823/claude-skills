#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"; echo '[]' > "$BW_STUB_DB"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT

out="$(BW_SESSION=x bash bin/bw-status)"
assert_contains "$out" "session=set" "status shows session set"
assert_contains "$out" "vault=unlocked" "status shows unlocked"
assert_status 0 'BW_SESSION=x bash bin/bw-status' "unlocked+session → exit 0"

assert_status 3 'env -u BW_SESSION bash bin/bw-status' "no session → exit 3"
out2="$(env -u BW_SESSION bash bin/bw-status 2>&1 || true)"
assert_contains "$out2" "session=unset" "status shows session unset"

finish
echo "PASS test_status"
