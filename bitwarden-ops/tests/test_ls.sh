#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"i1","name":"site-a","type":1,"login":{"username":"USERA","password":"SECRETA"},"notes":null,
  "fields":[{"name":"api","value":"FIELDSECRET","type":1}]},
 {"id":"i2","name":"db-b","type":1,"login":{"password":"SECRETB"},"notes":null,"fields":[]},
 {"id":"i3","name":"memo-c","type":2,"login":null,"notes":"NOTESECRET","fields":[]},
 {"id":"i4","name":"empty-d","type":1,"login":{"username":null,"password":null},"notes":null,"fields":[]}]
JSON

out="$(BW_SESSION=x bash bin/bw-ls)"
assert_contains "$out" "site-a" "lists item name"
assert_contains "$out" "db-b" "lists second item"
assert_contains "$out" "api" "lists field name"
assert_not_contains "$out" "SECRETA" "no password value in output"
assert_not_contains "$out" "FIELDSECRET" "no field value in output"
assert_not_contains "$out" "USERA" "no username value in output"
assert_not_contains "$out" "NOTESECRET" "no notes value in output"
assert_contains "$out" $'site-a\tlogin\tusername,password,api' "login: kind and refs"
assert_contains "$out" $'db-b\tlogin\tpassword' "login without username"
assert_contains "$out" $'memo-c\tnote\tnotes' "secure note: kind and refs"
assert_contains "$out" $'empty-d\tlogin\t-' "no refs shown as -"

out2="$(BW_SESSION=x bash bin/bw-ls site)"
assert_contains "$out2" "site-a" "search match shown"
assert_not_contains "$out2" "db-b" "search filters out non-match"

assert_status 3 'env -u BW_SESSION bash bin/bw-ls' "locked vault → exit 3"
assert_status 3 'BW_SESSION=x BW_STUB_STATUS=locked bash bin/bw-ls' "expired session → exit 3, not empty list"

finish
echo "PASS test_ls"
