#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export PVE_TOKEN="stub-token-value"

cat > /tmp/_waitprobe.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
pve_wait_task "$1" "$2"
EOF
cp /tmp/_waitprobe.sh bin/_waitprobe.sh
trap 'rm -f bin/_waitprobe.sh' EXIT
U="UPID:stub:1:1:1:t:0:root@pam:"

# 성공: 기본 task-aware 스텁은 tasks/status 에 stopped/OK 반환
out="$(bash bin/_waitprobe.sh pve-01 "$U")"; rc=$?
assert_eq "0" "$rc" "OK task → exit 0"
assert_contains "$out" "HO-TASK upid=$U exitstatus=OK" "emits HO-TASK OK line"

# 실패 exitstatus: 전용 스텁 디렉터리로 교체
errd="$(mktemp -d)"
cat > "$errd/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"stopped","exitstatus":"err: volume busy"}}'
EOF
chmod +x "$errd/curl"
set +e
out="$(PATH="$errd:$PATH" bash bin/_waitprobe.sh pve-01 "$U")"; rc=$?
set -e
assert_eq "1" "$rc" "non-OK exitstatus → exit 1"
assert_contains "$out" "exitstatus=err: volume busy" "HO-TASK carries the error exitstatus"
rm -rf "$errd"

# 타임아웃: 항상 running + HOMELAB_TASK_TIMEOUT=0 → 즉시 75
runp="$(mktemp -d)"
cat > "$runp/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"running"}}'
EOF
chmod +x "$runp/curl"
set +e
out="$(HOMELAB_TASK_TIMEOUT=0 PATH="$runp:$PATH" bash bin/_waitprobe.sh pve-01 "$U")"; rc=$?
set -e
assert_eq "75" "$rc" "timeout → exit 75"
assert_contains "$out" "exitstatus=TIMEOUT" "HO-TASK records TIMEOUT, upid preserved"
assert_contains "$out" "upid=$U" "timeout HO-TASK preserves upid"
rm -rf "$runp"

# running→stopped 전이: 카운터 스텁, 정수 간격 1s
trd="$(mktemp -d)"
cat > "$trd/curl" <<'EOF'
#!/usr/bin/env bash
c="${TMP_TR:-/tmp/_tr_count}"; n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c"
if (( n >= 2 )); then echo '{"data":{"status":"stopped","exitstatus":"OK"}}'
else echo '{"data":{"status":"running"}}'; fi
EOF
chmod +x "$trd/curl"
: > /tmp/_tr_count
set +e
out="$(HOMELAB_TASK_POLL_INTERVAL=1 TMP_TR=/tmp/_tr_count PATH="$trd:$PATH" bash bin/_waitprobe.sh pve-01 "$U")"; rc=$?
set -e
assert_eq "0" "$rc" "running→stopped → eventual exit 0"
rm -rf "$trd" /tmp/_tr_count

finish; echo "PASS test_pve_wait"
