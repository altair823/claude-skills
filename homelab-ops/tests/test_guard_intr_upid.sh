#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard 2>/dev/null || true
export HOMELAB_SESSION_ID="intr-upid-sess"
export PVE_TOKEN="stub-token-value"
: > logs/audit.jsonl
rm -rf "logs/runs/$HOMELAB_SESSION_ID"

# 느린 백엔드: UPID 가 든 raw 응답을 출력한 뒤 폴링처럼 장시간 sleep.
# 정상 종료 직전 HO-TASK 라인은 만들지 않음 → 인터럽트 경로의 raw-UPID
# 스크레이프(우선순위 2)만 검증.
cat > /tmp/slow-upid-backend <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *--dry-run* ]] && { echo "DRYRUN"; exit 0; }
[[ "$1" == status ]] && { echo '{"state":"pre"}'; exit 0; }
echo '{"data":"UPID:stub:DEADBEEF:0:0:t:0:root@pam:"}'
sleep 30
EOF
chmod +x /tmp/slow-upid-backend
export HOMELAB_BACKEND=/tmp/slow-upid-backend

# lab-vm-900: caution+lab → 승인 불필요, 백그라운드 파이프라인 진입.
bin/guard stop lab-vm-900 >/dev/null 2>&1 &
gpid=$!
sleep 2                       # 백엔드가 UPID 라인을 run-log 에 쓸 시간
kill -TERM "$gpid" 2>/dev/null || true
set +e
wait "$gpid" 2>/dev/null
rc=$?
set -e

rec="$(tail -1 logs/audit.jsonl)"
assert_eq "143" "$(jq -r .exit <<<"$rec")" "TERM 경로 exit 143 감사 1건"
n="$(wc -l < logs/audit.jsonl)"
assert_eq "1" "$n" "감사 레코드 정확히 1건(갭/중복 없음)"
assert_eq "UPID:stub:DEADBEEF:0:0:t:0:root@pam:" "$(jq -r .task_upid <<<"$rec")" \
  "인터럽트 경로에서 raw UPID 가 감사 task_upid 에 캡처됨"
assert_eq "null" "$(jq -r '.task_exitstatus // "null"' <<<"$rec")" \
  "결과 미상 → task_exitstatus null (정직한 표현)"

# ── 시나리오 2: PDM 형식 raw 응답 복구 ─────────────────────────────────────
# 느린 백엔드: PVE UPID 없이 PDM-shaped {"data":"PDM-task:stub:777"} 응답 후 sleep.
# _finish_trap 우선순위-3 fallback 이 "data" 키에서 task id 를 복구해야 한다.
: > logs/audit.jsonl
rm -rf "logs/runs/$HOMELAB_SESSION_ID"

cat > /tmp/slow-pdm-backend <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *--dry-run* ]] && { echo "DRYRUN"; exit 0; }
[[ "$1" == status ]] && { echo '{"state":"pre"}'; exit 0; }
echo '{"data":"PDM-task:stub:777"}'
sleep 30
EOF
chmod +x /tmp/slow-pdm-backend
export HOMELAB_BACKEND=/tmp/slow-pdm-backend

bin/guard stop lab-vm-900 >/dev/null 2>&1 &
gpid2=$!
sleep 2                       # 백엔드가 PDM 응답 라인을 run-log 에 쓸 시간
kill -TERM "$gpid2" 2>/dev/null || true
set +e
wait "$gpid2" 2>/dev/null
rc2=$?
set -e

rec2="$(tail -1 logs/audit.jsonl)"
assert_eq "143" "$(jq -r .exit <<<"$rec2")" "PDM 시나리오: TERM 경로 exit 143 감사 1건"
n2="$(wc -l < logs/audit.jsonl)"
assert_eq "1" "$n2" "PDM 시나리오: 감사 레코드 정확히 1건(갭/중복 없음)"
assert_eq "PDM-task:stub:777" "$(jq -r .task_upid <<<"$rec2")" \
  "PDM 시나리오: raw {\"data\":...} 에서 PDM task id 복구됨"
assert_eq "null" "$(jq -r '.task_exitstatus // "null"' <<<"$rec2")" \
  "PDM 시나리오: task_exitstatus null (결과 미상)"

finish; echo "PASS test_guard_intr_upid"
