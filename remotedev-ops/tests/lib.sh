# tests/lib.sh — zero-dependency assertions for remotedev-ops.
# Each test runs in its own subshell via `run_test "name" body-fn`.

RDO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # skill root

_T_PASS=0
_T_FAIL=0

new_workspace() { mktemp -d "${TMPDIR:-/tmp}/rdo-test.XXXXXX"; }

_fail() { printf '       %s\n' "$1" >&2; exit 1; }

assert_eq()          { [ "$1" = "$2" ] || _fail "expected [$1], got [$2]"; }
assert_contains()    { case "$1" in *"$2"*) : ;; *) _fail "expected to contain [$2], got [$1]" ;; esac; }
assert_not_contains(){ case "$1" in *"$2"*) _fail "expected NOT to contain [$2], got [$1]" ;; esac; }
assert_file_has()    { grep -qF -- "$2" "$1" || _fail "[$1] missing [$2]"; }
assert_file_absent() { [ ! -e "$1" ] || _fail "[$1] should not exist"; }

# fixtures dir holding fake ssh/rsync; prepend to PATH for server-free tests.
fixtures_path() {
  chmod +x "$RDO/tests/fixtures/ssh" "$RDO/tests/fixtures/rsync"
  printf '%s' "$RDO/tests/fixtures"
}

run_test() {
  local name="$1"; shift
  if ( set -uo pipefail; "$@" ) 2> >(sed 's/^/  /' >&2); then
    _T_PASS=$((_T_PASS+1)); printf '  ok   %s\n' "$name"
  else
    _T_FAIL=$((_T_FAIL+1)); printf '  FAIL %s\n' "$name"
  fi
}

summary() { printf '\n%d passed, %d failed\n' "$_T_PASS" "$_T_FAIL"; [ "$_T_FAIL" -eq 0 ]; }
