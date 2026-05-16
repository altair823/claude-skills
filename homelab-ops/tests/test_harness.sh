#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

assert_eq "ab" "ab" "eq works"
assert_contains "hello world" "lo wo" "contains works"
assert_status 0 true "status 0 works"
assert_status 3 'bash -c "exit 3"' "status 3 works"

# stubs must be deterministic and on PATH via run.sh; check shape directly:
PATH="$PWD/tests/stubs:$PATH"
out="$(bw get password "x" --session s)"
[[ "$out" == "stub-secret-x" ]] || { echo "FAIL: bw stub"; exit 1; }

finish
echo "PASS test_harness"
