#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/ssh-run 2>/dev/null || true
export HL_SSH_KEY="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nSTUBKEY-ssh-nas-01\n-----END OPENSSH PRIVATE KEY-----')"

# Private tmpdir so any tempfile/agent socket ssh-run creates lands here
# (ssh-agent/ssh-add/mktemp honor $TMPDIR). The disk-leak scan then targets
# THIS dir + the runtime logs/ — never the shared global /tmp, whose unrelated
# content (e.g. a PR-diff dump quoting this test's own marker) would otherwise
# false-positive.
export TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# no key injected: ssh-run must refuse before spawning an agent (exit 3)
assert_status 3 'env -u HL_SSH_KEY bin/ssh-run nas-01 -- uname -a' "ssh-run without HL_SSH_KEY exits 3"

out="$(bin/ssh-run nas-01 -- uname -a 2>err.txt; cat err.txt)"
assert_contains "$out" "stub-ssh-output" "ssh-run runs remote command"
# StrictHostKeyChecking must be enforced
assert_contains "$out" "StrictHostKeyChecking=yes" "StrictHostKeyChecking=yes enforced"
assert_contains "$out" "BatchMode=yes" "BatchMode=yes enforced"
rm -f err.txt

# Key flows HL_SSH_KEY env → ssh-add stdin only; it must never be persisted.
# Scan the only places ssh-run could leak it: its private $TMPDIR (tempfiles /
# agent socket) and the runtime logs/ dir. Scoped to $TMPDIR (not shared /tmp)
# so unrelated global /tmp content can't false-positive on this test's own
# marker literal; still catches a real leak since ssh-run honors $TMPDIR.
if grep -rqI "STUBKEY-ssh-nas-01" "$TMPDIR" logs 2>/dev/null; then
  echo "FAIL: ssh key on disk"; exit 1
fi
echo "  ok: ssh key never written to disk"

# password 인증 경로: sshpass -e 사용, 비번은 SSHPASS env(argv 미노출),
# StrictHostKeyChecking=yes 유지.
export SSHPASS_SPY="$(mktemp)"; : > "$SSHPASS_SPY"
export SSH_SPY="$(mktemp)"; : > "$SSH_SPY"
out="$(HL_SSH_PASS='p@ss w0rd' bin/ssh-run pwhost -- echo hi 2>&1)"
spy="$(cat "$SSHPASS_SPY")"
assert_contains "$spy" "sshpass -e" "password path invokes sshpass -e"
assert_not_contains "$spy" "p@ss w0rd" "password never in sshpass argv"
sa="$(cat "$SSH_SPY" 2>/dev/null || true)"
assert_contains "$sa" "StrictHostKeyChecking=yes" "password path keeps host key check"
assert_contains "$sa" "PubkeyAuthentication=no" "password path disables pubkey"
assert_status 3 'env -u HL_SSH_PASS bin/ssh-run pwhost -- echo hi' "password path without HL_SSH_PASS exits 3"
assert_status 3 'env -u HL_SSH_KEY bin/ssh-run keyhost-notes -- echo hi' "key host still needs HL_SSH_KEY"
rm -f "$SSHPASS_SPY" "$SSH_SPY"

finish; echo "PASS test_ssh_run"
