#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

CDIR="$(mktemp -d)/c"
export BITWARDEN_OPS_CACHE_DIR="$CDIR"
export BW_STUB_DB="$(mktemp)"
trap 'rm -rf "$(dirname "$CDIR")" "$BW_STUB_DB" "$BW_STUB_DB.locked"' EXIT

# 1) removes an existing session file and reports
mkdir -p "$CDIR"; chmod 700 "$CDIR"
printf 'sess' > "$CDIR/session"; chmod 600 "$CDIR/session"
out="$(bash bin/bw-lock)"
assert_contains "$out" "세션 잠금" "announces lock"
[[ ! -e "$CDIR/session" ]] && echo "  ok: session file removed" \
  || { echo "  FAIL: session file remained"; exit 1; }

# 2) idempotent: no file present → still succeeds
assert_status 0 'bash bin/bw-lock' "idempotent when no session file"

# 3) bw lock was invoked (stub drops a marker file — no stdout scraping)
rm -f "$BW_STUB_DB.locked"
bash bin/bw-lock >/dev/null
[[ -f "$BW_STUB_DB.locked" ]] && echo "  ok: bw lock invoked" \
  || { echo "  FAIL: bw lock not invoked"; exit 1; }

finish
echo "PASS test_lock"
