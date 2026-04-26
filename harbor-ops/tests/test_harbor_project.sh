#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- create with default (private) ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code POST '/api/v2.0/projects' 201
harbor-project create playground >/dev/null 2>&1
call="$(nth_call 1)"
assert_contains "$call" "POST" "POST method"
assert_contains "$call" '"project_name":"playground"' "name in body"
assert_contains "$call" '"public":"false"' "default private"

# --- create --public ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code POST '/api/v2.0/projects' 201
harbor-project create pubproj --public >/dev/null 2>&1
call="$(nth_call 1)"
assert_contains "$call" '"public":"true"' "--public flag"

# --- name validation: rejects uppercase ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
ec=0
err="$(harbor-project create UPPER 2>&1)" || ec=$?
assert_exit_code "$ec" "4" "uppercase name → exit 4"
assert_contains "$err" "lowercase" "validation message"

# --- delete with --yes ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code DELETE '/api/v2.0/projects/foo' 200
harbor-project delete foo --yes >/dev/null 2>&1
call="$(nth_call 1)"
assert_contains "$call" "DELETE" "DELETE method"
assert_contains "$call" "/api/v2.0/projects/foo" "URL"

# --- delete without --yes refuses on non-tty ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
ec=0
err="$(harbor-project delete foo 2>&1 </dev/null)" || ec=$?
assert_exit_code "$ec" "4" "non-tty no-yes refuse"

# --- set-public true ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code PUT '/api/v2.0/projects/foo' 200
harbor-project set-public foo true >/dev/null 2>&1
call="$(nth_call 1)"
assert_contains "$call" "PUT" "PUT method"
assert_contains "$call" '"public":"true"' "public true"

# --- set-public false ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code PUT '/api/v2.0/projects/foo' 200
harbor-project set-public foo false >/dev/null 2>&1
call="$(nth_call 1)"
assert_contains "$call" '"public":"false"' "public false"

echo "OK test_harbor_project"
