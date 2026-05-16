#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced"' EXIT
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"id1","name":"site","login":{"username":"u","password":"pw-secret"},
  "notes":null,"fields":[{"name":"api","value":"tok-123","type":1}]}]
JSON

# Value reaches the child via env only.
assert_eq "tok-123" "$(BW_SESSION=x bash bin/bw-exec API=bw://site/api -- printenv API)" "env injected"
out="$(BW_SESSION=x bash bin/bw-exec API=bw://site/api -- sh -c 'echo done')"
assert_eq "done" "$out" "cmd runs"

# Secret must NOT be in the child's own argv.
argv="$(BW_SESSION=x bash bin/bw-exec API=bw://site/api -- sh -c 'echo "$@"' _ )"
assert_not_contains "$argv" "tok-123" "secret absent from child argv"

assert_status 1 'BW_SESSION=x bash bin/bw-exec API=bw://site/api echo hi' "missing -- → usage error"
assert_status 1 'BW_SESSION=x bash bin/bw-exec -- echo hi' "no mapping → error"
assert_status 3 'env -u BW_SESSION bash bin/bw-exec API=bw://site/api -- true' "locked vault → exit 3"

finish
echo "PASS test_exec"
