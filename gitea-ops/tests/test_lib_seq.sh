#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

setup
install_curl_stub
fixture_seq GET /api/v1/ping 'first' 'second' 'third'

out1="$(curl -sS -X GET https://gitea.test/api/v1/ping)"
assert_eq "$out1" "first" "1st call returns first body"
out2="$(curl -sS -X GET https://gitea.test/api/v1/ping)"
assert_eq "$out2" "second" "2nd call returns second body"
out3="$(curl -sS -X GET https://gitea.test/api/v1/ping)"
assert_eq "$out3" "third" "3rd call returns third body"
out4="$(curl -sS -X GET https://gitea.test/api/v1/ping)"
assert_eq "$out4" "third" "subsequent calls keep last body"
teardown
echo OK
