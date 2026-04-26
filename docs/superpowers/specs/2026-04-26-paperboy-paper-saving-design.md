# Paperboy paper-saving rules — design

Add paper-conservation discipline to the `paperboy-ops` skill so Claude does not
waste thermal paper on verbose prose, gratuitous formatting, or color metadata
the BIXOLON SRP-350III cannot render.

## Problem

The current `paperboy-ops` skill teaches Claude how to call the paperboy HTTP
API but says nothing about content shape or length. Claude defaults to verbose,
prose-heavy output that prints 2–3× more paper than necessary. A recent
3-fortune print used three jobs (three cuts → ~6 cm of cutter overhead),
multi-line prose per fortune, and color metadata ("행운의 색: 파랑") that the
B&W printer cannot render anyway.

## Goals

- Force Claude to consider compression before every text print.
- Stop emitting content (color labels, fancy Unicode) the printer cannot render
  or the EUC-KR encoding will mangle.
- Provide a deterministic line/cm estimate so the gate threshold is enforced
  by a tool, not by Claude's intuition.
- Survive paperboy API drift (new endpoints, renamed routes).

## Non-goals

- No changes to the paperboy server.
- No new HTTP wrapper that hides the OpenAPI-discovery flow. The skill keeps
  its `discover → schema → call` shape.
- Multiple-job vs single-job-with-divider is **not** auto-merged. Paper
  separation can carry meaning; the skill respects user intent.

## Design

### 1. Scope & trigger (content-based)

Rule applies when the JSON payload Claude is about to send contains a
plaintext string field intended for human reading: `text`, `body`, `content`,
`markdown`, or any OpenAPI string field that is clearly user-facing.

Rule does **not** apply when the payload is a base64 / binary blob
(`data_b64` and similar). Raw callers are byte-aware by definition.

This detection is endpoint-agnostic. If paperboy adds `/print/template` or
renames `/print/text`, the rule still triggers based on payload shape.

### 2. Pre-print compaction checklist (mandatory)

Before serializing the payload, Claude must walk this checklist:

| # | Item | Action |
|---|---|---|
| 1 | Prose → table/list | No padding sentences. Convert "오늘은 ~한다" prose to tables or bullets. |
| 2 | Trim duplicate labels | Repeated prefixes per item (e.g. "행운의 ~:" on every line) → table header once. |
| 3 | Drop color metadata | Printer is B&W. Color labels ("행운의 색: 파랑") waste paper — omit. |
| 4 | Compatible glyphs only | Server encodes EUC-KR. Safe: ASCII, Hangul, common Hanja, basic punctuation (`.,!?:;-/()`), box drawing (`─│┌┐└┘├┤┬┴┼`). Avoid: emoji, exotic Unicode symbols (★☆♥), full-width symbols not in EUC-KR. When in doubt, ASCII. |
| 5 | Minimize blank lines | Collapse consecutive blanks to one. `feed_lines=0` unless cutter offset requires 1–3. |
| 6 | Fix `size=[1,1]` | Hard default. Only `[2,2]+` when user explicitly says "크게 / 제목 / 강조". |
| 7 | Conservative `bold` / `align` | `bold=false`, `align=0` unless user requests otherwise. |

Multiple-item requests are **not** auto-merged. If the user asks for "3
fortunes," Claude prints 3 jobs unless the user themselves asks for a single
strip with dividers.

### 3. `paperboy-estimate` — deterministic line/cm tool

New helper at `~/claude-skills/paperboy-ops/bin/paperboy-estimate`.

Claude must call it on the post-compaction text before invoking
`paperboy-api POST /print/text` (or any other text-payload print endpoint).

**Interface:**

```
paperboy-estimate [--size W,H] [--feed-lines N] [--threshold N] [--check-charset] < text
```

**Computation:**

- Split input on `\n`.
- For each line: estimate column width by EUC-KR byte count.
  Hangul = 2 bytes, ASCII = 1 byte. Default printer width = 42 ASCII columns
  (= 21 Hangul). Effective width = `42 / W`. Wrapped lines per logical line
  = `ceil(byte_width / effective_width)`.
- Total physical lines = `sum(wrapped) * H + feed_lines`.
- Approx cm = `physical_lines * 0.3` (conservative; SRP-350III is closer to
  0.21 cm/line, so 0.3 over-estimates and keeps the gate slightly cautious).

**Output (stdout, JSON):**

```json
{"physical_lines": 18, "approx_cm": 5.4, "over_threshold": true, "threshold": 15}
```

**Exit code:** `0` if under threshold, `1` if over. Lets shell pipelines branch.

**Threshold:** default 15 lines. Override with `--threshold N` or env
`PAPERBOY_LINE_THRESHOLD`.

**`--check-charset`:** attempt EUC-KR encoding (via `iconv -f UTF-8 -t EUC-KR`).
On failure, list the offending characters to stderr and exit 2.

### 4. Gate flow

```
1. Compose payload, walk checklist 1–7.
2. Extract the text-bearing field from the payload (whichever of `text` / `body`
   / `content` / `markdown` applies for the chosen endpoint), pipe to
   `paperboy-estimate --size W,H --feed-lines N`.
3. over_threshold == false → POST the print endpoint immediately
4. over_threshold == true →
     - Show preview to user: first 10 lines of text + "... (총 N줄, ~M cm)"
     - Ask "이대로 인쇄?"
     - YES → print
     - NO / 수정 → re-run checklist, re-estimate
5. --check-charset failure → report offending chars, propose ASCII fallback
```

The gate is a **confirmation**, not a hard block. Intentionally long content
proceeds with one user OK.

### 5. SKILL.md changes

- **New section "Paper-saving rules"** inserted between `## When to use` and
  `## Setup`. Contains the compaction checklist, gate-flow pseudocode, and a
  pointer to `paperboy-estimate`.
- **Update "Worked example — text print + verify"** to call
  `paperboy-estimate` between the readyz check and the enqueue step. Replace
  the `안녕 paperboy` example with a realistic short receipt (no color
  metadata).
- **Add `paperboy-estimate` row** to the existing tool overview at the top of
  the file.
- **`/print/raw` example unchanged** — raw payloads bypass the rule.

### 6. Files touched

| File | Change |
|---|---|
| `~/claude-skills/paperboy-ops/SKILL.md` | New section + updated worked example. |
| `~/claude-skills/paperboy-ops/bin/paperboy-estimate` | New script (bash + iconv + awk; no Python dependency). |

No changes to `paperboy-api`, `paperboy-spec`, or `_common.sh`.

## Trade-offs

- **Why content-based, not endpoint-based?** Endpoint names drift; payload
  shape is the actual signal. New `/print/markdown` would still get gated.
- **Why a separate `paperboy-estimate` instead of inlining the math in
  `paperboy-api`?** Keeps `paperboy-api` a generic HTTP client. Estimation is
  a pre-flight concern, not a transport concern.
- **Why no auto-merge for multi-item prints?** Paper separation can be
  intentional (one fortune per person, one ticket per attendee). Cheaper
  failure mode than silently merging.
- **Why 15 lines, not 10 or 20?** 10 fires on legitimate short receipts (8–12
  lines incl. header/footer) — alert fatigue. 20 fires only after the waste
  is already substantial. 15 catches Claude's prose padding without nagging
  on real receipts.

## Risks

- Claude may skip the `paperboy-estimate` call. Mitigation: SKILL.md states
  the call is mandatory before any text-payload print, and the worked example
  shows it.
- EUC-KR check may flag legitimate uncommon Hanja. Mitigation: `--check-charset`
  is opt-in, not on by default; Claude only runs it when introducing unusual
  glyphs.
- 0.3 cm/line over-estimate makes the gate slightly cautious. Acceptable; a
  false positive costs one extra confirmation, a false negative costs paper.
