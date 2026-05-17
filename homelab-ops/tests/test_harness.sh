#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

assert_eq "ab" "ab" "eq works"
assert_contains "hello world" "lo wo" "contains works"
assert_status 0 true "status 0 works"
assert_status 3 'bash -c "exit 3"' "status 3 works"

finish
echo "PASS test_harness"
