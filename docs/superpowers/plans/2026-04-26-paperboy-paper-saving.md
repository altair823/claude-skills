# Paperboy paper-saving rules — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic line/cm estimator (`paperboy-estimate`) and a paper-saving discipline section to the `paperboy-ops` skill so Claude stops wasting thermal paper on verbose prose, color metadata, and incompatible glyphs.

**Architecture:** One new bash helper (`paperboy-estimate`) that reads stdin text + flags, computes physical lines via EUC-KR byte width and size/feed_lines multipliers, and emits JSON + an exit code that lets shells branch. SKILL.md gets a new "Paper-saving rules" section (compaction checklist + gate flow) plus a refreshed worked example. No server changes; no changes to `paperboy-api` or `paperboy-spec`.

**Tech Stack:** bash, awk, `iconv` (glibc), `jq`, `wc`. No Python. No new runtime deps.

---

## File Structure

| Path (relative to repo root `/home/altair823/claude-skills`) | Role | Status |
|---|---|---|
| `paperboy-ops/bin/paperboy-estimate` | New: deterministic line/cm estimator. Reads stdin text + flags, writes JSON to stdout, exit 0 under threshold / 1 over / 2 on charset failure. | Create |
| `paperboy-ops/tests/paperboy-estimate.test.sh` | New: bash-only test driver. Each test invokes the helper with a fixture input and asserts JSON fields via `jq`. No external test framework. | Create |
| `paperboy-ops/SKILL.md` | New "Paper-saving rules" section; updated text-print worked example; new tool row in the top overview. | Modify |

The test driver is single-file because the helper is a single script. If it grows past ~200 lines, split per-feature into `tests/paperboy-estimate-*.sh`.

---

## Conventions

**Test driver pattern.** Every test in `tests/paperboy-estimate.test.sh` follows:

```bash
test_<name>() {
  local out
  out=$(printf '%s' "<input>" | bin/paperboy-estimate <flags>)
  local rc=$?
  assert_eq "$rc" <expected_rc>          "<name>: exit code"
  assert_eq "$(jq -r .<field> <<<"$out")" "<expected>" "<name>: <field>"
}
```

`assert_eq` and the test runner harness are added in Task 1.

**Working directory.** All commands run from `/home/altair823/claude-skills`.

**Helper invocation in tests.** Always `bin/paperboy-estimate` (relative). The test driver `cd`s into `paperboy-ops/` first.

**Commits.** One commit per task. Conventional commits, scoped `paperboy-ops`.

---

## Task 1: Test harness skeleton + first failing test

**Files:**
- Create: `paperboy-ops/tests/paperboy-estimate.test.sh`

- [ ] **Step 1: Write the test harness + first test (will fail because the helper does not exist yet)**

Create `paperboy-ops/tests/paperboy-estimate.test.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x paperboy-ops/tests/paperboy-estimate.test.sh
```

- [ ] **Step 2: Run the tests and confirm they fail because the helper does not exist**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: stderr line like `bin/paperboy-estimate: No such file or directory`, both assertions for `ascii_single_line` should fail (exit code is shell's "command not found" 127 not 0; physical_lines parse fails so jq returns null), runner ends with `0 passed, 2 failed` and overall non-zero exit.

- [ ] **Step 3: Commit**

```bash
git add paperboy-ops/tests/paperboy-estimate.test.sh
git commit -m "test(paperboy-ops): add test harness for paperboy-estimate"
```

---

## Task 2: Minimal `paperboy-estimate` — counts ASCII lines, emits JSON

**Files:**
- Create: `paperboy-ops/bin/paperboy-estimate`

- [ ] **Step 1: Create the minimal helper that makes Task 1's test pass**

Create `paperboy-ops/bin/paperboy-estimate`:

```bash
#!/usr/bin/env bash
# paperboy-estimate — deterministic line/cm estimator for paperboy text payloads.
# Reads text from stdin, writes a JSON object to stdout.
# Exit code: 0 if physical_lines <= threshold, 1 if over, 2 on charset check failure.
set -u

PRINTER_WIDTH_ASCII=42        # SRP-350III, font A, default size: 42 columns
CM_PER_LINE="0.3"             # conservative; actual ~0.21 cm/line

SIZE_W=1
SIZE_H=1
FEED_LINES=0
THRESHOLD="${PAPERBOY_LINE_THRESHOLD:-15}"
CHECK_CHARSET=0

usage() {
  cat <<'EOF' >&2
Usage: paperboy-estimate [--size W,H] [--feed-lines N] [--threshold N] [--check-charset] < text
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size)         IFS=',' read -r SIZE_W SIZE_H <<<"$2"; shift 2 ;;
    --feed-lines)   FEED_LINES="$2"; shift 2 ;;
    --threshold)    THRESHOLD="$2"; shift 2 ;;
    --check-charset) CHECK_CHARSET=1; shift ;;
    -h|--help)      usage ;;
    *)              usage ;;
  esac
done

input=$(cat)

# Minimal: count newline-separated lines. No wrap, no size, no feed.
# Subsequent tasks expand the math.
if [[ -z "$input" ]]; then
  physical=0
else
  physical=$(printf '%s' "$input" | awk 'END{print NR}')
fi

cm=$(awk -v p="$physical" -v c="$CM_PER_LINE" 'BEGIN{printf "%.2f", p*c}')
over=$(awk -v p="$physical" -v t="$THRESHOLD" 'BEGIN{print (p>t)?"true":"false"}')

jq -n \
  --argjson p "$physical" \
  --argjson cm "$cm" \
  --argjson over "$over" \
  --argjson t "$THRESHOLD" \
  '{physical_lines: $p, approx_cm: $cm, over_threshold: $over, threshold: $t}'

[[ "$over" == "true" ]] && exit 1 || exit 0
```

Make it executable:

```bash
chmod +x paperboy-ops/bin/paperboy-estimate
```

- [ ] **Step 2: Run the tests and confirm `ascii_single_line` passes**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: `1 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add paperboy-ops/bin/paperboy-estimate
git commit -m "feat(paperboy-ops): paperboy-estimate skeleton — ASCII line count + JSON"
```

---

## Task 3: Multi-line ASCII + empty-input cases

**Files:**
- Modify: `paperboy-ops/tests/paperboy-estimate.test.sh`

- [ ] **Step 1: Add failing tests for multi-line and empty input**

Append inside `# ---- tests ----` block in `paperboy-ops/tests/paperboy-estimate.test.sh`, before the runner block:

```bash
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
```

- [ ] **Step 2: Run the tests**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: `ascii_three_lines` and `empty_input` pass already (the awk-based counter handles them). `blank_line_counts_as_one` should also pass — `awk END{print NR}` on `a\n\nb` returns 3 (NR counts records including the empty middle one).

If any of those three actually fails, do not move on — fix Task 2's helper before Task 4.

- [ ] **Step 3: Commit**

```bash
git add paperboy-ops/tests/paperboy-estimate.test.sh
git commit -m "test(paperboy-ops): cover multi-line and empty inputs"
```

---

## Task 4: EUC-KR byte width + 42-column wrap

**Files:**
- Modify: `paperboy-ops/tests/paperboy-estimate.test.sh`
- Modify: `paperboy-ops/bin/paperboy-estimate`

- [ ] **Step 1: Add failing tests for Hangul width and ASCII wrap**

Append before the runner in `paperboy-ops/tests/paperboy-estimate.test.sh`:

```bash
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
```

- [ ] **Step 2: Run the tests and confirm the three new ones fail**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: previous 4 still pass; the 3 new ones fail because the helper currently counts logical lines, not wrapped lines.

- [ ] **Step 3: Replace the line-counting block in `bin/paperboy-estimate`**

Open `paperboy-ops/bin/paperboy-estimate`. Replace the block:

```bash
if [[ -z "$input" ]]; then
  physical=0
else
  physical=$(printf '%s' "$input" | awk 'END{print NR}')
fi
```

with:

```bash
if [[ -z "$input" ]]; then
  physical=0
else
  effective_cols=$(( PRINTER_WIDTH_ASCII / SIZE_W ))
  if (( effective_cols < 1 )); then effective_cols=1; fi

  physical=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    bytes=$(printf '%s' "$line" | iconv -f UTF-8 -t EUC-KR 2>/dev/null | wc -c)
    bytes=${bytes// /}
    if (( bytes == 0 )); then
      wrapped=1
    else
      wrapped=$(( (bytes + effective_cols - 1) / effective_cols ))
    fi
    physical=$(( physical + wrapped ))
  done <<<"$input"
fi
```

Notes:
- `iconv ... 2>/dev/null` swallows partial-conversion noise. The real charset check is opt-in via `--check-charset` (Task 7).
- Empty lines (`bytes == 0`) still count as 1 physical line — printer feeds for the `\n`.
- `SIZE_H` multiplier and `FEED_LINES` are not applied yet; that lands in Task 5.

- [ ] **Step 4: Run the tests and confirm all 7 pass**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: `7 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add paperboy-ops/bin/paperboy-estimate paperboy-ops/tests/paperboy-estimate.test.sh
git commit -m "feat(paperboy-ops): EUC-KR byte width + 42-col wrap"
```

---

## Task 5: `--size` height multiplier + `--feed-lines`

**Files:**
- Modify: `paperboy-ops/tests/paperboy-estimate.test.sh`
- Modify: `paperboy-ops/bin/paperboy-estimate`

- [ ] **Step 1: Add failing tests for height multiplier and feed lines**

Append before the runner:

```bash
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
```

- [ ] **Step 2: Run the tests and confirm the new ones fail (or the size_width one passes already)**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: `size_height_doubles_lines` and `feed_lines_added` fail (multiplier and feed addition not implemented yet). `size_width_halves_effective_cols` already passes from Task 4 (effective_cols logic landed there).

- [ ] **Step 3: Apply the multiplier and feed addition**

In `paperboy-ops/bin/paperboy-estimate`, replace the JSON block:

```bash
cm=$(awk -v p="$physical" -v c="$CM_PER_LINE" 'BEGIN{printf "%.2f", p*c}')
over=$(awk -v p="$physical" -v t="$THRESHOLD" 'BEGIN{print (p>t)?"true":"false"}')
```

with:

```bash
physical=$(( physical * SIZE_H + FEED_LINES ))
cm=$(awk -v p="$physical" -v c="$CM_PER_LINE" 'BEGIN{printf "%.2f", p*c}')
over=$(awk -v p="$physical" -v t="$THRESHOLD" 'BEGIN{print (p>t)?"true":"false"}')
```

(Single new line: the `physical=$(( physical * SIZE_H + FEED_LINES ))` arithmetic. Both ops happen post-wrap so they apply uniformly.)

- [ ] **Step 4: Run the tests**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: `10 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add paperboy-ops/bin/paperboy-estimate paperboy-ops/tests/paperboy-estimate.test.sh
git commit -m "feat(paperboy-ops): apply size height multiplier and feed_lines"
```

---

## Task 6: Threshold gate — exit code 1 + `over_threshold: true`

**Files:**
- Modify: `paperboy-ops/tests/paperboy-estimate.test.sh`

- [ ] **Step 1: Add tests for the threshold gate**

Append before the runner:

```bash
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
```

- [ ] **Step 2: Run the tests**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: all three pass. The threshold/exit logic is already in the helper from Task 2; these tests just lock in the behaviour. If any fails, fix the existing logic in `paperboy-estimate` (do not skip).

- [ ] **Step 3: Commit**

```bash
git add paperboy-ops/tests/paperboy-estimate.test.sh
git commit -m "test(paperboy-ops): pin threshold gate behaviour"
```

---

## Task 7: `--check-charset` — flag EUC-KR-incompatible glyphs

**Files:**
- Modify: `paperboy-ops/tests/paperboy-estimate.test.sh`
- Modify: `paperboy-ops/bin/paperboy-estimate`

- [ ] **Step 1: Add failing tests for charset check**

Append before the runner:

```bash
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
```

- [ ] **Step 2: Run the tests and confirm the new ones fail**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: ASCII and Hangul charset tests pass (the iconv path doesn't error today; flag is a no-op). Emoji test fails because the helper currently exits 0 regardless of charset.

- [ ] **Step 3: Wire `--check-charset` into the helper**

In `paperboy-ops/bin/paperboy-estimate`, immediately after `input=$(cat)`, add:

```bash
if (( CHECK_CHARSET == 1 )); then
  if ! conv_err=$(printf '%s' "$input" | iconv -f UTF-8 -t EUC-KR -o /dev/null 2>&1); then
    printf 'paperboy-estimate: EUC-KR charset check failed:\n%s\n' "$conv_err" >&2
    exit 2
  fi
fi
```

This runs `iconv` strictly (no `2>/dev/null` swallow), captures any error, and exits 2 with the message on stderr if conversion does not complete.

- [ ] **Step 4: Run the tests**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh
```

Expected: `16 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add paperboy-ops/bin/paperboy-estimate paperboy-ops/tests/paperboy-estimate.test.sh
git commit -m "feat(paperboy-ops): --check-charset flags EUC-KR-incompatible glyphs"
```

---

## Task 8: SKILL.md — new "Paper-saving rules" section

**Files:**
- Modify: `paperboy-ops/SKILL.md`

- [ ] **Step 1: Insert the new section between `## When to use` and `## Setup`**

In `paperboy-ops/SKILL.md`, locate the line `## Setup` (currently the section that begins with `` `~/.config/paperboy-ops/config` (mode 0600) ``). Insert the entire block below **immediately above** that `## Setup` heading, so the new section sits between `## When to use` and `## Setup`.

```markdown
## Paper-saving rules

The printer is a B&W thermal unit. Every line eats paper. Before sending any
**text-bearing payload** (a JSON body whose human-readable content lives in a
field like `text`, `body`, `content`, or `markdown`), Claude MUST walk the
checklist below, then call `paperboy-estimate` to verify length.

Raw payloads (`/print/raw` and any future endpoint that ships base64/binary)
are exempt — the caller is byte-aware by definition.

### Pre-print compaction checklist

| # | Rule | Why |
|---|---|---|
| 1 | Convert prose to tables or bullets | Prose pads with filler; tables strip it. |
| 2 | Hoist repeated label prefixes into a table header (one row per item) | Removes per-line redundancy. |
| 3 | Drop colour metadata (`행운의 색: 파랑`, etc.) | Printer is B&W; the value renders as text but conveys nothing. |
| 4 | Glyphs only from ASCII, Hangul, common Hanja, basic punctuation (`.,!?:;-/()`) and box drawing (`─│┌┐└┘├┤┬┴┼`) | Server encodes EUC-KR. Emoji, ★☆♥, exotic full-width symbols become `?` or fail the print. |
| 5 | Collapse consecutive blank lines to one. `feed_lines=0` unless cutter offset demands 1–3 | Each blank line = paper. |
| 6 | `size=[1,1]` is the default. Only `[2,2]+` when the user explicitly asks for "크게/제목/강조" | Doubling each axis quadruples paper area. |
| 7 | `bold=false`, `align=0` unless the user requests otherwise | Conservative defaults; nothing is "decorative by default". |

Multiple-item requests are NOT auto-merged. If the user asks for three
fortunes, print three jobs unless the user themselves asks for a single strip
with dividers — paper separation can carry intent.

### Length gate

After composing the payload, run the helper on the text-bearing field:

```sh
echo "$TEXT" | paperboy-estimate --size "$W,$H" --feed-lines "$N"
```

Output:

```json
{"physical_lines": 18, "approx_cm": 5.4, "over_threshold": true, "threshold": 15}
```

Exit code: `0` if `physical_lines <= threshold` (default 15), `1` if over,
`2` if `--check-charset` was passed and the text contains EUC-KR-incompatible
glyphs.

| `over_threshold` | Action |
|---|---|
| `false` | Print immediately. |
| `true` | Show the user a preview (first ~10 lines + `... (총 N줄, ~M cm)`) and ask for confirmation. Print only after explicit OK. |

The gate is a confirmation, not a hard block. Intentionally long content
proceeds with one user OK. Override the threshold via `--threshold N` or
`PAPERBOY_LINE_THRESHOLD`.

### When to use `--check-charset`

Only when introducing unusual glyphs (decorative marks, Unicode symbols,
uncommon Hanja). It runs strict `iconv -f UTF-8 -t EUC-KR`, prints offending
characters to stderr, and exits 2. ASCII + Hangul + common punctuation never
needs it.
```

- [ ] **Step 2: Add a row for `paperboy-estimate` to the tool list at the top of the file**

Locate the lines near the top of `paperboy-ops/SKILL.md` (currently lines 8–11):

```markdown
Two thin tools:

- `paperboy-spec` — inspect the live OpenAPI document (paths, operations, schemas).
- `paperboy-api` — generic authenticated HTTP client (`paperboy-api METHOD PATH …`).
```

Replace with:

```markdown
Three thin tools:

- `paperboy-spec` — inspect the live OpenAPI document (paths, operations, schemas).
- `paperboy-api` — generic authenticated HTTP client (`paperboy-api METHOD PATH …`).
- `paperboy-estimate` — deterministic line/cm estimator for text payloads (paper-saving gate).
```

- [ ] **Step 3: Sanity-check the file renders as expected**

Read the updated file and verify both edits landed in the right place:

```bash
sed -n '1,20p;/## Paper-saving rules/,/^## Setup/p' paperboy-ops/SKILL.md | head -120
```

Expected: tool list now lists three tools; `## Paper-saving rules` appears between `## When to use` and `## Setup`.

- [ ] **Step 4: Commit**

```bash
git add paperboy-ops/SKILL.md
git commit -m "docs(paperboy-ops): add paper-saving rules section"
```

---

## Task 9: SKILL.md — refresh the text-print worked example

**Files:**
- Modify: `paperboy-ops/SKILL.md`

- [ ] **Step 1: Replace the text-print worked example with one that exercises the gate**

In `paperboy-ops/SKILL.md`, find the section that begins with `## Worked example — text print + verify` and contains the `JOB=$(paperboy-api POST /print/text ...)` block (currently roughly lines 102–127). Replace the entire fenced code block under that heading with:

````markdown
```sh
# 1. Confirm the route + body shape from the live server.
paperboy-spec op POST /print/text
paperboy-spec schema TextPayload     # required: text; optional: align/bold/size/cut/feed_lines

# 2. Sanity-check the printer.
paperboy-api GET /readyz             # {ok:true, usb_open:true, online:true, ...}

# 3. Compose payload (compaction checklist 1–7 already applied).
TEXT='[영수증]
커피      4500
샌드위치  6000
─────────────
합계     10500'

# 4. Estimate length. Exit 0 = under threshold → print. Exit 1 = ask user first.
if echo "$TEXT" | paperboy-estimate --size 1,1 --feed-lines 0; then
  :  # under threshold; proceed
else
  echo "Over threshold — show preview, get user confirmation, then proceed."
fi

# 5. Enqueue (auto Idempotency-Key so retries don't double-print).
JOB=$(paperboy-api POST /print/text --idem-auto \
  --json "$(jq -n --arg t "$TEXT" '{text:$t,align:0,size:[1,1],cut:true,feed_lines:0}')" \
  | jq -r .job_id)

# 6. Poll until terminal.
while :; do
  s=$(paperboy-api GET "/jobs/$JOB" --raw | jq -r .status)
  case "$s" in
    succeeded|failed_*|cancelled) echo "$s"; break ;;
  esac
  sleep 1
done
```
````

Notes for the engineer doing the edit:
- Keep the surrounding `UTF-8 in, EUC-KR encoding handled by the server — just send Korean text as-is.` line that follows the code block.
- Do NOT touch the `## Worked example — raw ESC/POS bytes` section that follows it (raw is exempt from the gate).

- [ ] **Step 2: Sanity-check the diff**

```bash
git diff paperboy-ops/SKILL.md
```

Expected: only the text-print worked-example code fence changed. The raw ESC/POS example, idempotency rules, common operations table, and common mistakes table are all untouched.

- [ ] **Step 3: Commit**

```bash
git add paperboy-ops/SKILL.md
git commit -m "docs(paperboy-ops): rework text-print example around paperboy-estimate"
```

---

## Task 10: End-to-end smoke (manual, single step)

**Files:** none modified.

- [ ] **Step 1: Run the full test suite + a manual estimate against a realistic payload**

```bash
bash paperboy-ops/tests/paperboy-estimate.test.sh

# Manual realistic spot-check (no network, no print):
printf '[영수증]\n커피      4500\n샌드위치  6000\n─────────────\n합계     10500\n' \
  | paperboy-ops/bin/paperboy-estimate --size 1,1 --feed-lines 0
```

Expected:
- Test suite: `16 passed, 0 failed`.
- Manual run: JSON with `physical_lines: 5`, `over_threshold: false`, exit code 0.

If either fails, do not declare done — return to the failing task.

- [ ] **Step 2: Final commit only if anything was tweaked**

If Step 1 surfaced a small fix, commit it as `fix(paperboy-ops): ...` and re-run Step 1. Otherwise no commit.

---

## Self-Review (done before handing off)

**Spec coverage check (`docs/superpowers/specs/2026-04-26-paperboy-paper-saving-design.md`):**

| Spec section | Implemented in |
|---|---|
| §1 Scope & trigger (content-based) | Task 8 (SKILL.md "Paper-saving rules" section explains the `text`/`body`/`content`/`markdown` detection rule and raw exemption) |
| §2 Compaction checklist (1–7) | Task 8 (table copied verbatim into SKILL.md) |
| §3 `paperboy-estimate` interface, computation, output, exit code, threshold, `--check-charset` | Tasks 2 (skeleton + JSON + threshold), 4 (EUC-KR width + wrap), 5 (size H + feed_lines), 6 (threshold gate tests), 7 (`--check-charset`) |
| §4 Gate flow | Task 8 (length-gate subsection in SKILL.md) + Task 9 (worked example) |
| §5 SKILL.md changes (new section, updated example, tool overview row) | Task 8 (section + tool row), Task 9 (worked example) |
| §6 Files touched | Plan creates exactly the two files in the spec table; no other paths modified |

**Placeholder scan:** No `TBD`, `TODO`, "implement later", "appropriate error handling", or other vague directives. Every code step shows the actual code or command.

**Type / name consistency:** JSON field names (`physical_lines`, `approx_cm`, `over_threshold`, `threshold`) match between the spec, the helper implementation, the tests, and the SKILL.md docs. Flag names (`--size`, `--feed-lines`, `--threshold`, `--check-charset`) are identical everywhere. Env var `PAPERBOY_LINE_THRESHOLD` is consistent.

No gaps found.
