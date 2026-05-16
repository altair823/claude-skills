#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
C="$RDO/bin/_common.sh"

t_shim_dir_default() {
  local got; got="$(bash -c '. "$0"; shim_dir' "$C")"
  assert_contains "$got" "/.local/share/remotedev/shims"
}
run_test "shim_dir default path" t_shim_dir_default

t_shim_dir_override() {
  local got; got="$(REMOTEDEV_SHIM_DIR=/tmp/x bash -c '. "$0"; shim_dir' "$C")"
  assert_eq "/tmp/x" "$got"
}
run_test "shim_dir honours REMOTEDEV_SHIM_DIR" t_shim_dir_override

t_rc_file_override() {
  local got; got="$(REMOTEDEV_RC=/tmp/rc bash -c '. "$0"; rc_file' "$C")"
  assert_eq "/tmp/rc" "$got"
}
run_test "rc_file honours REMOTEDEV_RC" t_rc_file_override

t_rc_block_roundtrip() {
  local ws; ws="$(new_workspace)"; local rc="$ws/rc"
  echo 'export PATH=/usr/bin' > "$rc"
  REMOTEDEV_SHIM_DIR="$ws/shims" REMOTEDEV_RC="$rc" bash -c '. "$0"; rc_block_write "$(rc_file)"' "$C"
  REMOTEDEV_SHIM_DIR="$ws/shims" REMOTEDEV_RC="$rc" bash -c '. "$0"; rc_block_write "$(rc_file)"' "$C"
  local n; n="$(grep -c '>>> remotedev >>>' "$rc")"
  assert_eq "1" "$n"
  assert_file_has "$rc" "export REMOTEDEV_SHIM_DIR=\"$ws/shims\""
  REMOTEDEV_RC="$rc" bash -c '. "$0"; rc_block_remove "$(rc_file)"' "$C"
  n="$(grep -c '>>> remotedev >>>' "$rc" || true)"
  rm -rf "$ws"; assert_eq "0" "$n"
}
run_test "rc_block_write idempotent + rc_block_remove" t_rc_block_roundtrip

t_git_hide_tracked() {
  local ws; ws="$(new_workspace)"; cd "$ws"; git init -q
  echo hi > f; git add f; git commit -qm init
  bash -c '. "$0"; cd "'"$ws"'"; git_hide f' "$C"
  local flag; flag="$(git ls-files -v f | cut -c1)"
  rm -rf "$ws"; assert_eq "S" "$flag"
}
run_test "git_hide sets skip-worktree on tracked file" t_git_hide_tracked

summary
