#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend bin/pdm 2>/dev/null || true
export PDM_TOKEN="stub-pdm-token"

assert_eq "destructive" "$(bin/guard grade remote-migrate lab-vm-900)" "remote-migrate destructive"
assert_eq "destructive pdm" "$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[remote-migrate]}"')" "ACTIONS[remote-migrate]=destructive pdm"

# dry-run: 미적용, source/target/vmid/storage/online echo, exit 0
o="$(bin/_backend remote-migrate lab-vm-900 --dry-run -- --to pve-01 --target-storage local:local-zfs --online 2>&1)"
assert_contains "$o" "DRY-RUN" "remote-migrate dry-run 헤더"
assert_contains "$o" "vmid=900" "vmid echo"
assert_contains "$o" "to=pve-01" "target node echo"
assert_contains "$o" "online=true" "online=true when --online passed"
o2="$(bin/_backend remote-migrate lab-vm-900 --dry-run -- --to pve-01 2>&1)"
assert_contains "$o2" "online=false" "online=false when --online absent"
assert_status 0 'bin/_backend remote-migrate lab-vm-900 --dry-run -- --to pve-01' "dry-run exit 0"

# 적용: bin/pdm 가 POST 발행하고 task id 반환 → pdm_wait_task 폴링 → HO-TASK
sp="$(mktemp -d)"
cat > "$sp/curl" <<'EOF'
#!/usr/bin/env bash
a="$*"
echo "$a" >> "${RM_CARGS:?}"
if [[ "$a" == *"/status"* ]]; then echo '{"data":{"status":"stopped","exitstatus":"OK"}}'
else echo '{"data":"PDM-task:stub:42"}'; fi
EOF
chmod +x "$sp/curl"
rmc="$(mktemp)"
out="$(RM_CARGS="$rmc" PATH="$sp:$PWD/tests/stubs:$PATH" bin/_backend remote-migrate lab-vm-900 -- --to pve-01 2>&1)"
assert_contains "$out" "HO-TASK upid=PDM-task:stub:42 exitstatus=OK" "remote-migrate 가 PDM task 폴링"
grep -q -- '-X POST' "$rmc" && echo "  ok: POST 발행" || { echo "  FAIL: POST 미발행: $(cat "$rmc")"; exit 1; }
rm -rf "$sp" "$rmc"

# 자격 게이트: PDM_TOKEN 없으면 exit 3
assert_status 3 'env -u PDM_TOKEN bin/guard remote-migrate lab-vm-900 -- --to pve-01' "remote-migrate without PDM_TOKEN exits 3"
# --plan → PDM_TOKEN ref
assert_eq "PDM_TOKEN=bw://Proxmox-Datacenter-Manager pdm-01/api-token" "$(bin/guard --plan remote-migrate lab-vm-900)" "--plan remote-migrate → PDM_TOKEN ref"

# 인젝션 거부: --to / --target-storage 에 셸/파라미터 메타문자 → die, POST 미발행
sp2="$(mktemp -d)"; rmc2="$(mktemp)"
cat > "$sp2/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${RM_CARGS:?}"
echo '{"data":"PDM-task:stub:42"}'
EOF
chmod +x "$sp2/curl"
set +e
o="$(RM_CARGS="$rmc2" PATH="$sp2:$PWD/tests/stubs:$PATH" bin/_backend remote-migrate lab-vm-900 -- --to 'pve-01&evil=1' 2>&1)"; rc=$?
set -e
[[ "$rc" -ne 0 ]] && echo "  ok: --to 메타문자 거부(비-0)" || { echo "  FAIL: --to 인젝션 통과"; exit 1; }
assert_eq "" "$(cat "$rmc2")" "인젝션 거부 시 curl 미호출"
rm -rf "$sp2" "$rmc2"

# --target-storage 인젝션도 거부(charset 가드) — POST 미발행
sp3="$(mktemp -d)"; rmc3="$(mktemp)"
cat > "$sp3/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${RM_CARGS:?}"
echo '{"data":"PDM-task:stub:42"}'
EOF
chmod +x "$sp3/curl"
set +e
o="$(RM_CARGS="$rmc3" PATH="$sp3:$PWD/tests/stubs:$PATH" bin/_backend remote-migrate lab-vm-900 -- --to pve-01 --target-storage 'local-zfs&evil=1' 2>&1)"; rc=$?
set -e
[[ "$rc" -ne 0 ]] && echo "  ok: --target-storage 메타문자 거부(비-0)" || { echo "  FAIL: --target-storage 인젝션 통과"; exit 1; }
assert_eq "" "$(cat "$rmc3")" "tstor 인젝션 거부 시 curl 미호출"
rm -rf "$sp3" "$rmc3"

finish; echo "PASS test_remote_migrate"
