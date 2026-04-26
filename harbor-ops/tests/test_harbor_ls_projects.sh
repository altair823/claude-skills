#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- happy path table ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' \
    '[{"name":"p1","project_id":1,"metadata":{"public":"true"},"repo_count":3,"creation_time":"2026-04-20T10:11:00.000Z"},
      {"name":"p2","project_id":2,"metadata":{"public":"false"},"repo_count":7,"creation_time":"2026-04-21T08:30:00.000Z"}]'
out="$(harbor-ls projects 2>/dev/null)"
assert_contains "$out" "NAME" "header"
assert_contains "$out" "p1" "row p1"
assert_contains "$out" "p2" "row p2"

# --- --json passthrough ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' '[{"name":"p1"}]'
out="$(harbor-ls projects --json 2>/dev/null)"
assert_contains "$out" '"name":"p1"' "json output"

# --- --filter glob applied after fetch ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' \
    '[{"name":"alpha"},{"name":"beta"},{"name":"gamma"}]'
out="$(harbor-ls projects --filter 'a*' 2>/dev/null)"
assert_contains "$out" "alpha" "alpha kept"
assert_not_contains "$out" "beta" "beta filtered"
assert_not_contains "$out" "gamma" "gamma filtered"

# --- --limit truncates ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' \
    '[{"name":"a"},{"name":"b"},{"name":"c"}]'
out="$(harbor-ls projects --limit 1 2>/dev/null)"
assert_contains "$out" "a" "first kept"
assert_not_contains "$out" "b" "second dropped"

# --- empty result → header + (no results) note ---
teardown; setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects?page=1&page_size=100' '[]'
err="$(harbor-ls projects 2>&1 >/dev/null)"
assert_contains "$err" "no results" "empty stderr note"

echo "OK test_harbor_ls_projects"
