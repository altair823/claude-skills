#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

for d in bin tests/stubs; do
  [[ -d "$d" ]] || { echo "FAIL: missing dir $d"; exit 1; }
done
[[ -f SKILL.md ]] || { echo "FAIL: missing SKILL.md"; exit 1; }
# Frontmatter: name + description present.
head -1 SKILL.md | grep -qx -- '---' || { echo "FAIL: SKILL.md no frontmatter"; exit 1; }
grep -q '^name: bitwarden-ops$' SKILL.md || { echo "FAIL: name missing"; exit 1; }
grep -q '^description: ' SKILL.md || { echo "FAIL: description missing"; exit 1; }
# Hard invariant must be stated in the skill body.
grep -qi 'BW_SESSION' SKILL.md || { echo "FAIL: session model not documented"; exit 1; }
echo "PASS test_skeleton"
