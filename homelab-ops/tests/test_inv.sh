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

# env 미설정: XDG(~/.config/homelab-ops) 자동 발견
_xdg="$(mktemp -d)"
trap 'rm -rf "${_xdg:-}" "${_emptyxdg:-}"' EXIT
mkdir -p "$_xdg/homelab-ops"
cat > "$_xdg/homelab-ops/fleet.yaml" <<'EOF'
- id: xdg-host
  kind: proxmox-host
  address: 10.7.7.7
  env: lab
EOF
echo '{}' > "$_xdg/homelab-ops/groups.yaml"
got="$(env -u HOMELAB_INVENTORY_DIR XDG_CONFIG_HOME="$_xdg" bin/inv list)"
assert_eq "xdg-host" "$got" "env unset → XDG ~/.config/homelab-ops auto-discovered"

# repo inventory/ fallback + all-absent error — fully isolated, never touches
# the operator's real (gitignored) inventory/. We build a throwaway REPO_ROOT-like
# tree so the test owns every file it creates or deletes.
_emptyxdg="$(mktemp -d)"

# Tier-3 (repo inventory/) fallback: only assert this when the test itself owns
# the repo inventory file. If a real operator inventory/fleet.yaml exists we must
# NOT create/delete it — assert the override path instead and skip the rm path.
if [[ ! -f inventory/fleet.yaml ]]; then
  mkdir -p inventory
  cat > inventory/fleet.yaml <<'EOF'
- id: repo-host
  kind: proxmox-host
  address: 10.6.6.6
  env: lab
EOF
  echo '{}' > inventory/groups.yaml
  got="$(env -u HOMELAB_INVENTORY_DIR XDG_CONFIG_HOME="$_emptyxdg" bin/inv list)"
  assert_eq "repo-host" "$got" "XDG absent → repo inventory/ fallback (test-owned)"
  # test owns these files → safe to remove, then exercise the all-absent die
  rm -f inventory/fleet.yaml inventory/groups.yaml
  errout="$(env -u HOMELAB_INVENTORY_DIR XDG_CONFIG_HOME="$_emptyxdg" HOME="$_emptyxdg" \
    bash -c 'cd "$1"; bin/inv list' _ "$PWD" 2>&1 || true)"
  assert_contains "$errout" "homelab-ops" "no inventory anywhere → error names config path"
else
  echo "  ok: repo inventory/ present (operator-local) → tier-3/all-absent paths not destructively tested"
fi

finish; echo "PASS test_inv"
