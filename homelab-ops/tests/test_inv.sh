#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/inv 2>/dev/null || true

ids="$(bin/inv list)"
assert_contains "$ids" "pve-01" "list includes pve-01"
assert_contains "$ids" "lab-vm-900" "list includes lab dummy"

entry="$(bin/inv get pve-01)"
assert_eq "proxmox-host" "$(jq -r .kind <<<"$entry")" "get returns kind"
assert_eq "prod" "$(jq -r .env <<<"$entry")" "get returns env"

resolved="$(bin/inv resolve pve-01)"
assert_contains "$(jq -rc '.groups' <<<"$resolved")" "pve-hosts" "resolve attaches groups"

kids="$(bin/inv children pve-01)"
assert_contains "$kids" "vm-100" "children lists guests"

mem="$(bin/inv group pve-hosts)"
assert_contains "$mem" "pve-01" "group lists members"

assert_status 1 'bin/inv get nope' "unknown id exits 1"

assert_eq "" "$(bin/inv children vm-100)" "leaf node has no children"
assert_status 1 'bin/inv resolve nope' "resolve unknown id exits 1"
assert_status 1 'bin/inv' "no subcommand exits 1"

# HOMELAB_INVENTORY_DIR overrides the inventory location so the live
# inventory/ can hold the operator's real fleet without breaking the
# stub-driven suite (which points at a fixed fixture).
_tmpinv="$(mktemp -d)"
cat > "$_tmpinv/fleet.yaml" <<'EOF'
- id: override-host
  kind: proxmox-host
  address: 10.9.9.9
  env: lab
EOF
cat > "$_tmpinv/groups.yaml" <<'EOF'
ovr: [override-host]
EOF
ovr_ids="$(HOMELAB_INVENTORY_DIR="$_tmpinv" bin/inv list)"
assert_eq "override-host" "$ovr_ids" "HOMELAB_INVENTORY_DIR overrides fleet path"
ovr_grp="$(HOMELAB_INVENTORY_DIR="$_tmpinv" bin/inv resolve override-host | jq -rc '.groups')"
assert_contains "$ovr_grp" "ovr" "override also redirects groups.yaml"
rm -rf "$_tmpinv"

finish; echo "PASS test_inv"
