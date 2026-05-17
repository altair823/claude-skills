#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_SESSION="stub-session"
export PVE_TOKEN="stub-token-value"
export HOMELAB_SESSION_ID="sig-sess"
: > logs/audit.jsonl
rm -rf "logs/runs/sig-sess"

# Backend: fast for the dry-run probe and the pre-op status snapshot, but the
# real destructive action blocks (sleep) so we can interrupt mid-op.
cat > /tmp/slow-backend <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *--dry-run* ]]; then echo "DRYRUN $1 $2"; exit 0; fi
[[ "$1" == status ]] && { echo '{"state":"pre-op-running"}'; exit 0; }
echo "ACTION-STARTED $1 $2"
sleep 30
echo "ACTION-DONE"
EOF
chmod +x /tmp/slow-backend
export HOMELAB_BACKEND=/tmp/slow-backend

bin/guard destroy lab-vm-900 --approve >/dev/null 2>&1 &
gpid=$!

# Wait (bounded) until the real action has actually started (run log shows the
# ACTION-STARTED marker), then SIGTERM the guard process mid-op.
rl=""
for _ in $(seq 1 100); do
  rl="$(ls logs/runs/sig-sess/*.log 2>/dev/null | head -1 || true)"
  [[ -n "$rl" ]] && grep -q "ACTION-STARTED" "$rl" 2>/dev/null && break
  sleep 0.1
done
[[ -n "$rl" ]] && grep -q "ACTION-STARTED" "$rl" 2>/dev/null \
  || { echo "FAIL: action never started (cannot test interrupt)"; kill "$gpid" 2>/dev/null || true; exit 1; }

kill -TERM "$gpid"
set +e
wait "$gpid"
rc=$?
set -e
assert_eq "143" "$rc" "SIGTERM mid-op exits 143"

n="$(wc -l < logs/audit.jsonl)"
assert_eq "1" "$n" "exactly one audit record on signal (no gap, no double)"
ex="$(tail -1 logs/audit.jsonl | jq -r .exit)"
assert_eq "143" "$ex" "interrupted op audited with non-zero signal exit (not false 0)"
assert_eq "destroy" "$(tail -1 logs/audit.jsonl | jq -r .action)" "interrupted op records the action"
assert_eq "lab-vm-900" "$(tail -1 logs/audit.jsonl | jq -r .inv_snapshot.id)" "interrupted op records inventory snapshot"

finish; echo "PASS test_guard_signal"
