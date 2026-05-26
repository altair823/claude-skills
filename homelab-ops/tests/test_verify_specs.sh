#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_verify_specs bin/_backend bin/pve 2>/dev/null || true

# PVE_TOKEN injection mirrors what bw-exec does in production. The curl stub
# returns canned JSON that matches fixtures/fleet.yaml pve-01.hardware exactly,
# so the default run is no-drift (exit 0).
export PVE_TOKEN="stub-token-value"

# ── 1. ACTIONS 테이블 등록 확인 ─────────────────────────────────────────────
spec="$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[verify-specs]:-MISSING}"')"
assert_eq "safe pve" "$spec" "ACTIONS[verify-specs]=safe pve"

# ── 2. 잘못된 kind → exit 2 + 명확한 메시지 ─────────────────────────────────
err="$(bin/_verify_specs vm-100 2>&1 || true)"
assert_contains "$err" "proxmox-host only" "verify-specs on vm exits with clear msg"
assert_status 2 'bin/_verify_specs vm-100' "verify-specs on non-host exits 2"
assert_status 2 'bin/_verify_specs' "verify-specs without arg exits 2"

# ── 3. hardware 미선언 host (lab-vm-900 은 host 아니라 vm — 다른 케이스 필요).
# 임시 인벤토리로 hardware 미선언 proxmox-host 만들기.
_tmpinv="$(mktemp -d)"
cat > "$_tmpinv/fleet.yaml" <<'EOF'
- id: bare-host
  kind: proxmox-host
  address: 10.0.0.99
  env: lab
  access: { api: { token_ref: "bw://x" } }
EOF
echo '{}' > "$_tmpinv/groups.yaml"
nohw="$(HOMELAB_INVENTORY_DIR="$_tmpinv" bin/_verify_specs bare-host)"
assert_contains "$nohw" "no 'hardware:' block declared" "no hardware → informational notice"
assert_status 0 "HOMELAB_INVENTORY_DIR=\"$_tmpinv\" bin/_verify_specs bare-host" \
  "verify-specs on hardware-less host exits 0"
rm -rf "$_tmpinv"

# ── 4. 정상 경로: fixture pve-01 + 스텁 → 0 drift, exit 0 ────────────────────
out="$(bin/_verify_specs pve-01)"
assert_contains "$out" "0 drift, 0 missing" "no-drift result line present"
assert_contains "$out" "sockets declared=1 live=1" "CPU sockets compared"
assert_contains "$out" "threads declared=16 live(cpus)=16" "threads ↔ cpus mapping"
assert_contains "$out" "total_gib declared=128 live=128" "memory total compared"
assert_contains "$out" "pool 'local-zfs'" "storage pool 'local-zfs' line"
assert_contains "$out" "vmbr0 present on node" "NIC presence check"
assert_contains "$out" "10de:2206" "PCI passthrough id reported"
assert_status 0 'bin/_verify_specs pve-01' "no-drift run exits 0"

# ── 5. drift 감지: 인벤토리에 일부러 다른 값 → exit 1 ──────────────────────
_driftinv="$(mktemp -d)"
mkdir -p "$_driftinv/ca"
cat > "$_driftinv/fleet.yaml" <<'EOF'
- id: pve-01
  kind: proxmox-host
  address: 10.0.0.11
  env: prod
  access: { api: { token_ref: "bw://x" } }
  hardware:
    cpu: { sockets: 2, cores: 8, threads: 16 }
    memory: { total_gib: 256 }
    storages:
      - { name: ghost-pool, type: zfs, size_tib: 1.0 }
EOF
echo '{}' > "$_driftinv/groups.yaml"
dout="$(HOMELAB_INVENTORY_DIR="$_driftinv" bin/_verify_specs pve-01 2>&1 || true)"
assert_contains "$dout" "DRIFT" "drift on cpu.sockets surfaces DRIFT line"
assert_contains "$dout" "MISSING" "declared 'ghost-pool' surfaces MISSING"
assert_contains "$dout" "drift," "summary line counts drift+missing"
assert_status 1 "HOMELAB_INVENTORY_DIR=\"$_driftinv\" bin/_verify_specs pve-01" \
  "drift run exits 1"
rm -rf "$_driftinv"

# ── 6. guard --plan: PVE_TOKEN 요구 (safe pve transport) ────────────────────
plan="$(env -u PVE_TOKEN bin/guard --plan verify-specs pve-01 2>&1 || true)"
assert_contains "$plan" "PVE_TOKEN=bw://" "guard --plan emits PVE_TOKEN ref"

# ── 7. guard verify-specs (safe → no --approve, no dry-run probe) ──────────
gout="$(bin/guard verify-specs pve-01 2>&1 || true)"
assert_contains "$gout" "0 drift, 0 missing" "guard routes verify-specs through _backend"

finish; echo "PASS test_verify_specs"
