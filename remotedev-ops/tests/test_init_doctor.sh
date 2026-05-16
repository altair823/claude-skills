#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-init"

t_init_runs_doctor_and_stays_zero() {
  local ws fb out rc; ws="$(new_workspace)"; cd "$ws"; fb="$(fixtures_path)"
  echo '[package]
name="x"' > Cargo.toml
  out="$(PATH="$fb:$PATH" REMOTEDEV_FAKE_LOCAL_ARCH=x86_64 RD_FAKE_UNAME=aarch64 \
         bash "$BIN" 2>&1)"; rc=$?
  assert_eq 0 "$rc"
  assert_file_has .remotedev 'REMOTEDEV_HOST="devbox"'
  assert_contains "$out" "env-compat"
  rm -rf "$ws"
}
run_test "init runs doctor advisory and still exits 0" t_init_runs_doctor_and_stays_zero

summary
