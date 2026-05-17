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

# XDG 부재 + repo inventory/ 존재 → repo 로 폴백
_emptyxdg="$(mktemp -d)"
mkdir -p homelab-ops-inv-probe
# repo inventory/ 는 운영자-로컬·gitignored 라 없을 수 있으니 임시 생성/정리
_made_repo_inv=0
if [[ ! -f inventory/fleet.yaml ]]; then
  mkdir -p inventory
  cat > inventory/fleet.yaml <<'EOF'
- id: repo-host
  kind: proxmox-host
  address: 10.6.6.6
  env: lab
EOF
  echo '{}' > inventory/groups.yaml
  _made_repo_inv=1
fi
got="$(env -u HOMELAB_INVENTORY_DIR XDG_CONFIG_HOME="$_emptyxdg" bin/inv list)"
[[ -n "$got" ]] && echo "  ok: XDG absent → repo inventory/ fallback" \
  || { echo "  FAIL: repo fallback failed"; exit 1; }
[[ "$_made_repo_inv" -eq 1 ]] && rm -f inventory/fleet.yaml inventory/groups.yaml
rmdir homelab-ops-inv-probe 2>/dev/null || true

# 셋 다 부재 → 후보 경로를 담은 명확한 에러로 exit 1
errout="$(env -u HOMELAB_INVENTORY_DIR XDG_CONFIG_HOME="$_emptyxdg" HOME="$_emptyxdg" \
  bash -c 'cd "$1"; rm -f inventory/fleet.yaml; bin/inv list' _ "$PWD" 2>&1 || true)"
assert_contains "$errout" "homelab-ops" "no-inventory error mentions config path"
rm -rf "$_xdg" "$_emptyxdg"

finish; echo "PASS test_inv"
