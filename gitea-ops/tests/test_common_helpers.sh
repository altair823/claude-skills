#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
. "$BIN/_common.sh"

setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"merged":false,"head":{"ref":"feat/x"},"base":{"ref":"main"}}'

out="$(gitea_get "/repos/owner/repo/pulls/42")"
assert_contains "$out" '"head"' "gitea_get returns body"

# call must use GET with no body
call="$(nth_call 1)"
method="$(printf '%s' "$call" | cut -f1)"
assert_eq "$method" "GET" "method is GET"

teardown
echo OK
