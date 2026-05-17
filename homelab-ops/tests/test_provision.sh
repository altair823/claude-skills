#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x provisioning/phase1 2>/dev/null || true
export BW_SESSION="stub-session"
export PVE_TOKEN="stub-token-value"

# dry-run prints what WILL be created/destroyed and calls no mutating API
out="$(provisioning/phase1 dry-run pve-01 --from-template 9000 --new-vmid 950)"
assert_contains "$out" "WOULD CREATE" "dry-run announces creation"
assert_contains "$out" "template 9000 -> vmid 950 (name=ho-950) on host pve-01" "dry-run impact line is accurate"
[[ "$out" != *"CREATED"* ]] && echo "  ok: dry-run did not create" \
  || { echo "  FAIL: dry-run created"; exit 1; }
# a non-proxmox-host target is rejected up front (clear failure, no clone)
assert_status 1 'provisioning/phase1 dry-run vm-100 --from-template 9000 --new-vmid 950' "non-host target rejected"
# a missing flag value fails cleanly (not a raw bash unbound-variable crash)
assert_status 1 'provisioning/phase1 apply pve-01 --from-template' "missing flag value errors"

# apply path performs the clone via pve (curl stubbed → deterministic)
out="$(provisioning/phase1 apply pve-01 --from-template 9000 --new-vmid 950)"
assert_contains "$out" "CREATED" "apply performs clone"

# guard routes provision (destructive) through dry-run/approval
export HOMELAB_BACKEND=""   # use real _backend → provisioning/phase1
set +e; out="$(bin/guard provision pve-01 -- --from-template 9000 --new-vmid 950 2>&1)"; rc=$?; set -e
assert_eq "10" "$rc" "guard provision needs approval (destructive)"
assert_contains "$out" "DRY-RUN" "guard provision shows dry-run"

finish; echo "PASS test_provision"
