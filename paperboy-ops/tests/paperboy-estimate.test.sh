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

test_ascii_three_lines() {
  local out rc
  out=$(printf 'a\nb\nc' | bin/paperboy-estimate)
  rc=$?
  assert_eq "$rc" "0" "ascii_three_lines: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "3" "ascii_three_lines: physical_lines"
}

test_empty_input() {
  local out rc
  out=$(printf '' | bin/paperboy-estimate)
  rc=$?
  assert_eq "$rc" "0" "empty_input: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "0" "empty_input: physical_lines"
}

test_blank_line_counts_as_one() {
  local out rc
  out=$(printf 'a\n\nb' | bin/paperboy-estimate)
  rc=$?
  assert_eq "$rc" "0" "blank_line_counts_as_one: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "3" "blank_line_counts_as_one: physical_lines"
}

test_hangul_one_line_no_wrap() {
  # 5 Hangul chars = 10 EUC-KR bytes, fits in 42-col line → 1 physical line
  local out rc
  out=$(printf '안녕하세요' | bin/paperboy-estimate)
  rc=$?
  assert_eq "$rc" "0" "hangul_one_line_no_wrap: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "1" "hangul_one_line_no_wrap: physical_lines"
}

test_ascii_wraps_past_42_cols() {
  # 50 'x' chars → ceil(50/42) = 2 physical lines
  local out rc input
  input=$(printf 'x%.0s' {1..50})
  out=$(printf '%s' "$input" | bin/paperboy-estimate)
  rc=$?
  assert_eq "$rc" "0" "ascii_wraps_past_42_cols: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "2" "ascii_wraps_past_42_cols: physical_lines"
}

test_hangul_wraps_past_21_chars() {
  # 22 Hangul chars = 44 EUC-KR bytes → ceil(44/42) = 2 physical lines
  local out rc input
  input=$(printf '가%.0s' {1..22})
  out=$(printf '%s' "$input" | bin/paperboy-estimate)
  rc=$?
  assert_eq "$rc" "0" "hangul_wraps_past_21_chars: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "2" "hangul_wraps_past_21_chars: physical_lines"
}

test_size_height_doubles_lines() {
  # 3 ASCII lines × H=2 = 6 physical lines
  local out rc
  out=$(printf 'a\nb\nc' | bin/paperboy-estimate --size 1,2)
  rc=$?
  assert_eq "$rc" "0" "size_height_doubles_lines: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "6" "size_height_doubles_lines: physical_lines"
}

test_size_width_halves_effective_cols() {
  # 30 'x' chars at W=2 → effective_cols=21 → ceil(30/21)=2 lines, ×H=1 = 2
  local out rc input
  input=$(printf 'x%.0s' {1..30})
  out=$(printf '%s' "$input" | bin/paperboy-estimate --size 2,1)
  rc=$?
  assert_eq "$rc" "0" "size_width_halves_effective_cols: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "2" "size_width_halves_effective_cols: physical_lines"
}

test_feed_lines_added() {
  # 1 line + feed_lines=4 = 5 physical
  local out rc
  out=$(printf 'a' | bin/paperboy-estimate --feed-lines 4)
  rc=$?
  assert_eq "$rc" "0" "feed_lines_added: exit code"
  assert_eq "$(jq -r .physical_lines <<<"$out")" "5" "feed_lines_added: physical_lines"
}

test_under_threshold_exit_zero() {
  local out rc
  out=$(printf 'a\nb\nc' | bin/paperboy-estimate --threshold 5)
  rc=$?
  assert_eq "$rc" "0" "under_threshold_exit_zero: exit code"
  assert_eq "$(jq -r .over_threshold <<<"$out")" "false" "under_threshold_exit_zero: over_threshold"
}

test_over_threshold_exit_one() {
  local out rc lines
  lines=$(printf 'x\n%.0s' {1..20})  # 20 lines
  out=$(printf '%s' "$lines" | bin/paperboy-estimate --threshold 15)
  rc=$?
  assert_eq "$rc" "1" "over_threshold_exit_one: exit code"
  assert_eq "$(jq -r .over_threshold <<<"$out")" "true" "over_threshold_exit_one: over_threshold"
  assert_eq "$(jq -r .threshold <<<"$out")" "15" "over_threshold_exit_one: threshold"
}

test_env_threshold_default() {
  local out rc lines
  lines=$(printf 'x\n%.0s' {1..20})
  out=$(PAPERBOY_LINE_THRESHOLD=25 printf '%s' "$lines" | PAPERBOY_LINE_THRESHOLD=25 bin/paperboy-estimate)
  rc=$?
  assert_eq "$rc" "0" "env_threshold_default: exit code (env override raises ceiling)"
  assert_eq "$(jq -r .threshold <<<"$out")" "25" "env_threshold_default: threshold from env"
}

test_charset_check_passes_ascii() {
  local out rc
  out=$(printf 'hello' | bin/paperboy-estimate --check-charset)
  rc=$?
  assert_eq "$rc" "0" "charset_check_passes_ascii: exit code"
}

test_charset_check_passes_hangul() {
  local out rc
  out=$(printf '안녕' | bin/paperboy-estimate --check-charset)
  rc=$?
  assert_eq "$rc" "0" "charset_check_passes_hangul: exit code"
}

test_charset_check_fails_emoji() {
  local out rc err
  err=$(mktemp)
  out=$(printf '🎨 hello' | bin/paperboy-estimate --check-charset 2>"$err")
  rc=$?
  local err_content
  err_content=$(cat "$err")
  rm -f "$err"
  assert_eq "$rc" "2" "charset_check_fails_emoji: exit code"
  if [[ -n "$err_content" ]]; then
    assert_eq "ok" "ok" "charset_check_fails_emoji: stderr non-empty"
  else
    assert_eq "non-empty" "empty" "charset_check_fails_emoji: stderr non-empty"
  fi
}

# ---- runner ----

for fn in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  printf '\n== %s ==\n' "$fn"
  "$fn"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
