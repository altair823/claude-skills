#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard 2>/dev/null || true
export HOMELAB_SESSION_ID="task-audit-sess"
export PVE_TOKEN="stub-token-value"
export HOMELAB_BACKEND=""        # 실제 _backend → bin/pve → task-aware 스텁
: > logs/audit.jsonl
rm -rf "logs/runs/$HOMELAB_SESSION_ID"

# lab-vm-900: vm/lab → caution+lab, 승인 불필요. guest→pve 전송.
out="$(bin/guard stop lab-vm-900)"
rec="$(tail -1 logs/audit.jsonl)"
assert_eq "stop" "$(jq -r .action <<<"$rec")" "action recorded"
assert_eq "0"    "$(jq -r .exit   <<<"$rec")" "OK task → exit 0 audited"
[[ "$(jq -r .task_upid <<<"$rec")" == UPID:* ]] && echo "  ok: task_upid captured" \
  || { echo "  FAIL: task_upid not captured: $rec"; exit 1; }
assert_eq "OK" "$(jq -r .task_exitstatus <<<"$rec")" "task_exitstatus OK captured"

# 별칭 정규화: guard delete → 감사 action 은 destroy
: > logs/audit.jsonl
bin/guard delete lab-vm-900 --approve >/dev/null 2>&1 || true
assert_eq "destroy" "$(tail -1 logs/audit.jsonl | jq -r .action)" "delete alias audited as destroy"

# fake backend 경로(HO-TASK 없음)는 필드가 null 이고 JSON 유효
export HOMELAB_BACKEND=/tmp/fake-nb
cat > /tmp/fake-nb <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *--dry-run* ]] && { echo "DRYRUN"; exit 0; }
echo "no task here"; exit 0
EOF
chmod +x /tmp/fake-nb
: > logs/audit.jsonl
bin/guard stop lab-vm-900 >/dev/null 2>&1 || true
rec="$(tail -1 logs/audit.jsonl)"
jq -e . >/dev/null <<<"$rec" && echo "  ok: audit record is valid JSON without HO-TASK" \
  || { echo "  FAIL: invalid audit JSON"; exit 1; }
assert_eq "null" "$(jq -r '.task_upid // "null"' <<<"$rec")" "no HO-TASK → task_upid null"

finish; echo "PASS test_guard_task_audit"
