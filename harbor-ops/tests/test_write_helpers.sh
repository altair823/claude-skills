#!/bin/sh
# Test harbor_post / harbor_put / harbor_delete + confirm.
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

# --- POST 201 with body sent ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code POST '/api/v2.0/projects' 201
fixture      POST '/api/v2.0/projects' ''
out="$(run_with_lib "harbor_post /api/v2.0/projects '{\"project_name\":\"foo\"}'")"
call="$(nth_call 1)"
assert_contains "$call" "POST" "POST method"
assert_contains "$call" '"project_name":"foo"' "body sent"

# --- PUT 200 ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code PUT '/api/v2.0/projects/foo' 200
fixture      PUT '/api/v2.0/projects/foo' '{"updated":true}'
out="$(run_with_lib "harbor_put /api/v2.0/projects/foo '{\"metadata\":{\"public\":\"true\"}}'")"
call="$(nth_call 1)"
assert_contains "$call" "PUT" "PUT method"

# --- DELETE 200 ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code DELETE '/api/v2.0/projects/foo' 200
fixture      DELETE '/api/v2.0/projects/foo' ''
ec=0
run_with_lib "harbor_delete /api/v2.0/projects/foo" >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "0" "DELETE 200"
call="$(nth_call 1)"
assert_contains "$call" "DELETE" "DELETE method"

# --- POST 409 conflict → exit 1 with 'conflict' message ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture_code POST '/api/v2.0/projects' 409
fixture      POST '/api/v2.0/projects' '{"errors":[{"code":"CONFLICT","message":"project foo already exists"}]}'
ec=0
err="$(run_with_lib "harbor_post /api/v2.0/projects '{\"project_name\":\"foo\"}'" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "1" "409 → exit 1"
assert_contains "$err" "conflict" "409 message"

# --- confirm: HARBOR_YES=1 bypasses, returns 0 ---
ec=0
run_with_lib "HARBOR_YES=1 confirm 'really delete?'" >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "0" "HARBOR_YES bypass"

# --- confirm: non-tty without HARBOR_YES → exit 4 ---
ec=0
err="$(run_with_lib "confirm 'really delete?'" 2>&1 </dev/null)" || ec=$?
assert_exit_code "$ec" "4" "non-tty no-yes refuse"
assert_contains "$err" "stdin is not a tty" "non-tty message"

echo "OK test_write_helpers"
