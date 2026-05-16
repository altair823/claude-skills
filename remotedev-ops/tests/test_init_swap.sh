#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-init"

mk_gradle_repo() {
  local ws; ws="$(new_workspace)"; cd "$ws"; git init -q
  printf '#!/bin/sh\necho REAL_GRADLEW\n' > gradlew; chmod +x gradlew
  git add gradlew; git commit -qm init; printf '%s' "$ws"
}

t_swap() {
  local ws; ws="$(mk_gradle_repo)"; cd "$ws"
  PATH="$(fixtures_path):$PATH" bash "$BIN" >/dev/null 2>&1
  [ -f gradlew.real ] || _fail "gradlew.real missing"
  assert_file_has gradlew.real "REAL_GRADLEW"
  assert_file_has gradlew "rd-exec ./gradlew.real"
  assert_eq "S" "$(git ls-files -v gradlew | cut -c1)"
  assert_file_has "$(git rev-parse --git-dir)/info/exclude" "gradlew.real"
  assert_file_has "$(git rev-parse --git-dir)/info/exclude" ".remotedev"
  rm -rf "$ws"
}
run_test "init swaps gradlew and hides changes from git" t_swap

t_swap_idempotent() {
  local ws; ws="$(mk_gradle_repo)"; cd "$ws"
  PATH="$(fixtures_path):$PATH" bash "$BIN" >/dev/null 2>&1
  PATH="$(fixtures_path):$PATH" bash "$BIN" --force >/dev/null 2>&1
  assert_file_has gradlew.real "REAL_GRADLEW"
  assert_file_has gradlew "rd-exec ./gradlew.real"
  rm -rf "$ws"
}
run_test "init swap is idempotent (no double-swap)" t_swap_idempotent

summary
