#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
D="$RDO/bin/remotedev-doctor"

mkcfg() { printf 'REMOTEDEV_HOST="fakehost"\n' > .remotedev; }

t_no_cfg() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  bash "$D" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 2 "$rc"
}
run_test "doctor without .remotedev exits 2" t_no_cfg

t_offline() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" RD_FAKE_HOST_UP=1 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 0 "$rc"; assert_contains "$out" "offline"
}
run_test "doctor offline → note + exit 0" t_offline

t_compatible() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=2.39 \
         RD_FAKE_UNAME=x86_64 RD_FAKE_GLIBC=2.35 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 0 "$rc"; assert_contains "$out" "COMPATIBLE"
}
run_test "doctor arch== & devbox glibc<=local → COMPATIBLE exit 0" t_compatible

t_arch_mismatch() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=2.39 \
         RD_FAKE_UNAME=aarch64 RD_FAKE_GLIBC=2.39 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 2 "$rc"; assert_contains "$out" "CRITICAL"
  assert_contains "$out" "aarch64"
}
run_test "doctor arch mismatch → CRITICAL exit 2" t_arch_mismatch

t_glibc_warn() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=2.31 \
         RD_FAKE_UNAME=x86_64 RD_FAKE_GLIBC=2.39 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 1 "$rc"; assert_contains "$out" "WARNING"
  assert_contains "$out" "GLIBC"
}
run_test "doctor devbox glibc>local → WARNING exit 1" t_glibc_warn

t_local_glibc_unknown() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=unknown \
         RD_FAKE_UNAME=x86_64 RD_FAKE_GLIBC=2.39 bash "$D" 2>&1)"; rc=$?
  rm -rf "$ws"
  assert_eq 0 "$rc"; assert_contains "$out" "COMPATIBLE"
}
run_test "doctor unknown local glibc → skip glibc compare, exit 0" t_local_glibc_unknown

t_brief() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"; mkcfg
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 REMOTEDEV_FAKE_LOCAL_GLIBC=2.39 \
         RD_FAKE_UNAME=aarch64 RD_FAKE_GLIBC=2.39 bash "$D" --brief 2>&1)"; rc=$?
  local lines; lines="$(printf '%s\n' "$out" | grep -c .)"
  rm -rf "$ws"
  assert_eq 2 "$rc"
  [ "$lines" -le 2 ] || _fail "--brief should be 1-2 lines, got $lines"
}
run_test "doctor --brief → ≤2 lines, same exit code" t_brief

t_real_gated() {
  [ -n "${REMOTEDEV_TEST_HOST:-}" ] || { echo "  (skipped: set REMOTEDEV_TEST_HOST)"; return 0; }
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  printf 'REMOTEDEV_HOST="%s"\n' "$REMOTEDEV_TEST_HOST" > .remotedev
  bash "$D" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"
  [ "$rc" -eq 0 ] || _fail "expected COMPATIBLE (exit 0) vs real $REMOTEDEV_TEST_HOST, got $rc"
}
run_test "doctor vs real host → COMPATIBLE (gated)" t_real_gated

summary
