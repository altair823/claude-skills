#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/ssh-run 2>/dev/null || true
export BW_SESSION="stub-session"

# locked vault refusal (key resolved via bw-resolve --ssh)
assert_status 3 'env -u BW_SESSION bin/ssh-run nas-01 -- uname -a' "ssh-run without BW_SESSION exits 3"

out="$(bin/ssh-run nas-01 -- uname -a 2>err.txt; cat err.txt)"
assert_contains "$out" "stub-ssh-output" "ssh-run runs remote command"
# StrictHostKeyChecking must be enforced
assert_contains "$out" "StrictHostKeyChecking=yes" "StrictHostKeyChecking=yes enforced"
assert_contains "$out" "BatchMode=yes" "BatchMode=yes enforced"
rm -f err.txt

# Key flows bw-resolve stdout → ssh-add stdin only; it must never be persisted.
# Scan the only places ssh-run could leak it: tmpfiles and the runtime logs dir.
# (The repo source is excluded on purpose: this test file and the plan doc
#  legitimately contain the literal marker as the search pattern.)
if grep -rqI "STUBKEY-ssh-nas-01" /tmp logs 2>/dev/null; then
  echo "FAIL: ssh key on disk"; exit 1
fi
echo "  ok: ssh key never written to disk"

finish; echo "PASS test_ssh_run"
