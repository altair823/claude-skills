#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help prints usage, exits 0 ---
setup
out="$("$BIN/gitea-pr-diff" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "PR#" "--help mentions PR# arg"
teardown

# --- missing PR# fails with clear error ---
setup
if "$BIN/gitea-pr-diff" 2>"$TEST_TMP/err"; then
    echo FAIL: expected exit non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
teardown

# --- unknown flag fails ---
setup
if "$BIN/gitea-pr-diff" 1 --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on unknown flag >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "unknown" "error mentions unknown"
teardown

# --- --raw and --json mutually exclusive ---
setup
if "$BIN/gitea-pr-diff" 1 --raw --json 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on conflicting flags >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "mutually exclusive" "error names conflict"
teardown

# --- default mode: meta header + diff ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"Add widget","html_url":"https://gitea.test/owner/repo/pulls/42","state":"open","user":{"login":"alice"},"head":{"ref":"feat/widget","sha":"abc1234"},"base":{"ref":"main","sha":"def5678"}}'
fixture GET /api/v1/repos/owner/repo/pulls/42/files \
    '[{"filename":"src/a.go","status":"modified","additions":10,"deletions":3},{"filename":"src/b.sh","status":"added","additions":50,"deletions":0}]'
fixture GET /api/v1/repos/owner/repo/pulls/42.diff \
    'diff --git a/src/a.go b/src/a.go
@@ -1,1 +1,1 @@
-old
+new
'

out="$("$BIN/gitea-pr-diff" 42 2>&1)"
assert_contains "$out" "PR #42: Add widget" "header has PR title"
assert_contains "$out" "feat/widget" "header has head ref"
assert_contains "$out" "main" "header has base ref"
assert_contains "$out" "alice" "header has author"
assert_contains "$out" "src/a.go" "file list shows path"
assert_contains "$out" "+10 -3" "file list shows stats"
assert_contains "$out" "--- DIFF ---" "diff section header"
assert_contains "$out" "+new" "diff body included"
teardown

echo OK
