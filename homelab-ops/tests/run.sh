#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/tests/stubs:$PATH"
export HOMELAB_SESSION_ID="test-sess"
# Suite reads the fixed fixture, never the operator's live inventory/.
export HOMELAB_INVENTORY_DIR="$PWD/tests/fixtures"
rc=0
for t in tests/test_*.sh; do
  echo "== $t"
  bash "$t" || rc=1
done
[[ $rc -eq 0 ]] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $rc
