#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"; echo '[]' > "$BW_STUB_DB"
SECRET="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced" "$SECRET"' EXIT
export BITWARDEN_OPS_TEST_SECRET_FILE="$SECRET"

# 1) Create new password item.
printf 'new-pw' > "$SECRET"
out="$(BW_SESSION=x bash bin/bw-put 'bw://acct')"
assert_contains "$out" "created: bw://acct" "create announces"
assert_eq "0" "$([[ -f "$BW_STUB_DB.synced" ]]; echo $?)" "sync ran before write"
assert_eq "new-pw" "$(BW_SESSION=x bash bin/bw-get 'bw://acct')" "value round-trips"

# 2) Overwrite without --replace is refused.
printf 'changed' > "$SECRET"
assert_status 1 "BW_SESSION=x bash bin/bw-put 'bw://acct'" "overwrite needs --replace"
assert_eq "new-pw" "$(BW_SESSION=x bash bin/bw-get 'bw://acct')" "value unchanged after refusal"

# 3) Overwrite with --replace succeeds.
out3="$(BW_SESSION=x bash bin/bw-put 'bw://acct' --replace)"
assert_contains "$out3" "updated: bw://acct" "replace announces update"
assert_eq "changed" "$(BW_SESSION=x bash bin/bw-get 'bw://acct')" "value replaced"

# 4) Field create on new item, then notes.
printf 'tokv' > "$SECRET"
BW_SESSION=x bash bin/bw-put 'bw://svc/api' >/dev/null
assert_eq "tokv" "$(BW_SESSION=x bash bin/bw-get 'bw://svc/api')" "new field round-trips"

# 4b) Note create (ref-shaped and explicit --type), and --type override.
printf 'note-body' > "$SECRET"
BW_SESSION=x bash bin/bw-put 'bw://nt/notes' >/dev/null
assert_eq "note-body" "$(BW_SESSION=x bash bin/bw-get 'bw://nt/notes')" "note ref round-trips"
printf 'forced-note' > "$SECRET"
BW_SESSION=x bash bin/bw-put 'bw://nt2' --type note >/dev/null
assert_eq "forced-note" "$(BW_SESSION=x bash bin/bw-get 'bw://nt2/notes')" "--type note override round-trips"

# 5) Empty value rejected.
: > "$SECRET"
assert_status 1 "BW_SESSION=x bash bin/bw-put 'bw://acct' --replace" "empty value rejected"

# 6) Locked vault.
assert_status 3 "env -u BW_SESSION bash bin/bw-put 'bw://acct'" "locked vault → exit 3"

finish
echo "PASS test_put"
