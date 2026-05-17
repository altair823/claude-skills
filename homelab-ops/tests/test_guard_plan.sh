#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard 2>/dev/null || true

# 안전 등급 op 는 credential 불필요 → 빈 출력
out="$(bin/guard --plan status vm-100)"
assert_eq "" "$out" "safe op → empty plan"

# status on critical stays safe (read-only exempt from the critical bump);
# --plan exits early for safe ops → empty plan, no credential needed.
out="$(bin/guard --plan status pve-01)"
assert_eq "" "$out" "status on critical (safe, read-only exempt) → empty plan"

# vm action → 소유 Proxmox 호스트의 api token_ref
out="$(bin/guard --plan stop vm-100)"
assert_eq "PVE_TOKEN=bw://Proxmox pve-01/api-token" "$out" "vm stop → owner host PVE_TOKEN ref"

# appliance action → 그 target 의 ssh key_ref
out="$(bin/guard --plan stop nas-01)"
assert_eq "HL_SSH_KEY=bw://ssh-nas-01" "$out" "appliance stop → HL_SSH_KEY ref"

# pkg-install → ssh transport
out="$(bin/guard --plan pkg-install vm-100)"
assert_eq "HL_SSH_KEY=bw://ssh-vm-100" "$out" "pkg-install → HL_SSH_KEY ref"

# provision → 호스트 자신의 token_ref
out="$(bin/guard --plan provision pve-01)"
assert_eq "PVE_TOKEN=bw://Proxmox pve-01/api-token" "$out" "provision → host PVE_TOKEN ref"

# --plan 은 어떤 시크릿에도 접근하지 않는다: bw 가 PATH 에 없어도 동작
out="$(env -u BW_SESSION PATH="/usr/bin:/bin" bash bin/guard --plan stop vm-100 2>/dev/null || true)"
assert_eq "PVE_TOKEN=bw://Proxmox pve-01/api-token" "$out" "--plan resolves without any bw/session"

# 잘못된 사용
assert_status 1 'bin/guard --plan' "no args → usage error"

# 미매핑 액션: stdout 은 비어 있고 rc 0, 진단은 stderr 로만
out="$(bin/guard --plan frobnicate vm-100 2>/dev/null)"
assert_eq "" "$out" "unmapped action → empty stdout"
assert_status 0 'bin/guard --plan frobnicate vm-100 2>/dev/null' "unmapped action → rc 0"
err="$(bin/guard --plan frobnicate vm-100 2>&1 1>/dev/null)"
assert_contains "$err" "transport 매핑이 없어" "unmapped action → stderr diagnostic"
# 정당한 read-only(critical bump 으로 caution 인 status)는 stderr 진단 없음
err="$(bin/guard --plan status pve-01 2>&1 1>/dev/null)"
assert_eq "" "$err" "status on critical → no false diagnostic on stderr"

# 키 ref 가 /notes 를 포함해도 guard --plan 은 변형 없이 verbatim 통과.
out="$(bin/guard --plan stop keyhost-notes)"
assert_eq "HL_SSH_KEY=bw://ssh-keyhost-notes/notes" "$out" "ssh key_ref with /notes passes verbatim"

# auth=password 호스트는 HL_SSH_PASS 자격을 산출한다.
out="$(bin/guard --plan stop pwhost)"
assert_eq "HL_SSH_PASS=bw://ssh-pwhost-pass" "$out" "password host → HL_SSH_PASS ref"

finish; echo "PASS test_guard_plan"
