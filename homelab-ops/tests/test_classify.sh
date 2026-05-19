#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_classify 2>/dev/null || true
C() { bin/_classify "$@"; }   # prints "grade<TAB>rule"

# 메타문자 → destructive
assert_eq "destructive	metachar" "$(C guest -- sh -c 'rm -rf /')" "sh -c → metachar"
assert_eq "destructive	metachar" "$(C guest -- ls\; rm)" "세미콜론 → metachar"
assert_eq "destructive	metachar" "$(C node -- cat /etc/x \&\& reboot)" "&& → metachar"
# 미지 바이너리 → fallback-deny
assert_eq "destructive	fallback-deny" "$(C guest -- frobnicate --now)" "미지 바이너리 → fallback-deny"

# Regression: --method as last arg must not crash (shift 2 over-shift bug)
assert_eq "destructive	pve-write" "$(bin/_classify pve --method)" "--method as last arg: no crash, pve-write"
assert_eq "destructive	pve-write" "$(bin/_classify pve --method POST --path /x)" "pve POST → pve-write"
assert_eq "caution	pve-get" "$(bin/_classify pve --method GET --path /x)" "pve GET → pve-get"
# Regression: unknown via must emit invalid-via, not fall through silently
assert_eq "destructive	invalid-via" "$(bin/_classify bogus -- ls)" "unknown via → invalid-via"
# Regression: --method last arg exits 0 (no set -e abort)
assert_status 0 'bin/_classify pve --method' "--method last arg exits 0 (no set -e abort)"

finish; echo "PASS test_classify"
