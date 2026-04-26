#!/bin/sh
# Sanity check: lib.sh sandbox + curl stub + fixtures.
. "$(dirname "$0")/lib.sh"
setup
trap teardown EXIT

install_curl_stub
fixture GET /api/v2.0/projects '[{"name":"p1"}]'
fixture_code GET /api/v2.0/projects 200
fixture_hdrs GET /api/v2.0/projects 'X-Total-Count: 1
'

body="$(curl -s 'https://harbor.test/api/v2.0/projects')"
assert_eq "$body" '[{"name":"p1"}]' "stub returns body"

cnt="$(call_count)"
assert_eq "$cnt" "1" "one call recorded"

echo "OK test_lib_smoke"
