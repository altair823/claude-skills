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

# --- --raw: diff body only, no header ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"X","head":{"ref":"h","sha":"a"},"base":{"ref":"main","sha":"b"},"user":{"login":"u"},"state":"open","html_url":""}'
fixture GET /api/v1/repos/owner/repo/pulls/42/files '[]'
fixture GET /api/v1/repos/owner/repo/pulls/42.diff 'DIFF_BODY_42'

out="$("$BIN/gitea-pr-diff" 42 --raw 2>&1)"
assert_contains "$out" "DIFF_BODY_42" "raw includes diff"
case "$out" in *"PR #42:"*) echo FAIL: header leaked into raw >&2; exit 1 ;; esac
teardown

# --- --json: parseable JSON object ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"My PR","head":{"ref":"feat","sha":"abc"},"base":{"ref":"main","sha":"def"},"user":{"login":"u"},"state":"open"}'
fixture GET /api/v1/repos/owner/repo/pulls/42/files \
    '[{"filename":"f.go","status":"modified","additions":5,"deletions":2}]'
fixture GET /api/v1/repos/owner/repo/pulls/42.diff 'diff --git a/f.go'

out="$("$BIN/gitea-pr-diff" 42 --json 2>&1)"
title="$(printf '%s' "$out" | jq -r '.title')"
assert_eq "$title" "My PR" "json has title"
fpath="$(printf '%s' "$out" | jq -r '.files[0].path')"
assert_eq "$fpath" "f.go" "json files[0].path"
base_ref="$(printf '%s' "$out" | jq -r '.base.ref')"
assert_eq "$base_ref" "main" "json base.ref"
head_ref="$(printf '%s' "$out" | jq -r '.head.ref')"
assert_eq "$head_ref" "feat" "json head.ref"
fstatus="$(printf '%s' "$out" | jq -r '.files[0].status')"
assert_eq "$fstatus" "modified" "json files[0].status"
diff_field="$(printf '%s' "$out" | jq -r '.diff')"
assert_eq "$diff_field" "diff --git a/f.go" "json diff field"
teardown

# --- 404: PR not found → die ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/999 '{"message":"Not found"}'
if "$BIN/gitea-pr-diff" 999 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on 404 >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "999" "error mentions PR number"
teardown

# --- /files endpoint returns error JSON → die ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"X","head":{"ref":"h","sha":"a"},"base":{"ref":"main","sha":"b"},"user":{"login":"u"},"state":"open","html_url":""}'
fixture GET /api/v1/repos/owner/repo/pulls/42/files '{"message":"forbidden"}'
if "$BIN/gitea-pr-diff" 42 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on files error >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "files" "error mentions files endpoint"
teardown

# --- /files endpoint error: --raw mode also dies (guard is mode-independent) ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"X","head":{"ref":"h","sha":"a"},"base":{"ref":"main","sha":"b"},"user":{"login":"u"},"state":"open","html_url":""}'
fixture GET /api/v1/repos/owner/repo/pulls/42/files '{"message":"forbidden"}'
if "$BIN/gitea-pr-diff" 42 --raw 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on files error in --raw mode >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "files" "error mentions files endpoint"
teardown

echo OK
