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

# --- Task 7: disk-grow --to (qm resize 선행, 축소 거부, 하위호환) ---
# stub 디렉토리: qm config(읽기) + qm resize + 기존 guest-agent 응답 처리
td="$(mktemp -d)"
cat > "$td/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *"qm config"* ]]; then
  # owner-node qm config 응답: 단일 디스크
  echo 'scsi0: local-lvm:vm-900-disk-0,size=96G'
elif [[ "$all" == *"qm resize"* ]]; then
  # owner-node qm resize 응답: 성공
  echo '{"out-data":"","exitcode":0}'
elif [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
elif [[ "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}]}]}","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$td/ssh"
cat > "$td/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$td/ssh-add"
cat > "$td/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/td-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99992; export SSH_AGENT_PID;'
EOF
chmod +x "$td/ssh-agent"
TPV="PATH=$td:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

# --to: dry-run 에 qm resize 선행 단계 명시
o2="$(eval "$TPV bin/_backend disk-grow lab-vm-900 --dry-run -- --to 128G 2>&1")"
assert_contains "$o2" "qm resize" "--to dry-run 에 qm resize 단계"
assert_contains "$o2" "128G" "목표 크기 표기"
# --to 없으면 기존 동작(하위호환): qm resize 미포함
o3="$(eval "$TPV bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1")"
assert_not_contains "$o3" "qm resize" "--to 없으면 qm resize 없음(하위호환)"
# 잘못된 size 형식 거부 (G/T 만, 128GB 거부)
assert_status 1 "$(printf '%s ' $TPV) bin/_backend disk-grow lab-vm-900 --dry-run -- --to 128GB" "size 형식 가드(128GB 거부)"
rm -rf "$td"

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

# ============================================================
# Task 7 code-review follow-up: new coverage tests
# ============================================================

# --- Test 1: explicit --disk scsi0, no qm config call needed ---
# Stub without qm config handler; should still succeed because --disk is explicit.
ed1="$(mktemp -d)"
cat > "$ed1/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *"qm config"* ]]; then
  # Should NOT be called when --disk is explicit; fail loudly if it is
  echo "qm-config-should-not-be-called" >&2; exit 1
elif [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
elif [[ "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}]}]}","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$ed1/ssh"
cat > "$ed1/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ed1/ssh-add"
cat > "$ed1/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/ed1-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99991; export SSH_AGENT_PID;'
EOF
chmod +x "$ed1/ssh-agent"
ED1PV="PATH=$ed1:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

o_ed1="$(eval "$ED1PV bin/_backend disk-grow lab-vm-900 --dry-run -- --to 64G --disk scsi0 2>&1")"
assert_contains "$o_ed1" "qm resize" "explicit --disk: dry-run contains qm resize"
assert_contains "$o_ed1" "scsi0" "explicit --disk: dry-run contains scsi0"
assert_contains "$o_ed1" "64G" "explicit --disk: dry-run contains 64G"
assert_not_contains "$o_ed1" "qm-config-should-not-be-called" "explicit --disk: qm config NOT called"
assert_status 0 "eval \"$ED1PV bin/_backend disk-grow lab-vm-900 --dry-run -- --to 64G --disk scsi0 2>&1\"" "explicit --disk: exit 0"
rm -rf "$ed1"

# --- Test 2: multi-disk auto-detect die (cdrom included) ---
# qm config returns scsi0 + ide2 cdrom; --to without --disk should die mentioning --disk
ed2="$(mktemp -d)"
cat > "$ed2/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *"qm config"* ]]; then
  echo 'scsi0: local-lvm:vm-900-disk-0,size=96G'
  echo 'ide2: none,media=cdrom'
elif [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
elif [[ "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}]}]}","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$ed2/ssh"
cat > "$ed2/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ed2/ssh-add"
cat > "$ed2/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/ed2-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99990; export SSH_AGENT_PID;'
EOF
chmod +x "$ed2/ssh-agent"
ED2PV="PATH=$ed2:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

set +e
o_ed2="$(eval "$ED2PV bin/_backend disk-grow lab-vm-900 --dry-run -- --to 64G 2>&1")"; rc_ed2=$?
set -e
[[ "$rc_ed2" -ne 0 ]] && echo "  ok: multi-disk auto-detect → die" || { echo "  FAIL: multi-disk인데 진행"; exit 1; }
assert_contains "$o_ed2" "--disk" "multi-disk die: message contains --disk hint"
assert_contains "$o_ed2" "cdrom" "multi-disk die: message mentions cdrom"
rm -rf "$ed2"

# --- Test 3: apply-path ordering (qm resize BEFORE growpart) ---
ed3="$(mktemp -d)"
ord3="$ed3/call-order.log"
cat > "$ed3/ssh" <<EOF
#!/usr/bin/env bash
all="\$*"
if [[ "\$all" == *"qm config"* ]]; then
  echo 'scsi0: local-lvm:vm-900-disk-0,size=96G'
elif [[ "\$all" == *"qm resize"* ]]; then
  echo "qm-resize" >> "$ord3"
  exit 0
elif [[ "\$all" == *findmnt* ]]; then
  echo '{"out-data":"{\\"filesystems\\":[{\\"target\\":\\"/\\",\\"source\\":\\"/dev/mapper/vg0-root\\",\\"fstype\\":\\"ext4\\"}]}","exitcode":0}'
elif [[ "\$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\\"report\\":[{\\"pv\\":[{\\"pv_name\\":\\"/dev/sda3\\"}]}]}","exitcode":0}'
elif [[ "\$all" == *"lvs"* || "\$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\\"report\\":[{\\"lv\\":[{\\"lv_name\\":\\"root\\",\\"vg_name\\":\\"vg0\\"}]}]}","exitcode":0}'
elif [[ "\$all" == *growpart* ]]; then
  echo "growpart" >> "$ord3"
  echo '{"out-data":"","exitcode":0}'
elif [[ "\$all" == *pvresize* ]]; then
  echo "pvresize" >> "$ord3"
  echo '{"out-data":"","exitcode":0}'
elif [[ "\$all" == *lvextend* ]]; then
  echo "lvextend" >> "$ord3"
  echo '{"out-data":"","exitcode":0}'
elif [[ "\$all" == *resize2fs* ]]; then
  echo "resize2fs" >> "$ord3"
  echo '{"out-data":"","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$ed3/ssh"
cat > "$ed3/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ed3/ssh-add"
cat > "$ed3/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/ed3-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99989; export SSH_AGENT_PID;'
EOF
chmod +x "$ed3/ssh-agent"
ED3PV="PATH=$ed3:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

o_ed3="$(eval "$ED3PV bin/_backend disk-grow lab-vm-900 -- --to 64G 2>&1")"
assert_contains "$o_ed3" "GROWN:" "apply ordering: GROWN marker present"
# Verify order: qm-resize must appear before growpart in the log
if [[ -f "$ord3" ]]; then
  first_line="$(head -n1 "$ord3")"
  assert_eq "qm-resize" "$first_line" "apply ordering: qm resize is FIRST recorded call"
  if grep -q "growpart" "$ord3"; then
    echo "  ok: apply ordering: growpart recorded after qm resize"
  else
    echo "  FAIL: apply ordering: growpart not found in order log"; _FAILS=$((_FAILS+1))
  fi
else
  echo "  FAIL: apply ordering: order log not created"; _FAILS=$((_FAILS+1))
fi
rm -rf "$ed3"

# --- Test 4: qm resize failure → die, growpart NOT called ---
ed4="$(mktemp -d)"
ord4="$ed4/call-order.log"
cat > "$ed4/ssh" <<EOF
#!/usr/bin/env bash
all="\$*"
if [[ "\$all" == *"qm config"* ]]; then
  echo 'scsi0: local-lvm:vm-900-disk-0,size=96G'
elif [[ "\$all" == *"qm resize"* ]]; then
  echo "homelab-ops: qm resize failed: storage full" >&2
  exit 1
elif [[ "\$all" == *findmnt* ]]; then
  echo '{"out-data":"{\\"filesystems\\":[{\\"target\\":\\"/\\",\\"source\\":\\"/dev/mapper/vg0-root\\",\\"fstype\\":\\"ext4\\"}]}","exitcode":0}'
elif [[ "\$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\\"report\\":[{\\"pv\\":[{\\"pv_name\\":\\"/dev/sda3\\"}]}]}","exitcode":0}'
elif [[ "\$all" == *"lvs"* || "\$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\\"report\\":[{\\"lv\\":[{\\"lv_name\\":\\"root\\",\\"vg_name\\":\\"vg0\\"}]}]}","exitcode":0}'
elif [[ "\$all" == *growpart* ]]; then
  echo "growpart-called" >> "$ord4"
  echo '{"out-data":"","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$ed4/ssh"
cat > "$ed4/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ed4/ssh-add"
cat > "$ed4/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/ed4-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99988; export SSH_AGENT_PID;'
EOF
chmod +x "$ed4/ssh-agent"
ED4PV="PATH=$ed4:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

set +e
o_ed4="$(eval "$ED4PV bin/_backend disk-grow lab-vm-900 -- --to 64G 2>&1")"; rc_ed4=$?
set -e
[[ "$rc_ed4" -ne 0 ]] && echo "  ok: qm resize fail → die" || { echo "  FAIL: qm resize 실패인데 진행"; exit 1; }
assert_contains "$o_ed4" "qm resize" "qm resize fail die: message contains qm resize"
# growpart must NOT have been called
if [[ -f "$ord4" ]] && grep -q "growpart-called" "$ord4"; then
  echo "  FAIL: qm resize fail인데 growpart 도달"; exit 1
else
  echo "  ok: qm resize fail → growpart 미도달"
fi
rm -rf "$ed4"

# --- Test 5: IMPORTANT-1 fix — dry-run output consistency ---
# 5a: no --to → still contains original "범위 밖 ... 사전 확장 전제" line (byte-compat)
# Reuse gd-style stub (no qm config, no qm resize)
ed5="$(mktemp -d)"
cat > "$ed5/ssh" <<'EOF'
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
chmod +x "$ed5/ssh"
cat > "$ed5/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ed5/ssh-add"
cat > "$ed5/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/ed5a-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99987; export SSH_AGENT_PID;'
EOF
chmod +x "$ed5/ssh-agent"
ED5PV="PATH=$ed5:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

# 5a: no-to dry-run — must contain backward-compat "범위 밖" + "사전 확장 전제"
o_ed5a="$(eval "$ED5PV bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1")"
assert_contains "$o_ed5a" "범위 밖" "no-to dry-run: 범위 밖 존재(하위호환)"
assert_contains "$o_ed5a" "사전 확장 전제" "no-to dry-run: 사전 확장 전제 존재(하위호환)"

# 5b: with --to dry-run — must NOT contain "범위 밖" / "사전 확장 전제"
# but MUST contain qm resize line + new accurate note
# Use td-style stub (with qm config returning single disk)
ed5b="$(mktemp -d)"
cat > "$ed5b/ssh" <<'EOF'
#!/usr/bin/env bash
all="$*"
if [[ "$all" == *"qm config"* ]]; then
  echo 'scsi0: local-lvm:vm-900-disk-0,size=96G'
elif [[ "$all" == *findmnt* ]]; then
  echo '{"out-data":"{\"filesystems\":[{\"target\":\"/\",\"source\":\"/dev/mapper/vg0-root\",\"fstype\":\"ext4\"}]}","exitcode":0}'
elif [[ "$all" == *"pvs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"pv\":[{\"pv_name\":\"/dev/sda3\"}]}]}","exitcode":0}'
elif [[ "$all" == *"lvs"* || "$all" == *"vgs"* ]]; then
  echo '{"out-data":"{\"report\":[{\"lv\":[{\"lv_name\":\"root\",\"vg_name\":\"vg0\"}]}]}","exitcode":0}'
else
  echo '{"out-data":"","exitcode":0}'
fi
EOF
chmod +x "$ed5b/ssh"
cat > "$ed5b/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ed5b/ssh-add"
cat > "$ed5b/ssh-agent" <<'EOF'
#!/usr/bin/env bash
echo 'SSH_AUTH_SOCK=/tmp/ed5b-stub.sock; export SSH_AUTH_SOCK;'
echo 'SSH_AGENT_PID=99986; export SSH_AGENT_PID;'
EOF
chmod +x "$ed5b/ssh-agent"
ED5BPV="PATH=$ed5b:$PWD/tests/stubs:\$PATH HL_SSH_KEY=x"

o_ed5b="$(eval "$ED5BPV bin/_backend disk-grow lab-vm-900 --dry-run -- --to 128G 2>&1")"
assert_not_contains "$o_ed5b" "범위 밖" "--to dry-run: 범위 밖 미포함(IMPORTANT-1)"
assert_not_contains "$o_ed5b" "사전 확장 전제" "--to dry-run: 사전 확장 전제 미포함(IMPORTANT-1)"
assert_contains "$o_ed5b" "qm resize" "--to dry-run: qm resize 포함"
assert_contains "$o_ed5b" "1단계" "--to dry-run: 1단계 표기 포함"
rm -rf "$ed5" "$ed5b"

finish; echo "PASS test_disk_grow"
