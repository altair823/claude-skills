#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"i1","name":"site-a","login":{"password":"SECRETA"},"notes":null,
  "fields":[{"name":"api","value":"FIELDSECRET","type":1}]},
 {"id":"i2","name":"db-b","login":{"password":"SECRETB"},"notes":null,"fields":[]}]
JSON

out="$(BW_SESSION=x bash bin/bw-ls)"
assert_contains "$out" "site-a" "lists item name"
assert_contains "$out" "db-b" "lists second item"
assert_contains "$out" "api" "lists field name"
assert_not_contains "$out" "SECRETA" "no password value in output"
assert_not_contains "$out" "FIELDSECRET" "no field value in output"

out2="$(BW_SESSION=x bash bin/bw-ls site)"
assert_contains "$out2" "site-a" "search match shown"
assert_not_contains "$out2" "db-b" "search filters out non-match"

assert_status 3 'env -u BW_SESSION bash bin/bw-ls' "locked vault → exit 3"

finish
echo "PASS test_ls"
