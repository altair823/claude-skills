#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help ---
setup
out="$("$BIN/gitea-mirror-push" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "--gh-repo" "--help mentions --gh-repo"
teardown

# --- missing --gh-repo → die ---
setup
if "$BIN/gitea-mirror-push" 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "--gh-repo 필수" "error mentions --gh-repo requirement"
teardown

# --- unknown arg → die ---
setup
if "$BIN/gitea-mirror-push" --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "알 수 없는 인자" "error mentions unknown arg"
teardown

# --- --force-mirror 가 args parser 에서 정상 인식 (--gh-repo 검증에서 die, unknown arg 가 아님) ---
setup
if "$BIN/gitea-mirror-push" --force-mirror 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "--gh-repo 필수" "--force-mirror alone still requires --gh-repo"
case "$(cat "$TEST_TMP/err")" in
    *"알 수 없는 인자"*) echo "FAIL: --force-mirror flagged as unknown" >&2; exit 1 ;;
esac
teardown

echo OK
