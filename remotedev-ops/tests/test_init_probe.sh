#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-init"

t_offline_still_writes() {
  local ws out rc; ws="$(new_workspace)"; cd "$ws"
  out="$(PATH="$(fixtures_path):$PATH" RD_FAKE_HOST_UP=1 bash "$BIN" 2>&1)"; rc=$?
  assert_eq 0 "$rc"
  assert_file_has .remotedev 'REMOTEDEV_HOST="devbox"'
  assert_contains "$out" "unreachable"
  rm -rf "$ws"
}
run_test "init writes config + warns when host unreachable" t_offline_still_writes

t_warns_no_shim() {
  local ws out; ws="$(new_workspace)"; cd "$ws"
  out="$(REMOTEDEV_SHIM_DIR="$ws/none" PATH="$(fixtures_path):$PATH" bash "$BIN" 2>&1)"
  assert_contains "$out" "remotedev-install"
  rm -rf "$ws"
}
run_test "init warns when shim not installed" t_warns_no_shim

summary
