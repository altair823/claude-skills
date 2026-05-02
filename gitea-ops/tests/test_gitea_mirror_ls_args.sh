#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help ---
setup
out="$("$BIN/gitea-mirror-ls" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "--json" "--help mentions --json"
teardown

# --- unknown arg → die ---
setup
if "$BIN/gitea-mirror-ls" --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "알 수 없는 인자" "error mentions unknown arg"
teardown

# --- list returns rows from fixture ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/push_mirrors \
    '[{"remote_name":"github-mirror","remote_address":"https://github.com/u/r.git","interval":"8h0m0s","sync_on_commit":true,"last_update":"2026-04-30T01:23:45Z"}]'
out="$("$BIN/gitea-mirror-ls" 2>&1)"
assert_contains "$out" "github-mirror" "ls prints remote_name"
assert_contains "$out" "https://github.com/u/r.git" "ls prints remote_address"
assert_contains "$out" "interval=8h0m0s" "ls prints interval"
teardown

# --- empty list ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/push_mirrors '[]'
out="$("$BIN/gitea-mirror-ls" 2>&1)"
assert_contains "$out" "(no push mirrors)" "empty list message"
teardown

echo OK
