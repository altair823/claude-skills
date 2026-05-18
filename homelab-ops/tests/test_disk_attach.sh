#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend 2>/dev/null || true
export PVE_TOKEN="stub-token-value" HL_SSH_KEY="stub-key"

# 등급: disk-attach / disk-detach = destructive
assert_eq "destructive" "$(bin/guard grade disk-attach lab-vm-900)" "disk-attach destructive"
assert_eq "destructive" "$(bin/guard grade disk-detach lab-vm-900)" "disk-detach destructive"

# by-id 강제: /dev/sdX 거부 (dry-run 에서도)
o="$(bin/_backend disk-attach lab-vm-900 --dry-run -- --by-id /dev/sdb 2>&1 || true)"
assert_contains "$o" "by-id" "non-by-id 경로 거부 메시지"
assert_not_contains "$o" "qm set" "거부 시 qm 명령 미형성"

# serial 미선언 게스트(vm-100, disks 없음) → 거부
o="$(bin/_backend disk-attach vm-100 --dry-run -- --by-id /dev/disk/by-id/wwn-0xLAB 2>&1 || true)"
assert_contains "$o" "serial" "serial 미선언 게스트 거부"

# dry-run 정상: by-id + serial 선언된 lab-vm-900, 미적용·명령 echo·exit 0
o="$(bin/_backend disk-attach lab-vm-900 --dry-run -- --by-id /dev/disk/by-id/wwn-0xLAB --index 1 2>&1)"
assert_contains "$o" "DRY-RUN" "attach dry-run 헤더"
assert_contains "$o" "qm set 900 -scsi1 /dev/disk/by-id/wwn-0xLAB,backup=0,iothread=1" "attach 명령 형성(echo만)"
assert_status 0 'bin/_backend disk-attach lab-vm-900 --dry-run -- --by-id /dev/disk/by-id/wwn-0xLAB' "attach dry-run exit 0"

# detach dry-run
o="$(bin/_backend disk-detach lab-vm-900 --dry-run -- --index 1 2>&1)"
assert_contains "$o" "qm set 900 -delete scsi1" "detach 명령 형성(echo만)"

# transport host-ssh: PVE_TOKEN 무관, owner_host 의 HL_SSH_KEY 게이트
assert_eq "destructive host-ssh" "$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[disk-attach]}"')" "ACTIONS[disk-attach]=destructive host-ssh"
assert_status 3 'env -u HL_SSH_KEY -u HL_SSH_PASS PVE_TOKEN=x bin/guard disk-attach lab-vm-900 -- --by-id /dev/disk/by-id/wwn-0xLAB' "host-ssh 게이트: owner_host ssh 자격 없으면 exit 3"

finish; echo "PASS test_disk_attach"
