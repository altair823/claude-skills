#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_SESSION="stub-session"
export PVE_TOKEN="stub-token-value"
export HOMELAB_SESSION_ID="forensic-sess"
: > logs/audit.jsonl
rm -rf "logs/runs/forensic-sess"

# Deliberate failure: backend fails on a destructive, approved op.
cat > /tmp/fail-backend <<'EOF'
#!/usr/bin/env bash
echo "BACKEND action=$1 target=$2 args=$*"
[[ "$1" == status ]] && { echo '{"state":"pre-op-running"}'; exit 0; }
echo "simulated catastrophic failure" >&2
exit 20
EOF
chmod +x /tmp/fail-backend
export HOMELAB_BACKEND=/tmp/fail-backend

set +e
bin/guard destroy lab-vm-900 --approve >/dev/null 2>&1
rc=$?
set -e
assert_eq "20" "$rc" "deliberate failure surfaces as exit 20"

# 1) audit.jsonl has the failed op with enough context to start root-cause
rec="$(bin/forensics session forensic-sess | tail -1)"
[[ -n "$rec" ]] || { echo "FAIL: forensics returned no record for forensic-sess"; exit 1; }
assert_eq "destroy"      "$(jq -r .action <<<"$rec")"       "audit: action recorded"
assert_eq "destructive"  "$(jq -r .grade  <<<"$rec")"       "audit: grade recorded"
assert_eq "20"           "$(jq -r .exit   <<<"$rec")"       "audit: failure exit recorded"
assert_eq "lab-vm-900"   "$(jq -r .inv_snapshot.id <<<"$rec")" "audit: inventory snapshot recorded"
[[ "$(jq -r .dryrun_hash <<<"$rec")" != "null" ]] && echo "  ok: audit dryrun_hash present" \
  || { echo "  FAIL: dryrun_hash missing"; exit 1; }
[[ "$(jq -r .approver <<<"$rec")" != "null" ]] && echo "  ok: audit approver present" \
  || { echo "  FAIL: approver missing"; exit 1; }

# 2) run log exists, captured pre-op snapshot AND the failure stderr
op="$(jq -r .op <<<"$rec")"
rl="logs/runs/forensic-sess/${op}.log"
[[ -s "$rl" ]] || { echo "FAIL: run log missing"; exit 1; }
assert_contains "$(cat "$rl")" "pre-op snapshot" "run log has pre-op snapshot section"
assert_contains "$(cat "$rl")" "pre-op-running" "run log captured pre-op state"
assert_contains "$(cat "$rl")" "catastrophic failure" "run log captured failure cause"

# 3) timeline reconstructs the sequence ending in the failure
tl="$(bin/forensics timeline forensic-sess)"
assert_contains "$tl" "destroy" "timeline includes the failed action"
assert_contains "$tl" "exit=20" "timeline shows the failure"

finish; echo "PASS test_forensic_sufficiency"
