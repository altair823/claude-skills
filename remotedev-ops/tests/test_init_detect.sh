#!/usr/bin/env bash
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
BIN="$RDO/bin/remotedev-init"
CONTRACT='REMOTEDEV_HOST REMOTEDEV_REMOTE_DIR REMOTEDEV_EXCLUDES REMOTEDEV_ARTIFACTS BUILD_CMD TEST_CMD RUN_CMD'

init() { local d="$1"; shift; ( cd "$d" && PATH="$(fixtures_path):$PATH" RD_FAKE_LOG=/dev/null bash "$BIN" "$@" ); }

t_cargo() {
  local ws; ws="$(new_workspace)"; cd "$ws"; echo '[package]
name = "demo"' > Cargo.toml
  init "$ws" >/dev/null 2>&1
  assert_file_has .remotedev 'REMOTEDEV_HOST="devbox"'
  assert_file_has .remotedev 'BUILD_CMD="cargo build --release"'
  assert_file_has .remotedev 'TEST_CMD="cargo test"'
  assert_file_has .remotedev 'target/release/demo'
  rm -rf "$ws"
}
run_test "init detects Cargo and fills verbs" t_cargo

t_none() {
  local ws; ws="$(new_workspace)"; cd "$ws"
  init "$ws" >/dev/null 2>&1
  assert_file_has .remotedev 'REMOTEDEV_HOST="devbox"'
  assert_file_has .remotedev '# BUILD_CMD='
  rm -rf "$ws"
}
run_test "init with no build system writes commented verbs" t_none

t_host_arg() {
  local ws; ws="$(new_workspace)"; cd "$ws"
  init "$ws" myhost >/dev/null 2>&1
  assert_file_has .remotedev 'REMOTEDEV_HOST="myhost"'
  rm -rf "$ws"
}
run_test "init accepts HOST argument" t_host_arg

t_idempotent() {
  local ws rc; ws="$(new_workspace)"; cd "$ws"
  init "$ws" >/dev/null 2>&1
  init "$ws" >/dev/null 2>&1; rc=$?
  assert_eq 2 "$rc"
  init "$ws" --force >/dev/null 2>&1; rc=$?
  rm -rf "$ws"; assert_eq 0 "$rc"
}
run_test "init refuses overwrite without --force" t_idempotent

t_contract() {
  local ws; ws="$(new_workspace)"; cd "$ws"; echo '[package]
name="x"' > Cargo.toml
  init "$ws" >/dev/null 2>&1
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    local var="${line%%=*}"
    case " $CONTRACT " in *" $var "*) : ;; *) _fail "non-contract var: $var" ;; esac
  done < .remotedev
  rm -rf "$ws"
}
run_test "init emits only contract variables" t_contract

summary
