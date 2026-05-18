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

# non-dry: ssh stub 가 owner_host 로 qm set argv 를 받는지 + 인젝션 거부
nd="$(mktemp -d)"
cat > "$nd/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh-args: $*" >> "${ND_LOG:?}"
case "$*" in
  *lsblk*SERIAL*|*SERIAL*lsblk*) echo '{"blockdevices":[{"serial":"WD-LABDISK-001"}]}' ;;  # serial 일치(Task6)
  *) echo stub-applied ;;
esac
EOF
chmod +x "$nd/ssh"
# ssh-add: nd-local 허용 stub (tests/stubs/ssh-add 는 PEM 검증; non-dry 에서는 관대하게)
cat > "$nd/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$nd/ssh-add"
# ssh-agent: nd-local 허용 stub
cat > "$nd/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/nd-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99998; export SSH_AGENT_PID;'
EOF
chmod +x "$nd/ssh-agent"
ndlog="$(mktemp)"
out="$(ND_LOG="$ndlog" PATH="$nd:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-attach lab-vm-900 -- --by-id /dev/disk/by-id/wwn-0xLAB --index 2 2>&1)"
assert_contains "$(cat "$ndlog")" "qm set 900 -scsi2 /dev/disk/by-id/wwn-0xLAB,backup=0,iothread=1" "non-dry: qm argv reaches ssh (owner_host=lab-vm-900)"
# 인젝션 거부: ; 가 든 by-id 는 charset 에서 die, ssh 미호출
: > "$ndlog"
set +e
o="$(ND_LOG="$ndlog" PATH="$nd:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-attach lab-vm-900 -- --by-id '/dev/disk/by-id/x;reboot' 2>&1)"; rc=$?
set -e
[[ "$rc" -ne 0 ]] && echo "  ok: 인젝션 by-id 거부(비-0)" || { echo "  FAIL: 인젝션 by-id 통과"; exit 1; }
assert_eq "" "$(cat "$ndlog")" "인젝션 거부 시 ssh 미호출(빈 로그)"
[[ "$o" == *"허용되지 않는 문자"* ]] && echo "  ok: charset die 메시지" || { echo "  FAIL: charset die 메시지 없음: $o"; exit 1; }
rm -rf "$nd" "$ndlog"

# Task6: 적용 전 serial 실대조 — 노드 실측 serial 이 인벤토리 declared 와
# 불일치하면 qm set 전에 거부. ssh stub 가 lsblk SERIAL 질의에 응답.
T6="$(mktemp -d)"; t6log="$(mktemp)"
cat > "$T6/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh: $*" >> "${T6_LOG:?}"
case "$*" in
  *lsblk*SERIAL*|*SERIAL*lsblk*) echo '{"blockdevices":[{"serial":"WRONG-SERIAL-999"}]}' ;;   # 노드 실측(불일치)
  *) echo stub-ok ;;
esac
EOF
chmod +x "$T6/ssh"
# ssh-add: T6-local 허용 stub
cat > "$T6/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T6/ssh-add"
# ssh-agent: T6-local 허용 stub
cat > "$T6/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/t6-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99997; export SSH_AGENT_PID;'
EOF
chmod +x "$T6/ssh-agent"
# 불일치 → die, qm set 미실행
: > "$t6log"
set +e
o="$(T6_LOG="$t6log" PATH="$T6:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-attach lab-vm-900 -- --by-id /dev/disk/by-id/wwn-0xLAB --index 1 2>&1)"; rc=$?
set -e
[[ "$rc" -ne 0 ]] && echo "  ok: serial 불일치 → 비-0" || { echo "  FAIL: serial 불일치인데 진행"; exit 1; }
assert_contains "$o" "serial" "serial 불일치 die 메시지"
grep -q 'qm set' "$t6log" && { echo "  FAIL: 불일치인데 qm set 실행됨"; exit 1; } || echo "  ok: 불일치 시 qm set 미실행"

# 일치 → qm set 진행
cat > "$T6/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh: $*" >> "${T6_LOG:?}"
case "$*" in
  *lsblk*SERIAL*|*SERIAL*lsblk*) echo '{"blockdevices":[{"serial":"WD-LABDISK-001"}]}' ;;     # 인벤토리 declared 와 일치
  *) echo stub-ok ;;
esac
EOF
chmod +x "$T6/ssh"
: > "$t6log"
out="$(T6_LOG="$t6log" PATH="$T6:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-attach lab-vm-900 -- --by-id /dev/disk/by-id/wwn-0xLAB --index 1 2>&1)"
grep -q 'qm set 900 -scsi1 /dev/disk/by-id/wwn-0xLAB,backup=0,iothread=1' "$t6log" \
  && echo "  ok: serial 일치 → qm set 진행" || { echo "  FAIL: 일치인데 qm set 미실행: $(cat "$t6log")"; exit 1; }
rm -rf "$T6" "$t6log"

finish; echo "PASS test_disk_attach"
