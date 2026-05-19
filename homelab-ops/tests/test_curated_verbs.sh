#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_backend bin/guard 2>/dev/null || true

# 등급 회귀
assert_eq "caution" "$(bin/guard grade service lab-vm-900)" "service caution"
assert_eq "caution" "$(bin/guard grade logs lab-vm-900)" "logs caution"
assert_eq "caution" "$(bin/guard grade pkg-update lab-vm-900)" "pkg-update caution"
assert_eq "caution" "$(bin/guard grade reboot lab-vm-900)" "reboot caution"

# dry-run 라우팅(미실행, exit 0)
assert_contains "$(bin/_backend service lab-vm-900 --dry-run -- restart sshd 2>&1)" "DRY-RUN" "service dry-run"
assert_contains "$(bin/_backend logs lab-vm-900 --dry-run -- --unit sshd -n 20 2>&1)" "DRY-RUN" "logs dry-run"
assert_contains "$(bin/_backend pkg-update lab-vm-900 --dry-run -- 2>&1)" "DRY-RUN" "pkg-update dry-run"
assert_contains "$(bin/_backend reboot lab-vm-900 --dry-run -- 2>&1)" "DRY-RUN" "reboot dry-run"

# 인자 화이트리스트: service 미지 서브커맨드 거부
assert_status 1 "bin/_backend service lab-vm-900 --dry-run -- frobnicate sshd" "service 미지 서브커맨드 거부"
# service unit 명 charset 거부
assert_status 1 "bin/_backend service lab-vm-900 --dry-run -- restart 'a;b'" "service unit charset 거부"

# IMPORTANT fix: service/reboot 은 ssh transport → --plan 이 HL_SSH_KEY 를 산출해야 함 (PVE_TOKEN 아님)
# lab-vm-900 은 kind:vm, access.ssh.key_ref=bw://ssh-lab-vm-900
assert_contains "$(env -u HL_SSH_KEY -u PVE_TOKEN bin/guard --plan service lab-vm-900 2>&1)" \
  "HL_SSH_KEY=" "service --plan resolves ssh cred (not PVE_TOKEN)"
assert_contains "$(env -u HL_SSH_KEY -u PVE_TOKEN bin/guard --plan reboot lab-vm-900 2>&1)" \
  "HL_SSH_KEY=" "reboot --plan resolves ssh cred (not PVE_TOKEN)"

# MINOR 4: logs --file '..' 경로 구성요소 거부
assert_status 1 "bin/_backend logs lab-vm-900 --dry-run -- --file /var/../etc/shadow" "logs --file .. 거부"

# MINOR 7: logs guard-branch 커버리지
# -n 비정수 → die 1
assert_status 1 "bin/_backend logs lab-vm-900 --dry-run -- -n abc --unit sshd" "logs -n 비정수 거부"
# --unit 도 --file 도 없음 → die 1
assert_status 1 "bin/_backend logs lab-vm-900 --dry-run --" "logs --unit/--file 없음 거부"
# --unit charset 위반 → die 1
assert_status 1 "bin/_backend logs lab-vm-900 --dry-run -- --unit 'a;b'" "logs --unit charset 위반 거부"

finish; echo "PASS test_curated_verbs"
