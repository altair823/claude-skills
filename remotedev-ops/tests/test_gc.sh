#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
G="$RDO/bin/remotedev-gc"

t_no_cfg() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  bash "$G" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 2 "$rc"
}
run_test "gc without .remotedev exits 2" t_no_cfg

t_delete_present() {
  local ws fb rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  mkdir -p out; echo x > out/app; : > log
  PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" bash "$G" >/dev/null 2>&1; rc=$?
  assert_eq 0 "$rc"
  assert_file_has log "rm -rf -- remotedev/$(basename "$ws")/out/app"
  rm -rf "$ws"
}
run_test "gc deletes remote artifact when local copy exists" t_delete_present

t_skip_absent() {
  local ws fb out; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  : > log
  out="$(PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" bash "$G" 2>&1)"
  grep -q 'rm -rf' log && _fail "must not delete unrecovered artifact"
  assert_contains "$out" "keeping remote"
  rm -rf "$ws"
}
run_test "gc keeps remote when local copy is missing" t_skip_absent

t_offline_noop() {
  local ws fb rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  mkdir -p out; echo x > out/app; : > log
  PATH="$fb:$PATH" RD_FAKE_HOST_UP=1 RD_FAKE_LOG="$ws/log" bash "$G" >/dev/null 2>&1; rc=$?
  grep -q 'rm -rf' log && _fail "offline gc must not delete"
  rm -rf "$ws"; assert_eq 0 "$rc"
}
run_test "gc is a no-op when host unreachable" t_offline_noop

t_dry_run() {
  local ws fb out; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  mkdir -p out; echo x > out/app; : > log
  out="$(PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" bash "$G" --dry-run 2>&1)"
  grep -q 'rm -rf' log && _fail "--dry-run must not delete"
  assert_contains "$out" "would delete"
  rm -rf "$ws"
}
run_test "gc --dry-run mutates nothing" t_dry_run

t_real_gated() {
  [ -n "${REMOTEDEV_TEST_HOST:-}" ] || { echo "  (skipped: set REMOTEDEV_TEST_HOST)"; return 0; }
  local ws H RD; ws="$(new_workspace)"; cd "$ws"; H="$REMOTEDEV_TEST_HOST"
  RD="remotedev/rdo-gc-$$"
  printf 'REMOTEDEV_HOST="%s"\nREMOTEDEV_REMOTE_DIR="%s"\nREMOTEDEV_ARTIFACTS=(out/app)\n' "$H" "$RD" > .remotedev
  ssh "$H" "mkdir -p $(printf '%q' "$RD/out")" && ssh "$H" "echo remote > $(printf '%q' "$RD/out/app")"
  mkdir -p out; echo local > out/app
  bash "$G" >/dev/null 2>&1 || _fail "gc failed"
  if ssh "$H" "test -e $(printf '%q' "$RD/out/app")"; then
    ssh "$H" "rm -rf $(printf '%q' "$RD")"; _fail "remote artifact not deleted"
  fi
  ssh "$H" "rm -rf $(printf '%q' "$RD")"; rm -rf "$ws"
}
t_unsafe_path_blocked() {
  local ws fb out; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(../../evil /etc/passwd)\n' > .remotedev
  : > log
  out="$(PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" bash "$G" 2>&1)"
  grep -q 'rm -rf' log && _fail "unsafe path must NOT issue remote rm"
  assert_contains "$out" "unsafe artifact path"
  rm -rf "$ws"
}
run_test "gc refuses .. / absolute artifact paths" t_unsafe_path_blocked
run_test "gc deletes on the real host (gated)" t_real_gated

summary
