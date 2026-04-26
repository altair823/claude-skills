#!/bin/sh
. "$(dirname "$0")/lib.sh"

run_with_lib() {
    bash -c "
        set -euo pipefail
        export HOME='$HOME' PATH='$PATH'
        . '$BIN/_common.sh'
        load_profile
        $1
    "
}

# --- happy 200 ---
setup; trap teardown EXIT
write_default_config
install_curl_stub
fixture GET '/api/v2.0/projects' '[{"name":"p1"}]'
out="$(run_with_lib "harbor_get /api/v2.0/projects")"
assert_eq "$out" '[{"name":"p1"}]' "200 returns body"

# --- auth header carries Basic alice:secret-1 ---
expected_b64="$(printf 'alice:secret-1' | base64 -w0 2>/dev/null || printf 'alice:secret-1' | base64)"
call="$(nth_call 1)"
assert_contains "$call" "Authorization: Basic $expected_b64" "auth header set"

# --- 401 → exit 2, message names auth ---
teardown; setup; trap teardown EXIT
write_default_config
install_curl_stub
fixture GET '/api/v2.0/projects' ''
fixture_code GET '/api/v2.0/projects' 401
ec=0; err="$(run_with_lib "harbor_get /api/v2.0/projects" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "2" "401 exits 2"
assert_contains "$err" "auth failed" "auth message"

# --- 403 → exit 2 ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code GET '/api/v2.0/projects' 403
ec=0; run_with_lib "harbor_get /api/v2.0/projects" >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "2" "403 exits 2"

# --- 404 → exit 1, message contains path ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code GET '/api/v2.0/projects/none' 404
ec=0; err="$(run_with_lib "harbor_get /api/v2.0/projects/none" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "1" "404 exits 1"
assert_contains "$err" "not found" "404 message"

# --- 500 → exit 1, surfaces body ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects' 'oops the server is on fire'
fixture_code GET '/api/v2.0/projects' 500
ec=0; err="$(run_with_lib "harbor_get /api/v2.0/projects" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "1" "500 exits 1"
assert_contains "$err" "500" "shows status"
assert_contains "$err" "oops" "shows body excerpt"

echo "OK test_auth_errors"
