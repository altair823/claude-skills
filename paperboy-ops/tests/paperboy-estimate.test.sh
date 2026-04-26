#!/usr/bin/env bash
# Test driver for paperboy-estimate. No external framework — bash + jq.
# Run from repo root: bash paperboy-ops/tests/paperboy-estimate.test.sh
set -u

cd "$(dirname "$0")/.."  # paperboy-ops/

PASS=0
FAIL=0

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n    expected: %q\n    actual:   %q\n' "$label" "$expected" "$actual"
  fi
}

# ---- tests ----

test_ascii_single_line() {
  local out rc
  out=$(printf 'hello' | bin/paperboy-estimate)
  rc=$?
  assert_eq "$rc" "0" "ascii_single_line: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "1" "ascii_single_line: physical_lines"
}

# ---- runner ----

for fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  printf '\n== %s ==\n' "$fn"
  "$fn"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
