#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_hwsync bin/_backend bin/pve bin/ssh-run 2>/dev/null || true

# Defaults injected the same way bw-exec would. PVE_TOKEN for proxmox-host/
# vm/lxc transport (kind-dispatched 'guest' → pve); HL_SSH_KEY for appliance
# transport (kind-dispatched 'guest' → ssh).
export PVE_TOKEN="stub-token-value"
export HL_SSH_KEY="$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nSTUBKEY-hwsync\n-----END OPENSSH PRIVATE KEY-----\n')"

# ── 1. ACTIONS 테이블 ──────────────────────────────────────────────────────
spec="$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[hwsync]:-MISSING}"')"
assert_eq "safe guest" "$spec" "ACTIONS[hwsync]=safe guest"

# ── 2. proxmox-host: physical, full block ──────────────────────────────────
out="$(bin/_hwsync pve-01)"
assert_contains "$out" "resource_type: physical" "host → physical"
assert_contains "$out" "model: Stub CPU" "host CPU model from API"
assert_contains "$out" "sockets: 1" "host cpu.sockets from API"
assert_contains "$out" "threads: 16" "host cpu.threads from API"
assert_contains "$out" "total_gib: 128.0" "host memory.total_gib from API"
assert_contains "$out" "name: local-zfs" "host storage pool from API"
assert_contains "$out" "name: vmbr0" "host NIC iface from API"
assert_not_contains "$out" "id: '10de:2206'" "host hwsync does NOT auto-populate passthrough (/hardware/pci returns every device)"
assert_contains "$out" "passthrough[] left empty by design" "header explains why passthrough is empty"
assert_contains "$out" "reserved_gib: 0" "host reserved_gib defaults to 0 (operator fills in)"
assert_contains "$out" "proxmox-host → physical" "header marks kind+classification"

# ── 3. vm: virtual, owner_host wired in, informational caveat ───────────────
out="$(bin/_hwsync vm-100)"
assert_contains "$out" "resource_type: virtual" "vm → virtual"
assert_contains "$out" "owner_host: pve-01" "vm carries owner_host"
assert_contains "$out" "vmid: 100" "vm carries vmid"
assert_contains "$out" "cores: 4" "vm cores from PVE config"
assert_contains "$out" "total_gib: 8.0" "vm memory MB→GiB conversion"
assert_contains "$out" "storage: local-lvm" "vm disk storage parsed"
assert_contains "$out" "size_gib: 32" "vm disk size parsed (G suffix)"
assert_contains "$out" "model: virtio" "vm net model parsed"
assert_contains "$out" "bridge: vmbr0" "vm net bridge parsed"
assert_contains "$out" "slot: hostpci0" "vm hostpci slot recorded"
assert_contains "$out" "PVE config IS the source of truth" "vm output warns not to paste"

# ── 4. lxc: virtual, rootfs + mp parsing ───────────────────────────────────
out="$(bin/_hwsync lxc-201)"
assert_contains "$out" "resource_type: virtual" "lxc → virtual"
assert_contains "$out" "cores: 2" "lxc cores"
assert_contains "$out" "swap_gib: 0.5" "lxc swap MB→GiB"
assert_contains "$out" "slot: rootfs" "lxc rootfs parsed"
assert_contains "$out" "mountpoint: /data" "lxc mp0 mountpoint parsed"
assert_contains "$out" "hostname: stub-lxc" "lxc hostname surfaced"

# ── 5. appliance: physical, CPU + memory from /proc ─────────────────────────
out="$(bin/_hwsync nas-01)"
assert_contains "$out" "resource_type: physical" "appliance → physical"
assert_contains "$out" "model: Stub Appliance CPU" "appliance CPU model from /proc/cpuinfo"
assert_contains "$out" "sockets: 1" "appliance physical sockets"
assert_contains "$out" "cores: 2" "appliance physical cores"
assert_contains "$out" "threads: 4" "appliance logical threads"
assert_contains "$out" "total_gib: 16.0" "appliance memory from /proc/meminfo"

# ── 6. pdm: refused ────────────────────────────────────────────────────────
err="$(bin/_hwsync pdm-01 2>&1 || true)"
assert_contains "$err" "kind=pdm has no hardware" "pdm refused with clear message"
assert_status 1 'bin/_hwsync pdm-01' "pdm exits non-zero"

# ── 7. orphan vm/lxc: clear error ──────────────────────────────────────────
_tmpinv="$(mktemp -d)"
cat > "$_tmpinv/fleet.yaml" <<'EOF'
- id: orphan-vm
  kind: vm
  vmid: 999
  address: 10.0.0.99
  env: lab
EOF
echo '{}' > "$_tmpinv/groups.yaml"
err="$(HOMELAB_INVENTORY_DIR="$_tmpinv" bin/_hwsync orphan-vm 2>&1 || true)"
assert_contains "$err" "orphan" "orphan vm fails with explicit message"
rm -rf "$_tmpinv"

# ── 8. usage / wrong target ────────────────────────────────────────────────
assert_status 2 'bin/_hwsync' "no arg → exit 2"
assert_status 1 'bin/_hwsync nope' "unknown id → exit 1 (from inv)"

# ── 9. guard routing: --plan emits proper credential per kind ──────────────
host_plan="$(env -u PVE_TOKEN bin/guard --plan hwsync pve-01 2>&1 || true)"
assert_contains "$host_plan" "PVE_TOKEN=bw://" "guard --plan hwsync <host> → PVE_TOKEN"
vm_plan="$(env -u PVE_TOKEN bin/guard --plan hwsync vm-100 2>&1 || true)"
assert_contains "$vm_plan" "PVE_TOKEN=bw://" "guard --plan hwsync <vm> → PVE_TOKEN (kind-dispatch)"
nas_plan="$(env -u HL_SSH_KEY bin/guard --plan hwsync nas-01 2>&1 || true)"
assert_contains "$nas_plan" "HL_SSH_KEY=bw://" "guard --plan hwsync <appliance> → HL_SSH_KEY"

# ── 10. guard hwsync runtime → routed to _backend → _hwsync ────────────────
gout="$(bin/guard hwsync pve-01 2>&1 || true)"
assert_contains "$gout" "resource_type: physical" "guard hwsync routes to _backend"

finish; echo "PASS test_hwsync"
