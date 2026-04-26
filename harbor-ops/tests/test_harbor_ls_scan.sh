#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- scanned artifact: severity counts populated ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories/r/artifacts/v1?with_scan_overview=true' \
    '{
       "digest":"sha256:aaaa",
       "scan_overview":{
         "application/vnd.security.vulnerability.report; version=1.1": {
           "scan_status":"Success",
           "end_time":"2026-04-24T10:11:23.000Z",
           "summary": { "summary": {"Critical":2,"High":5,"Medium":8,"Low":3,"Unknown":1} }
         }
       }
     }'
out="$(harbor-ls scan p/r:v1 2>/dev/null)"
assert_contains "$out" "Success" "status shown"
assert_contains "$out" "p/r:v1" "ref shown"
assert_contains "$out" "2" "critical count"
assert_contains "$out" "5" "high count"

# --- multiple scanner keys: lexicographic first wins ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories/r/artifacts/v1?with_scan_overview=true' \
    '{
       "scan_overview":{
         "zz-scanner":{"scan_status":"Error","summary":{"summary":{}}},
         "aa-scanner":{"scan_status":"Success","summary":{"summary":{"Critical":1}}}
       }
     }'
out="$(harbor-ls scan p/r:v1 2>/dev/null)"
assert_contains "$out" "Success" "lex-first scanner status"
assert_not_contains "$out" "Error" "later scanner ignored"

# --- not yet scanned: empty scan_overview ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories/r/artifacts/v1?with_scan_overview=true' \
    '{"scan_overview":{}}'
out="$(harbor-ls scan p/r:v1 2>/dev/null)"
assert_contains "$out" "Not Scanned" "fallback status"

echo "OK test_harbor_ls_scan"
