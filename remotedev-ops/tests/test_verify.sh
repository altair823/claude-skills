#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
V="$RDO/bin/remotedev-verify"

t_no_cfg() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  bash "$V" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 2 "$rc"
}
run_test "verify without .remotedev exits 2" t_no_cfg

t_roundtrip() {
  [ -n "${REMOTEDEV_TEST_HOST:-}" ] || { echo "  (skipped: set REMOTEDEV_TEST_HOST)"; return 0; }
  local ws; ws="$(new_workspace)"; cd "$ws"
  printf 'REMOTEDEV_HOST="%s"\n' "$REMOTEDEV_TEST_HOST" > .remotedev
  bash "$V" >/dev/null 2>&1 || _fail "verify roundtrip failed against $REMOTEDEV_TEST_HOST"
  rm -rf "$ws"
}
run_test "verify roundtrip against real host (gated)" t_roundtrip

summary
