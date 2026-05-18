#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend 2>/dev/null || true
export HL_SSH_KEY="stub-key"

assert_eq "destructive" "$(bin/guard grade disk-grow lab-vm-900)" "disk-grow destructive"
assert_eq "destructive host-ssh" "$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[disk-grow]}"')" "ACTIONS[disk-grow]=destructive host-ssh"

# guest-agent 통한 탐지 stub: qm guest exec 가 lsblk/pvs/lvs/findmnt JSON 반환
gd="$(mktemp -d)"
cat > "$gd/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *lsblk* ]]; then
  echo '{"out-data":"{\"blockdevices\":[{\"name\":\"sda\",\"type\":\"disk\",\"children\":[{\"name\":\"sda3\",\"type\":\"part\",\"fstype\":\"LVM2_member\"}]}]}","exitcode":0}'
elif [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* || "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}],\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$gd/ssh"
# permissive ssh-add/ssh-agent stubs (tests/stubs/ssh-add requires real PEM key)
cat > "$gd/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$gd/ssh-add"
cat > "$gd/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/gd-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99996; export SSH_AGENT_PID;'
EOF
chmod +x "$gd/ssh-agent"
PV="PATH=$gd:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

# dry-run: 탐지 레이아웃 + 명령 시퀀스 echo, 미적용·exit 0, PVE-디스크 범위밖 명시
o="$(eval "$PV bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1")"
assert_contains "$o" "DRY-RUN" "disk-grow dry-run 헤더"
assert_contains "$o" "growpart" "시퀀스에 growpart"
assert_contains "$o" "pvresize" "시퀀스에 pvresize"
assert_contains "$o" "lvextend -l +100%FREE vg0/root" "시퀀스에 lvextend(탐지된 vg/lv)"
assert_contains "$o" "resize2fs" "ext4 → resize2fs 분기"
assert_contains "$o" "PVE 레벨 가상디스크" "범위밖(게스트 내부 전용) 명시"
assert_status 0 "$(printf '%s ' $PV) bin/_backend disk-grow lab-vm-900 --dry-run --" "disk-grow dry-run exit 0"

# guest-agent 실패 → 거부 (qm guest exec 비-0)
fd="$(mktemp -d)"
cat > "$fd/ssh" <<'EOF'
#!/usr/bin/env bash
echo "QEMU guest agent is not running" >&2; exit 1
EOF
chmod +x "$fd/ssh"
# permissive ssh-add/ssh-agent for $fd
cat > "$fd/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fd/ssh-add"
cat > "$fd/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/fd-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99995; export SSH_AGENT_PID;'
EOF
chmod +x "$fd/ssh-agent"
set +e
o="$(PATH="$fd:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1)"; rc=$?
set -e
assert_contains "$o" "guest" "guest-agent 실패 사유"
[[ "$rc" -ne 0 ]] && echo "  ok: guest-agent 실패 → 거부(추측 실행 없음)" || { echo "  FAIL: guest-agent 실패인데 진행"; exit 1; }
rm -rf "$gd" "$fd"

finish; echo "PASS test_disk_grow"
