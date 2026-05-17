#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"
_NL_CHK="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced" "$_NL_CHK"' EXIT
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"id1","name":"site","login":{"username":"u","password":"pw-secret"},
  "notes":"-----BEGIN OPENSSH PRIVATE KEY-----\nKEYBODY\n-----END OPENSSH PRIVATE KEY-----",
  "fields":[{"name":"api","value":"tok-123","type":1}]}]
JSON

assert_eq "pw-secret" "$(BW_SESSION=x bash bin/bw-get 'bw://site')" "password ref"
_exp_field="tok-123"   # single source: also drives the byte-length check below
assert_eq "$_exp_field" "$(BW_SESSION=x bash bin/bw-get 'bw://site/api')" "field ref"
# Field path must not append a trailing newline — it has to stay byte-consistent
# with `bw get password`, which bw-get forwards verbatim. $() would strip the
# newline and mask the bug, so capture to a file and assert the exact length.
# $(( )) normalizes the count: BSD/macOS `wc` left-pads it with spaces. The
# fixture token is ASCII so its char length (${#...}) equals its byte length.
BW_SESSION=x bash bin/bw-get 'bw://site/api' > "$_NL_CHK"
assert_eq "${#_exp_field}" "$(( $(wc -c < "$_NL_CHK") ))" "field ref: no trailing newline (exact bytes)"
assert_contains "$(BW_SESSION=x bash bin/bw-get 'bw://site/notes')" "BEGIN OPENSSH" "notes ref"
assert_contains "$(BW_SESSION=x bash bin/bw-get --ssh 'bw://site')" "KEYBODY" "--ssh returns notes key"
assert_status 1 'BW_SESSION=x bash bin/bw-get "bw://nope"' "missing item → error"
assert_status 1 'BW_SESSION=x bash bin/bw-get "bw://site/nofield"' "missing field → error"
assert_status 3 'env -u BW_SESSION bash bin/bw-get "bw://site"' "locked vault → exit 3"

finish
echo "PASS test_get"
