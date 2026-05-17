#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export HOMELAB_SESSION_ID="guard-exec-sess"   # stable session so run-log path is predictable

# Fake backend. A real backend's --dry-run does NOT execute, so the fake prints
# DRYRUN (not BACKEND) when --dry-run is present. Fails when --boom is in extra.
cat > /tmp/fake-backend <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *--dry-run* ]]; then echo "DRYRUN action=$1 target=$2"; exit 0; fi
echo "BACKEND action=$1 target=$2 extra=$*"
[[ "$*" == *--boom* ]] && exit 20 || exit 0
EOF
chmod +x /tmp/fake-backend
export HOMELAB_BACKEND=/tmp/fake-backend
export PVE_TOKEN="stub-token-value"
: > logs/audit.jsonl
rm -rf "logs/runs/$HOMELAB_SESSION_ID"

# safe: runs immediately, audited, exit 0
out="$(bin/guard status vm-100)"
assert_contains "$out" "BACKEND action=status" "safe action executes"
assert_eq "safe" "$(tail -1 logs/audit.jsonl | jq -r .grade)" "safe audited"
assert_eq "0" "$(tail -1 logs/audit.jsonl | jq -r .exit)" "safe exit 0 audited"

# non-safe op requires its transport credential (here: pve → PVE_TOKEN)
assert_status 3 'env -u PVE_TOKEN bin/guard stop lab-vm-900' "stop without PVE_TOKEN exits 3"
# ssh-transport op refused when its credential (HL_SSH_KEY) is absent
assert_status 3 'env -u HL_SSH_KEY -u PVE_TOKEN bin/guard pkg-install lab-vm-900' "pkg-install without HL_SSH_KEY exits 3"
# A non-safe transport-none op (kill → destructive, op_transport=none) is NOT
# blocked by the credential gate (no transport secret needed). It still hits
# the *unrelated* destructive-approval gate → exit 10, NOT the credential
# gate's exit 3. exit 10 ≠ 3 proves the credential gate passed it.
# (status on critical is now safe → exempt from the bump, so it can no longer
# serve as the non-safe transport-none vehicle here.)
assert_status 10 'env -u PVE_TOKEN -u HL_SSH_KEY bin/guard kill pve-01' "destructive+transport-none passes credential gate (no credential needed)"

# caution on lab env: 1-line summary, proceeds without --approve
out="$(bin/guard stop lab-vm-900)"
assert_contains "$out" "SUMMARY" "caution prints summary"
assert_contains "$out" "BACKEND action=stop" "caution lab proceeds"

# caution on prod env: requires --approve → exit 10 first
assert_status 10 'bin/guard stop vm-100' "caution+prod without approve exits 10"
out="$(bin/guard stop vm-100 --approve)"
assert_contains "$out" "BACKEND action=stop" "caution+prod with approve runs"

# destructive without --approve: dry-run + impact, exit 10, NO real backend exec
set +e; out="$(bin/guard destroy lab-vm-900 2>&1)"; rc=$?; set -e
assert_eq "10" "$rc" "destructive without approve exits 10"
assert_contains "$out" "DRY-RUN" "destructive prints dry-run"
[[ "$out" != *"BACKEND action=destroy"* ]] && echo "  ok: backend NOT executed on dry-run" \
  || { echo "  FAIL: backend executed during dry-run"; exit 1; }

# destructive with --approve: runs, audit has approver + dryrun_hash + inv_snapshot
out="$(bin/guard destroy lab-vm-900 --approve)"
assert_contains "$out" "BACKEND action=destroy" "destructive+approve runs"
rec="$(tail -1 logs/audit.jsonl)"
assert_eq "destructive" "$(jq -r .grade <<<"$rec")" "destructive audited"
[[ "$(jq -r .approver <<<"$rec")" != "null" ]] && echo "  ok: approver recorded" \
  || { echo "  FAIL: approver missing"; exit 1; }
[[ "$(jq -r .dryrun_hash <<<"$rec")" != "null" ]] && echo "  ok: dryrun_hash recorded" \
  || { echo "  FAIL: dryrun_hash missing"; exit 1; }
[[ "$(jq -r .inv_snapshot.id <<<"$rec")" == "lab-vm-900" ]] && echo "  ok: inv snapshot recorded" \
  || { echo "  FAIL: inv snapshot missing"; exit 1; }

# backend failure → exit 20 AND audit/run-log still written (no log gap)
n_before="$(wc -l < logs/audit.jsonl)"
set +e; bin/guard destroy lab-vm-900 --approve -- --boom >/dev/null 2>&1; rc=$?; set -e
assert_eq "20" "$rc" "backend failure propagates exit 20"
n_after="$(wc -l < logs/audit.jsonl)"
[[ "$n_after" -gt "$n_before" ]] && echo "  ok: failure still audited (no gap)" \
  || { echo "  FAIL: failure left audit gap"; exit 1; }
assert_eq "20" "$(tail -1 logs/audit.jsonl | jq -r .exit)" "failure exit code audited"

# run log exists and is non-empty
rl="$(ls -t logs/runs/$HOMELAB_SESSION_ID/*.log | head -1)"
[[ -s "$rl" ]] && echo "  ok: run log written" || { echo "  FAIL: no run log"; exit 1; }

finish; echo "PASS test_guard_exec"
