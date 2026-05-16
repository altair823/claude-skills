#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
INIT="$RDO/bin/remotedev-init"
DIS="$RDO/bin/remotedev-disable"

setup_repo() {
  local ws; ws="$(new_workspace)"; cd "$ws"; git init -q
  printf '#!/bin/sh\necho REAL\n' > gradlew; chmod +x gradlew
  git add gradlew; git commit -qm init
  PATH="$(fixtures_path):$PATH" bash "$INIT" >/dev/null 2>&1
  printf '%s' "$ws"
}

t_disable_restores() {
  local ws; ws="$(setup_repo)"; cd "$ws"
  bash "$DIS" >/dev/null 2>&1
  assert_file_absent gradlew.real
  assert_file_has gradlew "REAL"
  assert_eq "" "$(git ls-files -v gradlew | cut -c1 | tr -d H)"
  [ -f .remotedev ] || _fail ".remotedev should remain without --purge"
  rm -rf "$ws"
}
run_test "disable restores launcher, keeps .remotedev" t_disable_restores

t_disable_purge() {
  local ws; ws="$(setup_repo)"; cd "$ws"
  bash "$DIS" --purge >/dev/null 2>&1
  assert_file_absent .remotedev
  rm -rf "$ws"
}
run_test "disable --purge removes .remotedev" t_disable_purge

t_disable_noop() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"; git init -q
  bash "$DIS" >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"
}
run_test "disable with nothing set up is a no-op" t_disable_noop

summary
