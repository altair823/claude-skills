# shellcheck shell=bash
# Assertion helpers. Source this in test_*.sh files.
# Tests are offline and stub-driven: prepend tests/stubs so it shadows the real
# bw/curl/ssh. Every test_*.sh cd's to the repo root before sourcing this, so
# $PWD is the repo root here. (tests/run.sh also sets this; harmless to repeat.)
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
# assert_status: the command MUST be passed as ONE single-quoted string,
# e.g. assert_status 3 'env -u BW_SESSION bin/foo bar' "msg"
# (unquoted multi-token commands are silently truncated and give wrong verdicts)
assert_status() { # expected_code cmd... msg(last arg)
  local exp="$1"; local msg="${@: -1}"; local n=$#; set -- "${@:2:n-2}"
  local rc=0; ( eval "$*" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$exp" ]]; then echo "  ok: $msg";
  else echo "  FAIL: $msg — expected exit $exp got $rc"; _FAILS=$((_FAILS+1)); fi
}
finish() { [[ $_FAILS -eq 0 ]] || { echo "  ($_FAILS failed)"; exit 1; }; }
