#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
INIT="$RDO/bin/remotedev-init"
ST="$RDO/bin/remotedev-status"

t_status_configured() {
  local ws out; ws="$(new_workspace)"; cd "$ws"; echo '[package]
name="x"' > Cargo.toml
  PATH="$(fixtures_path):$PATH" bash "$INIT" >/dev/null 2>&1
  out="$(REMOTEDEV_SHIM_DIR="$ws/none" PATH="$(fixtures_path):$PATH" bash "$ST" 2>&1)"
  assert_contains "$out" "host: devbox"
  assert_contains "$out" "shim installed: no"
  assert_contains "$out" ".remotedev: present"
  rm -rf "$ws"
}
run_test "status reports config + machine state" t_status_configured

t_status_unconfigured() {
  local ws out rc; ws="$(new_workspace)"; cd "$ws"
  out="$(bash "$ST" 2>&1)"; rc=$?
  assert_contains "$out" ".remotedev: absent"
  rm -rf "$ws"; assert_eq 0 "$rc"
}
run_test "status without config is not an error" t_status_unconfigured

t_status_rc_block() {
  local ws out; ws="$(new_workspace)"; cd "$ws"
  printf '# >>> remotedev >>>\nexport X=1\n# <<< remotedev <<<\n' > "$ws/rc"
  out="$(REMOTEDEV_RC="$ws/rc" bash "$ST" 2>&1)"
  assert_contains "$out" "rc block: present"
  : > "$ws/rc2"
  out="$(REMOTEDEV_RC="$ws/rc2" bash "$ST" 2>&1)"
  assert_contains "$out" "rc block: absent"
  rm -rf "$ws"
}
run_test "status reports rc block presence" t_status_rc_block

summary
