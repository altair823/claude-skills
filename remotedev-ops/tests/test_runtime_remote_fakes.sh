#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
RT="$RDO/runtime"

t_no_pty() {
  local ws fb; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  echo 'REMOTEDEV_HOST="fakehost"' > .remotedev; : > log
  PATH="$fb:$PATH" RD_FAKE_LOG="$ws/log" "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1
  local execline; execline="$(grep ' && ' log | head -1)"
  rm -rf "$ws"
  assert_contains "$execline" "ssh "; assert_not_contains "$execline" " -t "
}
run_test "runtime: no -t when stdin not a tty" t_no_pty

t_no_pull_fail() {
  local ws fb rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  PATH="$fb:$PATH" RD_FAKE_BUILD_RC=7 "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1; rc=$?
  local p="present"; [ -e out/app ] || p="absent"
  rm -rf "$ws"; assert_eq 7 "$rc"; assert_eq "absent" "$p"
}
run_test "runtime: failed build skips pull, propagates rc" t_no_pull_fail

t_pull_ok() {
  local ws fb rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  printf 'REMOTEDEV_HOST="fakehost"\nREMOTEDEV_ARTIFACTS=(out/app)\n' > .remotedev
  PATH="$fb:$PATH" "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1; rc=$?
  local got=""; [ -e out/app ] && got="$(cat out/app)"
  rm -rf "$ws"; assert_eq 0 "$rc"; assert_eq "PULLED" "$got"
}
run_test "runtime: successful build pulls artifacts" t_pull_ok

t_lock() {
  local ws fb; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  echo 'REMOTEDEV_HOST="fakehost"' > .remotedev; : > crit
  PATH="$fb:$PATH" RD_FAKE_SLEEP=1 RD_FAKE_CRIT="$ws/crit" "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1 &
  local p1=$!
  PATH="$fb:$PATH" RD_FAKE_SLEEP=1 RD_FAKE_CRIT="$ws/crit" "$RT/rd-exec" ./b.sh </dev/null >/dev/null 2>&1 &
  local p2=$!
  wait "$p1"; wait "$p2"
  local lines; mapfile -t lines < crit; rm -rf "$ws"
  [ "${#lines[@]}" -eq 4 ] || _fail "expected 4 markers, got ${#lines[@]}"
  assert_eq "${lines[0]##* }" "${lines[1]##* }"
  assert_eq "${lines[2]##* }" "${lines[3]##* }"
}
run_test "runtime: concurrent runs serialize (flock)" t_lock

summary
