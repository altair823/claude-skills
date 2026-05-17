#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard 2>/dev/null || true

assert_eq "safe"        "$(bin/guard grade status vm-100)"       "status on non-critical = safe"
assert_eq "caution"     "$(bin/guard grade stop vm-100)"         "stop on plain vm = caution"
assert_eq "destructive" "$(bin/guard grade destroy vm-100)"      "destroy = destructive"
# critical tag escalates one level — but ONLY for ops that can mutate.
# Read-only safe ops (status/metrics/get/list/inventory) are NEVER escalated:
# observability of your most important hosts must not require --approve.
assert_eq "safe"        "$(bin/guard grade status pve-01)"       "status on critical stays safe (read-only exempt)"
assert_eq "safe"        "$(bin/guard grade metrics pve-01)"      "metrics on critical stays safe"
assert_eq "safe"        "$(bin/guard grade get pve-01)"          "get on critical stays safe"
assert_eq "destructive" "$(bin/guard grade stop nas-01)"         "stop on critical = destructive (bumped)"
# deny-by-default: unknown action
assert_eq "destructive" "$(bin/guard grade frobnicate vm-100)"   "unknown action = destructive"
# provision is always destructive
assert_eq "destructive" "$(bin/guard grade provision lab-vm-900)" "provision = destructive"
# delete 는 destroy 의 별칭 → 동일 등급
assert_eq "destructive" "$(bin/guard grade delete vm-100)" "delete (alias) = destructive"
assert_eq "destructive" "$(bin/guard grade delete pve-01)" "delete on critical stays destructive"
# 유령 verb 는 테이블에 없음 → deny-default destructive (광고 제거돼도 안전 거부)
assert_eq "destructive" "$(bin/guard grade kill vm-100)"          "kill = destructive (deny-default)"
assert_eq "destructive" "$(bin/guard grade net-change vm-100)"    "net-change = destructive (deny-default)"
assert_eq "destructive" "$(bin/guard grade storage-remove vm-100)"  "storage-remove = destructive (deny-default)"
# destructive + critical stays destructive (the _bump *) branch)
assert_eq "destructive" "$(bin/guard grade destroy pve-01)" "destroy on critical stays destructive"
# empty action is rejected cleanly (not a raw bash array-subscript error)
assert_status 1 'bin/guard grade "" vm-100' "empty action exits 1"

finish; echo "PASS test_guard_grade"
