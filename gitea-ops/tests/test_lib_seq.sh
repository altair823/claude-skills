#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

setup
install_curl_stub
fixture_seq GET /api/v1/ping 'first' 'second' 'third'

# Drive the stub via `tea api` (post-migration); the fixture key remains
# /api/v1/ping because the stub auto-prefixes /api/v1.
out1="$(tea api -X GET --login gitea-ops-author /ping)"
assert_eq "$out1" "first" "1st call returns first body"
out2="$(tea api -X GET --login gitea-ops-author /ping)"
assert_eq "$out2" "second" "2nd call returns second body"
out3="$(tea api -X GET --login gitea-ops-author /ping)"
assert_eq "$out3" "third" "3rd call returns third body"
out4="$(tea api -X GET --login gitea-ops-author /ping)"
assert_eq "$out4" "third" "subsequent calls keep last body"
teardown
echo OK
