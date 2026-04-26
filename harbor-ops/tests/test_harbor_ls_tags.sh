#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# --- multi-tag artifact, untagged artifact, digest truncation, IEC size ---
setup; trap teardown EXIT
write_default_config; install_curl_stub
fixture GET '/api/v2.0/projects/p/repositories/r/artifacts?with_tag=true&with_scan_overview=false&page=1&page_size=100' \
    '[
       {"digest":"sha256:abcdef0123456789aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "size":47185920,
        "push_time":"2026-04-20T10:11:00.000Z",
        "tags":[{"name":"v1.2.0"},{"name":"latest"}]},
       {"digest":"sha256:9999999999999999bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "size":1024,
        "push_time":"2026-04-19T08:30:00.000Z",
        "tags":null}
     ]'
out="$(harbor-ls tags p/r 2>/dev/null)"
assert_contains "$out" "v1.2.0" "v1.2.0 row"
assert_contains "$out" "latest" "latest row"
assert_contains "$out" "<none>" "untagged shown"
assert_contains "$out" "sha256:abcdef012345" "digest truncated"
assert_not_contains "$out" "abcdef0123456789aa" "full digest hidden"
assert_contains "$out" "MiB" "IEC size"

echo "OK test_harbor_ls_tags"
