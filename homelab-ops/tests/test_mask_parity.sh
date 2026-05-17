#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh

# The forensic masking rule set is intentionally duplicated in two places:
#   bin/_lib.sh   — the mask() function's `sed -E` block
#   bin/guard     — the inline `sed -uE` action-output pipeline
# They MUST stay byte-identical or one redaction path silently weakens and a
# secret can reach logs/. This test extracts the `-e '...'` masking rule
# strings from each site and asserts the ordered lists are equal — converting
# silent drift into a loud failure.

# Every forensic masking rule emits a MASKED marker
# (***MASKED***, ***MASKED-PRIVATE-KEY***, ***MASKED-BLOB***). Filtering to
# MASKED lines first excludes unrelated `-e '...'` occurrences (e.g. the
# `jq -e '(.tags? ...)'` in guard) so we compare only the masking pipeline.
# Leading whitespace differs by site (4 vs 8 spaces) and is irrelevant to rule
# semantics, so we key only on the `-e '...'` payload.
extract_rules() { # <file>
  grep 'MASKED' "$1" | grep -oE "\-e '[^']*'" | sed -E "s/^-e '//; s/'\$//"
}

lib_rules="$(extract_rules bin/_lib.sh)"
guard_rules="$(extract_rules bin/guard)"

assert_eq "$lib_rules" "$guard_rules" "mask() and guard inline sed rule lists are byte-identical"

# Sanity: extraction actually found the rule set (guard against a regex that
# silently matches nothing, which would make the equality trivially true).
n="$(printf '%s\n' "$lib_rules" | grep -c 'MASKED' || true)"
[[ "$n" -ge 5 ]] && echo "  ok: extracted $n masking rules (non-trivial)" \
  || { echo "  FAIL: expected >=5 masking rules, got $n"; exit 1; }

# HL_SSH_PASS / SSHPASS 값이 마스킹되는지(누출 방지).
src="$(printf 'x HL_SSH_PASS=p@ssw0rd y\nSSHPASS=topsecret z\n')"
masked="$(printf '%s' "$src" | (source bin/_lib.sh; mask))"
assert_not_contains "$masked" "p@ssw0rd" "HL_SSH_PASS value masked"
assert_not_contains "$masked" "topsecret" "SSHPASS value masked"

finish; echo "PASS test_mask_parity"
