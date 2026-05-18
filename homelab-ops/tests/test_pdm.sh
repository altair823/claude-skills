#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/pdm 2>/dev/null || true
export PDM_TOKEN="stub-pdm-token"

# 범용 api: curl 스텁이 결정적 JSON 반환
sp="$(mktemp -d)"
cat > "$sp/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/pdm-curl-args
echo '{"data":{"ok":true}}'
EOF
chmod +x "$sp/curl"; : > /tmp/pdm-curl-args
out="$(PATH="$sp:$PWD/tests/stubs:$PATH" bin/pdm api GET /version)"
assert_contains "$out" '"ok"' "pdm api GET returns json"
grep -q -- 'https://10.0.0.9/api2/json/version' /tmp/pdm-curl-args \
  && echo "  ok: pdm base URL from inventory entry" \
  || { echo "  FAIL: pdm base URL wrong: $(cat /tmp/pdm-curl-args)"; exit 1; }
grep -q -- 'PVEAPIToken=stub-pdm-token' /tmp/pdm-curl-args \
  && echo "  ok: pdm token header" || { echo "  FAIL: pdm token header"; exit 1; }
grep -q -- '-k' /tmp/pdm-curl-args && { echo "FAIL: pdm used -k"; exit 1; } || echo "  ok: TLS verification on"

# 미주입 PDM_TOKEN → exit 3
assert_status 3 'env -u PDM_TOKEN bin/pdm api GET /version' "pdm without PDM_TOKEN exits 3"

# pdm_wait_task: OK / 실패 / 타임아웃
cat > /tmp/_pdmwait.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
pdm_wait_task "$1"
EOF
cp /tmp/_pdmwait.sh bin/_pdmwait.sh
trap 'rm -f bin/_pdmwait.sh "$sp"/* ; rmdir "$sp" 2>/dev/null || true' EXIT
T="PDM-task:stub:1"

okd="$(mktemp -d)"
cat > "$okd/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"stopped","exitstatus":"OK"}}'
EOF
chmod +x "$okd/curl"
set +e
out="$(PDM_TOKEN=x PATH="$okd:$PWD/tests/stubs:$PATH" bash bin/_pdmwait.sh "$T")"; rc=$?
set -e
assert_eq "0" "$rc" "pdm_wait_task OK → 0"
assert_contains "$out" "HO-TASK upid=$T exitstatus=OK" "pdm_wait_task emits HO-TASK OK"

errd="$(mktemp -d)"
cat > "$errd/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"stopped","exitstatus":"migrate failed"}}'
EOF
chmod +x "$errd/curl"
set +e
out="$(PDM_TOKEN=x PATH="$errd:$PWD/tests/stubs:$PATH" bash bin/_pdmwait.sh "$T")"; rc=$?
set -e
assert_eq "1" "$rc" "pdm_wait_task non-OK → 1"
assert_contains "$out" "exitstatus=migrate failed" "pdm_wait_task carries error xs"

rund="$(mktemp -d)"
cat > "$rund/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"data":{"status":"running"}}'
EOF
chmod +x "$rund/curl"
set +e
out="$(HOMELAB_TASK_TIMEOUT=0 PDM_TOKEN=x PATH="$rund:$PWD/tests/stubs:$PATH" bash bin/_pdmwait.sh "$T")"; rc=$?
set -e
assert_eq "75" "$rc" "pdm_wait_task timeout → 75"
assert_contains "$out" "exitstatus=TIMEOUT" "pdm_wait_task TIMEOUT preserves task id"
rm -rf "$okd" "$errd" "$rund"

finish; echo "PASS test_pdm"
