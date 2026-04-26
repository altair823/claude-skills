#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- explicit project ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/myproj/repositories?page=1&page_size=100' \
    '[{"name":"myproj/api","artifact_count":3,"pull_count":42,"update_time":"2026-04-20T10:11:00.000Z"}]'
out="$(harbor-ls repos myproj 2>/dev/null)"
assert_contains "$out" "api" "repo name shown"

# --- detect-fill from manifest ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/Dockerfile" <<DF
FROM harbor.test/team-x/anything:v1
DF
fixture GET '/api/v2.0/projects/team-x/repositories?page=1&page_size=100' \
    '[{"name":"team-x/svc"}]'
out="$(cd "$TEST_TMP/proj" && harbor-ls repos 2>/dev/null)"
assert_contains "$out" "svc" "detected project queried"

# --- 404 project → exit 1 ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code GET '/api/v2.0/projects/no-such/repositories?page=1&page_size=100' 404
ec=0
harbor-ls repos no-such >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "1" "404 → exit 1"

# --- --filter on repo name ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories?page=1&page_size=100' \
    '[{"name":"p/alpha"},{"name":"p/beta"}]'
out="$(harbor-ls repos p --filter 'a*' 2>/dev/null)"
assert_contains "$out" "alpha" "alpha kept"
assert_not_contains "$out" "beta" "beta filtered"

echo "OK test_harbor_ls_repos"
