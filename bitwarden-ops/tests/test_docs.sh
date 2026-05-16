#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

S=SKILL.md
grep -q 'bw-unlock' "$S"            || { echo "FAIL: SKILL.md missing bw-unlock"; exit 1; }
grep -q 'bw-lock' "$S"              || { echo "FAIL: SKILL.md missing bw-lock"; exit 1; }
grep -q 'cache/bitwarden-ops' "$S"  || { echo "FAIL: SKILL.md missing cache path"; exit 1; }
grep -qiE 'env.*win|BW_SESSION.*우선|precedence' "$S" || { echo "FAIL: SKILL.md missing env-wins note"; exit 1; }
! grep -nE 'TODO|TBD' "$S"          || { echo "FAIL: SKILL.md has TODO/TBD"; exit 1; }
for t in bw-get bw-exec bw-ls bw-put bw-status bw-unlock bw-lock; do
  [[ -x "bin/$t" ]] || { echo "FAIL: bin/$t missing or not executable"; exit 1; }
done
echo "PASS test_docs"
