#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

assert_eq "a" "a" "assert_eq works"
assert_contains "hello world" "world" "assert_contains works"
assert_status 0 'true' "assert_status 0 works"
assert_status 3 'exit 3' "assert_status 3 works"

# bw stub: deterministic, file-backed, on PATH via lib.sh.
export BW_STUB_DB="$(mktemp)"; echo '[]' > "$BW_STUB_DB"
assert_eq "unlocked" "$(bw status | jq -r .status)" "stub status unlocked"
bw sync >/dev/null; assert_eq "0" "$([[ -f "$BW_STUB_DB.synced" ]]; echo $?)" "stub sync marks synced"
rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"

finish
echo "PASS test_harness"
