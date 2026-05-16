#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-install"

t_install() {
  local ws; ws="$(new_workspace)"
  local sd="$ws/shims" rc="$ws/rc"
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$BIN" >/dev/null 2>&1
  [ -L "$sd/cargo" ] || _fail "cargo shim missing"
  assert_eq "$RDO/runtime/rd-shim" "$(readlink "$sd/cargo")"
  [ -L "$sd/rd" ] || _fail "rd link missing"
  [ -L "$sd/rd-exec" ] || _fail "rd-exec link missing"
  assert_eq "1" "$(grep -c '>>> remotedev >>>' "$rc")"
  assert_file_has "$rc" "export REMOTEDEV_SHIM_DIR=\"$sd\""
  rm -rf "$ws"
}
run_test "install links shims + wires rc" t_install

t_install_idempotent() {
  local ws; ws="$(new_workspace)"
  local sd="$ws/shims" rc="$ws/rc"
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$BIN" >/dev/null 2>&1
  REMOTEDEV_SHIM_DIR="$sd" REMOTEDEV_RC="$rc" bash "$BIN" >/dev/null 2>&1
  assert_eq "1" "$(grep -c '>>> remotedev >>>' "$rc")"
  assert_eq "$RDO/runtime/rd-shim" "$(readlink "$sd/make")"
  rm -rf "$ws"
}
run_test "install is idempotent" t_install_idempotent

summary
