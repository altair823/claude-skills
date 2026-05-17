#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/pve 2>/dev/null || true
export BW_SESSION="stub-session"
export PVE_TOKEN="stub-token-value"

# curl is stubbed → deterministic Proxmox-shaped JSON
out="$(bin/pve pve-01 api GET /nodes)"
assert_contains "$out" '"status"' "pve api returns json"

st="$(bin/pve pve-01 status)"
assert_contains "$st" "running" "pve status convenience works"

# no token injected: pve must refuse (exit 3)
assert_status 3 'env -u PVE_TOKEN bin/pve pve-01 status' "pve without PVE_TOKEN exits 3"

# TLS verification must be ON: pve must NOT pass -k/--insecure to curl.
cat > /tmp/curl-spy <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/curl-args
echo '{"data":{"status":"running"}}'
EOF
chmod +x /tmp/curl-spy
: > /tmp/curl-args
mkdir -p /tmp/spybin && cp /tmp/curl-spy /tmp/spybin/curl
PATH="/tmp/spybin:$PWD/tests/stubs:$PATH" bin/pve pve-01 status >/dev/null
grep -q -- '-k' /tmp/curl-args && { echo "FAIL: curl -k used (TLS off)"; exit 1; }
grep -q -- '--insecure' /tmp/curl-args && { echo "FAIL: --insecure used"; exit 1; }
echo "  ok: TLS verification left on"

# action builds a kind-aware Proxmox path: vm→/qemu/<vmid>, lxc→/lxc/<vmid>
: > /tmp/curl-args
PATH="/tmp/spybin:$PWD/tests/stubs:$PATH" bin/pve pve-01 action stop vm-100 >/dev/null
grep -q -- '/nodes/pve-01/qemu/100/status/stop' /tmp/curl-args \
  && echo "  ok: vm action → /qemu/<vmid>" \
  || { echo "  FAIL: vm action path wrong: $(cat /tmp/curl-args)"; exit 1; }
: > /tmp/curl-args
PATH="/tmp/spybin:$PWD/tests/stubs:$PATH" bin/pve pve-01 action stop lxc-201 >/dev/null
grep -q -- '/nodes/pve-01/lxc/201/status/stop' /tmp/curl-args \
  && echo "  ok: lxc action → /lxc/<vmid>" \
  || { echo "  FAIL: lxc action path wrong: $(cat /tmp/curl-args)"; exit 1; }

finish; echo "PASS test_pve"
