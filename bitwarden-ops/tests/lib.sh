# shellcheck shell=bash
# Assertion helpers. Source this in test_*.sh files.
# Tests are offline and stub-driven: prepend tests/stubs so it shadows the real
# bw. Every test_*.sh cd's to the skill root before sourcing this, so $PWD is
# the skill root here. (tests/run.sh also sets this; harmless to repeat.)
export PATH="$PWD/tests/stubs:$PATH"
_FAILS=0

assert_eq() { # expected actual msg
  if [[ "$1" == "$2" ]]; then echo "  ok: $3";
  else echo "  FAIL: $3 — expected [$1] got [$2]"; _FAILS=$((_FAILS+1)); fi
}
assert_contains() { # haystack needle msg
  if [[ "$1" == *"$2"* ]]; then echo "  ok: $3";
  else echo "  FAIL: $3 — [$1] does not contain [$2]"; _FAILS=$((_FAILS+1)); fi
}
assert_not_contains() { # haystack needle msg
  if [[ "$1" != *"$2"* ]]; then echo "  ok: $3";
  else echo "  FAIL: $3 — [$1] unexpectedly contains [$2]"; _FAILS=$((_FAILS+1)); fi
}
# assert_status: command MUST be ONE single-quoted string.
assert_status() { # expected_code cmd msg
  local exp="$1" cmd="$2" msg="$3" rc=0
  ( eval "$cmd" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$exp" ]]; then echo "  ok: $msg";
  else echo "  FAIL: $msg — expected exit $exp got $rc"; _FAILS=$((_FAILS+1)); fi
}
finish() { [[ $_FAILS -eq 0 ]] || { echo "  ($_FAILS failed)"; exit 1; }; }
