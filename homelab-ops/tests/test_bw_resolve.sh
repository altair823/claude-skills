#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/bw-resolve 2>/dev/null || true

# Locked vault: no BW_SESSION → exit 3, nothing printed.
assert_status 3 'env -u BW_SESSION bin/bw-resolve "bw://Item/password"' "locked vault exits 3"
lv_out="$(env -u BW_SESSION bin/bw-resolve "bw://Item/password" 2>/dev/null || true)"
assert_eq "" "$lv_out" "locked vault emits nothing to stdout"

export BW_SESSION="stub-session"

pw="$(bin/bw-resolve 'bw://MyItem/password')"
assert_eq "stub-secret-MyItem" "$pw" "password ref resolves"

fld="$(bin/bw-resolve 'bw://Proxmox pve-01/api-token')"
assert_eq "stub-token-Proxmox pve-01" "$fld" "custom field ref resolves"

key="$(bin/bw-resolve --ssh 'bw://ssh-pve-01')"
assert_contains "$key" "BEGIN OPENSSH PRIVATE KEY" "ssh mode emits private key to stdout"

assert_status 1 'bin/bw-resolve "not-a-bw-ref"' "non bw:// ref rejected"

# resolved secret must never be written to disk by bw-resolve itself
grep -rq "stub-secret-MyItem" logs/ 2>/dev/null && { echo "FAIL: secret on disk"; exit 1; } || true
echo "  ok: no secret written to logs/"

finish; echo "PASS test_bw_resolve"
