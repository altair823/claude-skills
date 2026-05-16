#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

CDIR="$(mktemp -d)/c"
export BITWARDEN_OPS_CACHE_DIR="$CDIR"
FAKE="$(mktemp)"
export BITWARDEN_OPS_TEST_SESSION_FILE="$FAKE"
trap 'rm -rf "$(dirname "$CDIR")" "$FAKE"' EXIT

# 1) writes the session file with correct perms
printf 'sess-AAA' > "$FAKE"
out="$(bash bin/bw-unlock)"
assert_contains "$out" "$CDIR/session" "announces stored path"
assert_eq "sess-AAA" "$(cat "$CDIR/session")" "session written"
assert_eq "600" "$(stat -c '%a' "$CDIR/session")" "session file is 0600"
assert_eq "700" "$(stat -c '%a' "$CDIR")" "cache dir is 0700"

# 2) re-unlock replaces
printf 'sess-BBB' > "$FAKE"
bash bin/bw-unlock >/dev/null
assert_eq "sess-BBB" "$(cat "$CDIR/session")" "re-unlock replaces session"

# 3) empty session is rejected (no file clobber)
printf 'sess-BBB' > "$CDIR/session"
: > "$FAKE"
assert_status 1 'bash bin/bw-unlock' "empty session rejected"
assert_eq "sess-BBB" "$(cat "$CDIR/session")" "existing session untouched on empty"

# 4) fail-closed when cache dir unresolvable (no seam, no HOME)
printf 'x' > "$FAKE"
assert_status 1 'env -u HOME -u BITWARDEN_OPS_CACHE_DIR bash bin/bw-unlock' "no cache dir → fail closed"

finish
echo "PASS test_unlock"
