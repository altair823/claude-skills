#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
INST="$RDO/bin/remotedev-install"
UNINST="$RDO/bin/remotedev-uninstall"

t_uninstall() {
  local ws; ws="$(new_workspace)"; local sd="$ws/shims" rc="$ws/rc"
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$INST" >/dev/null 2>&1
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$UNINST" >/dev/null 2>&1
  assert_file_absent "$sd/cargo"
  assert_eq "0" "$(grep -c '>>> remotedev >>>' "$rc" || true)"
  rm -rf "$ws"
}
run_test "uninstall removes shims + rc block" t_uninstall

t_uninstall_idempotent() {
  local ws; ws="$(new_workspace)"; local sd="$ws/shims" rc="$ws/rc"
  : > "$rc"
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$UNINST" >/dev/null 2>&1; local r=$?
  rm -rf "$ws"; assert_eq 0 "$r"
}
run_test "uninstall with nothing installed is a no-op" t_uninstall_idempotent

summary
