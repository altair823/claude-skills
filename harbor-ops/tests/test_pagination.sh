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

# --- single page, no Link header → stops after page 1 ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' '[{"name":"p1"},{"name":"p2"}]'
fixture_hdrs GET '/api/v2.0/projects?page=1&page_size=100' 'X-Total-Count: 2
'
out="$(run_with_lib "harbor_get_paginated /api/v2.0/projects")"
assert_contains "$out" '"p1"' "single-page p1"
assert_contains "$out" '"p2"' "single-page p2"
assert_eq "$(call_count)" "1" "single call"

# --- two pages, Link rel=next on page 1 only ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' '[{"name":"p1"}]'
fixture_hdrs GET '/api/v2.0/projects?page=1&page_size=100' 'X-Total-Count: 2
Link: </api/v2.0/projects?page=2&page_size=100>; rel="next"
'
fixture GET '/api/v2.0/projects?page=2&page_size=100' '[{"name":"p2"}]'
fixture_hdrs GET '/api/v2.0/projects?page=2&page_size=100' 'X-Total-Count: 2
'
out="$(run_with_lib "harbor_get_paginated /api/v2.0/projects")"
assert_contains "$out" '"p1"' "page 1 included"
assert_contains "$out" '"p2"' "page 2 included"
assert_eq "$(call_count)" "2" "two calls made"

# --- extra-query is preserved ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?with_tag=true&page=1&page_size=100' '[]'
out="$(run_with_lib "harbor_get_paginated /api/v2.0/projects 'with_tag=true'")"
assert_eq "$out" '[]' "empty page handled"

echo "OK test_pagination"
