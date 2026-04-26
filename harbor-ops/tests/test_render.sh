#!/bin/sh
. "$(dirname "$0")/lib.sh"

run() {
    bash -c "
        set -euo pipefail
        export PATH='$PATH'
        . '$BIN/_common.sh'
        $1
    "
}

# --- format_size: bytes → IEC ---
out="$(run "format_size 0")"
assert_eq "$out" "0.0B" "0 bytes"
out="$(run "format_size 1024")"
assert_eq "$out" "1.0KiB" "1KiB"
out="$(run "format_size 47185920")"
assert_contains "$out" "MiB" "MiB"

# --- render_table: simple two-column ---
input='[{"name":"a","count":1},{"name":"b","count":2}]'
out="$(run "echo '$input' | render_table 'NAME=.name' 'COUNT=.count'")"
assert_contains "$out" "NAME" "header present"
assert_contains "$out" "COUNT" "header present"
assert_contains "$out" "a" "row a"
assert_contains "$out" "b" "row b"

# --- render_table: empty input → header + (no results) on stderr ---
out_e="$(run "echo '[]' | render_table 'NAME=.name' 2>&1 1>/dev/null")"
assert_contains "$out_e" "no results" "empty stderr note"

# --- render_json: passthrough compact ---
out="$(run "echo '$input' | render_json")"
assert_eq "$out" '[{"name":"a","count":1},{"name":"b","count":2}]' "json compact"

# --- render_json: empty array stays [] ---
out="$(run "echo '[]' | render_json")"
assert_eq "$out" "[]" "empty json"

echo "OK test_render"
