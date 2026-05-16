#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/ssh-run 2>/dev/null || true
export BW_SESSION="stub-session"

# Private tmpdir so any tempfile/agent socket ssh-run creates lands here
# (ssh-agent/ssh-add/mktemp honor $TMPDIR). The disk-leak scan then targets
# THIS dir + the runtime logs/ — never the shared global /tmp, whose unrelated
# content (e.g. a PR-diff dump quoting this test's own marker) would otherwise
# false-positive.
export TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# locked vault refusal (key resolved via bw-resolve --ssh)
assert_status 3 'env -u BW_SESSION bin/ssh-run nas-01 -- uname -a' "ssh-run without BW_SESSION exits 3"

out="$(bin/ssh-run nas-01 -- uname -a 2>err.txt; cat err.txt)"
assert_contains "$out" "stub-ssh-output" "ssh-run runs remote command"
# StrictHostKeyChecking must be enforced
assert_contains "$out" "StrictHostKeyChecking=yes" "StrictHostKeyChecking=yes enforced"
assert_contains "$out" "BatchMode=yes" "BatchMode=yes enforced"
rm -f err.txt

# Key flows bw-resolve stdout → ssh-add stdin only; it must never be persisted.
# Scan the only places ssh-run could leak it: its private $TMPDIR (tempfiles /
# agent socket) and the runtime logs/ dir. Scoped to $TMPDIR (not shared /tmp)
# so unrelated global /tmp content can't false-positive on this test's own
# marker literal; still catches a real leak since ssh-run honors $TMPDIR.
if grep -rqI "STUBKEY-ssh-nas-01" "$TMPDIR" logs 2>/dev/null; then
  echo "FAIL: ssh key on disk"; exit 1
fi
echo "  ok: ssh key never written to disk"

finish; echo "PASS test_ssh_run"
