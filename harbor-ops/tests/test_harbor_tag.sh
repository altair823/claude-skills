#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- delete tag with --yes ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code DELETE '/api/v2.0/projects/p/repositories/r/artifacts/v1/tags/v1' 200
harbor-tag delete p/r:v1 --yes >/dev/null 2>&1
call="$(nth_call 1)"
assert_contains "$call" "DELETE" "DELETE method"
assert_contains "$call" "/artifacts/v1/tags/v1" "tag-scoped delete URL"

# --- delete refuses without --yes on non-tty ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
ec=0
err="$(harbor-tag delete p/r:v1 2>&1 </dev/null)" || ec=$?
assert_exit_code "$ec" "4" "non-tty no-yes refuse"

# --- copy: POST artifacts with from= query ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code POST '/api/v2.0/projects/dstproj/repositories/dstrepo/artifacts?from=srcproj%2Fsrcrepo%3Av1' 201
harbor-tag copy srcproj/srcrepo:v1 dstproj/dstrepo:v1 >/dev/null 2>&1
call="$(nth_call 1)"
assert_contains "$call" "POST" "POST"
assert_contains "$call" "from=srcproj%2Fsrcrepo%3Av1" "from query (URL-encoded)"
assert_contains "$call" "/projects/dstproj/repositories/dstrepo/artifacts" "dst path"

# --- arg validation: missing tag → exit 4 ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
ec=0
harbor-tag delete p/r --yes 2>/dev/null || ec=$?
assert_exit_code "$ec" "4" "missing tag exits 4"

echo "OK test_harbor_tag"
