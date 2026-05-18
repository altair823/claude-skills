#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend 2>/dev/null || true
export HL_SSH_KEY="stub-key"

assert_eq "destructive" "$(bin/guard grade disk-grow lab-vm-900)" "disk-grow destructive"
assert_eq "destructive host-ssh" "$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[disk-grow]}"')" "ACTIONS[disk-grow]=destructive host-ssh"

# guest-agent 통한 탐지 stub: qm guest exec 가 pvs/lvs/findmnt JSON 반환
# (lsblk arm 제거 — disk-grow 는 findmnt/pvs/lvs 만 호출)
gd="$(mktemp -d)"
cat > "$gd/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
elif [[ "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}]}]}","exitcode":0}'
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
assert_contains "$o" "growpart /dev/sda 3" "시퀀스에 growpart(sda partnum=3)"
assert_contains "$o" "pvresize /dev/sda3" "시퀀스에 pvresize"
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

# [Issue 6] hostile-pvname 거부 테스트: pvname에 메타문자 → charset guard 로 die
# argv-form _ga 덕에 `;reboot`이 노드 셸에 닿지 않음; charset guard가 1차 방어.
hd="$(mktemp -d)"
hlog="$hd/ssh.log"
cat > "$hd/ssh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$hlog"
all="\$*"
if [[ "\$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "\$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3; reboot\"}]}]}","exitcode":0}'
elif [[ "\$all" == *"lvs"* || "\$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}]}]}","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$hd/ssh"
cat > "$hd/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$hd/ssh-add"
cat > "$hd/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/hd-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99994; export SSH_AGENT_PID;'
EOF
chmod +x "$hd/ssh-agent"
set +e
ho="$(PATH="$hd:$PWD/tests/stubs:$PATH" HL_SSH_KEY=x bin/_backend disk-grow lab-vm-900 -- 2>&1)"; hrc=$?
set -e
[[ "$hrc" -ne 0 ]] || { echo "  FAIL: hostile pvname 인데 성공함(거부 실패)"; exit 1; }
assert_contains "$ho" "허용되지 않는 문자" "hostile pvname → charset guard die"
# ssh log 에 growpart/pvresize 가 없어야 함 (뮤테이션 미도달)
if [[ -f "$hlog" ]]; then
  if grep -qE "growpart|pvresize" "$hlog"; then
    echo "  FAIL: hostile pvname 인데 growpart/pvresize 가 ssh log 에 존재(뮤테이션 도달)"; exit 1
  fi
fi
echo "  ok: hostile pvname → charset guard die, growpart/pvresize 미도달"

rm -rf "$gd" "$fd" "$hd"

# --- 엣지: 다중 LV → --lv 미지정 거부 / 명시 시 그 LV 사용 ---
md="$(mktemp -d)"
cat > "$md/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
elif [[ "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"},{\"lv_name\":\"data\",\"vg_name\":\"vg0\"}]}]}","exitcode":0}'
else echo '{"out-data":"","exitcode":0}'; fi
EOF
chmod +x "$md/ssh"
cat > "$md/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$md/ssh-add"
cat > "$md/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/md-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99994; export SSH_AGENT_PID;'
EOF
chmod +x "$md/ssh-agent"
MPV="PATH=$md:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

set +e
o="$(eval "$MPV bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1")"; rc=$?
set -e
assert_contains "$o" "--lv" "다중 LV → --lv 명시 요구 메시지"
[[ "$rc" -ne 0 ]] && echo "  ok: 다중 LV 모호 → 거부" || { echo "  FAIL: 다중 LV인데 진행"; exit 1; }
# --lv 명시하면 그 LV 사용 (dry-run 시퀀스에 vg0/data)
o="$(eval "$MPV bin/_backend disk-grow lab-vm-900 --dry-run -- --lv vg0/data 2>&1")"
assert_contains "$o" "lvextend -l +100%FREE vg0/data" "--lv 명시 시 그 LV 사용"
rm -rf "$md"

# --- 엣지: 미지원 FS (btrfs) → 거부 ---
bd="$(mktemp -d)"
cat > "$bd/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"btrfs\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
elif [[ "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}]}]}","exitcode":0}'
else echo '{"out-data":"","exitcode":0}'; fi
EOF
chmod +x "$bd/ssh"
cat > "$bd/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$bd/ssh-add"
cat > "$bd/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/bd-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99993; export SSH_AGENT_PID;'
EOF
chmod +x "$bd/ssh-agent"
BPV="PATH=$bd:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"
set +e
o="$(eval "$BPV bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1")"; rc=$?
set -e
assert_contains "$o" "미지원 FS" "btrfs → 미지원 FS 거부 메시지"
[[ "$rc" -ne 0 ]] && echo "  ok: btrfs → 거부" || { echo "  FAIL: btrfs인데 진행"; exit 1; }
rm -rf "$bd"

finish; echo "PASS test_disk_grow"
