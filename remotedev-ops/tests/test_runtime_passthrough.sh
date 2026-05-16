#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
RT="$RDO/runtime"

t_slash() {
  local ws; ws="$(new_workspace)"; cd "$ws"
  printf '#!/usr/bin/env bash\necho GR args=$*\n' > g.real; chmod +x g.real
  local out rc; out="$("$RT/rd-exec" ./g.real build 2>&1)"; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"; assert_contains "$out" "GR args=build"
}
run_test "runtime: passthrough runs a slash-path command" t_slash

t_pathcmd() {
  local ws; ws="$(new_workspace)"; cd "$ws"; mkdir rb
  printf '#!/usr/bin/env bash\necho MT args=$*\n' > rb/mytool; chmod +x rb/mytool
  local out rc; out="$(PATH="$ws/rb:$PATH" "$RT/rd-exec" mytool x 2>&1)"; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"; assert_contains "$out" "MT args=x"
}
run_test "runtime: passthrough runs a PATH command" t_pathcmd

t_offline() {
  local ws; ws="$(new_workspace)"; cd "$ws"
  echo 'REMOTEDEV_HOST="192.0.2.1"' > .remotedev
  printf '#!/usr/bin/env bash\necho LOCAL_BUILD\n' > b.sh; chmod +x b.sh
  local out rc; out="$("$RT/rd-exec" ./b.sh 2>&1)"; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"
  assert_contains "$out" "offline fallback"; assert_contains "$out" "LOCAL_BUILD"
}
run_test "runtime: offline fallback builds locally" t_offline

t_shimskip() {
  local ws; ws="$(new_workspace)"; cd "$ws"; mkdir shims rb
  ln -s "$RT/rd-shim" shims/mytool
  printf '#!/usr/bin/env bash\necho REAL args=$*\n' > rb/mytool; chmod +x rb/mytool
  local out rc
  out="$(REMOTEDEV_SHIM_DIR="$ws/shims" PATH="$ws/shims:$ws/rb:$PATH" "$ws/shims/mytool" b 2>&1)"; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"; assert_contains "$out" "REAL args=b"
}
run_test "runtime: shim skips itself, finds real binary" t_shimskip

summary
