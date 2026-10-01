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
grep -q 'bw-sync' "$S"              || { echo "FAIL: SKILL.md missing bw-sync"; exit 1; }
grep -qF '!`${CLAUDE_SKILL_DIR}/bin/bw-status || true`' "$S" || { echo "FAIL: SKILL.md missing status injection"; exit 1; }
grep -qxF 'allowed-tools: Bash(${CLAUDE_SKILL_DIR}/bin/bw-status)' "$S" || { echo "FAIL: SKILL.md missing allowed-tools"; exit 1; }
! grep -nE '\$BW/bin' "$S"          || { echo "FAIL: SKILL.md still uses \$BW/bin"; exit 1; }
for t in bw-get bw-exec bw-ls bw-put bw-status bw-unlock bw-lock bw-sync; do
  [[ -x "bin/$t" ]] || { echo "FAIL: bin/$t missing or not executable"; exit 1; }
done
echo "PASS test_docs"
