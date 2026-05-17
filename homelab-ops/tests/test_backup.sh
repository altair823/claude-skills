#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend 2>/dev/null || true
export PVE_TOKEN="stub-token-value"

# 등급: backup = caution
assert_eq "caution" "$(bin/guard grade backup vm-100)" "backup graded caution"

# dry-run: 실행 없이 대상/스토리지/모드 출력, exit 0
out="$(bin/_backend backup vm-100 --dry-run -- local-zfs snapshot zstd)"
assert_contains "$out" "DRY-RUN: would vzdump vm-100" "backup dry-run announces target"
assert_contains "$out" "storage=local-zfs" "backup dry-run echoes storage"
assert_status 0 'bin/_backend backup vm-100 --dry-run -- local-zfs' "backup dry-run exits 0"

# caution+prod(vm-100) → 승인 없이는 exit 10 (dry-run 표시)
set +e; o="$(bin/guard backup vm-100 -- local-zfs 2>&1)"; rc=$?; set -e
assert_eq "10" "$rc" "backup on prod needs --approve"
assert_contains "$o" "DRY-RUN" "backup prod shows dry-run"

# caution+lab(lab-vm-900) + 승인 경로: vzdump POST + UPID 폴링
out="$(bin/guard backup lab-vm-900 -- local-zfs snapshot zstd)"
assert_contains "$out" "HO-TASK upid=UPID:stub" "backup polls vzdump task"

# 자격 게이트: backup transport=pve → PVE_TOKEN 없으면 exit 3
assert_status 3 'env -u PVE_TOKEN bin/guard backup lab-vm-900 -- local-zfs' "backup without PVE_TOKEN exits 3"

# --plan: backup → 소유 호스트 PVE_TOKEN ref
assert_eq "PVE_TOKEN=bw://Proxmox pve-01/api-token" "$(bin/guard --plan backup vm-100)" "backup --plan → owner PVE_TOKEN"

finish; echo "PASS test_backup"
