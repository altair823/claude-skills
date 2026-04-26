# gitea-ops PR Review Step Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Claude-driven PR review step between `gitea-pr` (create) and `gitea-pr-merge` (merge): two new scripts (`gitea-pr-diff`, `gitea-pr-review`) plus a review gate in `gitea-pr-merge`.

**Architecture:** Two new shell scripts under `gitea-ops/bin/` follow the existing dumb-pipe pattern (curl + jq, no deps). A separate reviewer token (`~/.config/gitea-ops/reviewer-token` or `GITEA_REVIEWER_TOKEN`) is loaded only by `gitea-pr-review` so the PR author and reviewer identities stay distinct. `gitea-pr-merge` gains a `--force` flag and refuses to merge unless `GET /pulls/<n>/reviews` returns at least one non-dismissed `APPROVED` review.

**Tech Stack:** POSIX `/bin/sh`, `curl`, `jq`, `git`. Test harness: existing `tests/lib.sh` (curl stub + fixtures + assertion helpers).

**Reference spec:** `docs/superpowers/specs/2026-04-26-gitea-pr-review-design.md`

---

## File Structure

| Path | Action | Purpose |
|------|--------|---------|
| `gitea-ops/bin/_common.sh` | Modify | Add `load_reviewer_token()`, mirroring `load_token()`. |
| `gitea-ops/bin/gitea-pr-diff` | Create | Print PR meta + unified diff for Claude analysis. Flags: `--raw`, `--json`. |
| `gitea-ops/bin/gitea-pr-review` | Create | POST a review to Gitea using reviewer token. Summary + optional inline comments. |
| `gitea-ops/bin/gitea-pr-merge` | Modify | Add review gate before merge call; add `--force` flag to bypass. |
| `gitea-ops/SKILL.md` | Modify | Document new scripts, setup of reviewer-token, updated workflow. |
| `gitea-ops/tests/lib.sh` | Modify | Sandbox `GITEA_REVIEWER_TOKEN_FILE` so real config is untouched. |
| `gitea-ops/tests/test_common_helpers.sh` | Modify | Add `load_reviewer_token` unit test. |
| `gitea-ops/tests/test_gitea_pr_diff.sh` | Create | Cover meta/json/raw/404 paths. |
| `gitea-ops/tests/test_gitea_pr_review.sh` | Create | Cover token gating, body+inline POST shape, stdin, errors. |
| `gitea-ops/tests/test_gitea_pr_merge.sh` | Modify | Extend with review-gate cases (approved/empty/dismissed/--force). |

Each script stays small (one responsibility) and sources `_common.sh`. Tests run from `tests/run.sh` if present; otherwise each `test_*.sh` is executable directly.

---

## Task 1: Reviewer-token loader and test sandbox

**Files:**
- Modify: `gitea-ops/bin/_common.sh`
- Modify: `gitea-ops/tests/lib.sh`
- Modify: `gitea-ops/tests/test_common_helpers.sh`

- [ ] **Step 1: Write failing test for `load_reviewer_token`**

Append to `gitea-ops/tests/test_common_helpers.sh` (after the existing test, before `echo OK`):

```sh
# --- load_reviewer_token: env wins over file ---
setup
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/rev-token"
printf 'file-token\n' >"$GITEA_REVIEWER_TOKEN_FILE"
GITEA_REVIEWER_TOKEN="env-token" tok="$(load_reviewer_token)"
assert_eq "$tok" "env-token" "env wins over file"
unset GITEA_REVIEWER_TOKEN
teardown

# --- load_reviewer_token: falls back to file ---
setup
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/rev-token"
printf 'file-token\n' >"$GITEA_REVIEWER_TOKEN_FILE"
unset GITEA_REVIEWER_TOKEN || true
tok="$(load_reviewer_token)"
assert_contains "$tok" "file-token" "file fallback"
teardown

# --- load_reviewer_token: missing both → die ---
setup
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/does-not-exist"
unset GITEA_REVIEWER_TOKEN || true
if (load_reviewer_token) 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "reviewer token" "error mentions reviewer token"
teardown
```

- [ ] **Step 2: Run test, verify failure**

Run: `sh gitea-ops/tests/test_common_helpers.sh`
Expected: FAIL — `load_reviewer_token: command not found` (or unbound function).

- [ ] **Step 3: Add `load_reviewer_token` to `_common.sh`**

In `gitea-ops/bin/_common.sh`, immediately after the `load_token()` function, add:

```sh
GITEA_REVIEWER_TOKEN_FILE="${GITEA_REVIEWER_TOKEN_FILE:-$HOME/.config/gitea-ops/reviewer-token}"

load_reviewer_token() {
    if [ -n "${GITEA_REVIEWER_TOKEN:-}" ]; then
        printf '%s' "$GITEA_REVIEWER_TOKEN"; return 0
    fi
    if [ -r "$GITEA_REVIEWER_TOKEN_FILE" ] && [ -s "$GITEA_REVIEWER_TOKEN_FILE" ]; then
        cat "$GITEA_REVIEWER_TOKEN_FILE"; return 0
    fi
    die "reviewer token required (set GITEA_REVIEWER_TOKEN or write $GITEA_REVIEWER_TOKEN_FILE)"
}
```

The `-s` check (non-empty file) means an empty placeholder file falls through to `die`, matching the spec.

Also append `GITEA_REVIEWER_TOKEN_FILE` to the `export` line at the bottom of `resolve_remote()` is **not** needed — the var is read on demand by `load_reviewer_token` itself.

- [ ] **Step 4: Add reviewer-token sandbox to `tests/lib.sh`**

In `gitea-ops/tests/lib.sh`, inside `setup()`, immediately after the existing `GITEA_TOKEN_FILE` lines, add:

```sh
    # Reviewer token sandbox so real ~/.config/gitea-ops/reviewer-token is untouched.
    export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/reviewer-token"
    printf 'fake-reviewer-token\n' >"$GITEA_REVIEWER_TOKEN_FILE"
```

This means by default tests have a working reviewer token; tests that exercise the missing-token path override `GITEA_REVIEWER_TOKEN_FILE` themselves (as the unit test above does).

- [ ] **Step 5: Run test, verify pass**

Run: `sh gitea-ops/tests/test_common_helpers.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 6: Commit**

```sh
git add gitea-ops/bin/_common.sh gitea-ops/tests/lib.sh gitea-ops/tests/test_common_helpers.sh
git commit -m "feat(gitea-ops): add load_reviewer_token helper + sandbox"
```

---

## Task 2: `gitea-pr-diff` — argument parsing and `--help`

**Files:**
- Create: `gitea-ops/bin/gitea-pr-diff`
- Create: `gitea-ops/tests/test_gitea_pr_diff.sh`

- [ ] **Step 1: Write failing test for `--help` and missing-PR**

Create `gitea-ops/tests/test_gitea_pr_diff.sh`:

```sh
#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help prints usage, exits 0 ---
setup
out="$("$BIN/gitea-pr-diff" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "PR#" "--help mentions PR# arg"
teardown

# --- missing PR# fails with clear error ---
setup
if "$BIN/gitea-pr-diff" 2>"$TEST_TMP/err"; then
    echo FAIL: expected exit non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
teardown

# --- unknown flag fails ---
setup
if "$BIN/gitea-pr-diff" 1 --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on unknown flag >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "unknown" "error mentions unknown"
teardown

# --- --raw and --json mutually exclusive ---
setup
if "$BIN/gitea-pr-diff" 1 --raw --json 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on conflicting flags >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "mutually exclusive" "error names conflict"
teardown

echo OK
```

Make executable: `chmod +x gitea-ops/tests/test_gitea_pr_diff.sh`

- [ ] **Step 2: Run test, verify failure**

Run: `sh gitea-ops/tests/test_gitea_pr_diff.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Create script skeleton with arg parsing**

Create `gitea-ops/bin/gitea-pr-diff`:

```sh
#!/bin/sh
# Print PR metadata and unified diff for review.
#
# Usage:
#   gitea-pr-diff <PR#> [--raw|--json] [-r owner/repo] [-u URL]
#
# Default: human-readable header (PR title, base, head, file list) followed by
#          unified diff.
# --raw:   diff body only.
# --json:  {title, base, head, files:[...], diff:"..."} as a single JSON object.

set -eu
. "$(dirname "$0")/_common.sh"
require_cmd curl jq

PR=""
MODE="meta"   # meta | raw | json

while [ $# -gt 0 ]; do
    case "$1" in
        --raw)
            [ "$MODE" = "json" ] && die "--raw and --json are mutually exclusive"
            MODE="raw"; shift ;;
        --json)
            [ "$MODE" = "raw" ] && die "--raw and --json are mutually exclusive"
            MODE="json"; shift ;;
        -r|--repo) GITEA_REPO="$2"; shift 2 ;;
        -u|--url)  GITEA_URL="$2"; shift 2 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *)
            [ -z "$PR" ] || die "unexpected positional: $1"
            PR="$1"; shift ;;
    esac
done

[ -n "$PR" ] || die "PR# required"
resolve_remote

# Body of script filled in next step.
die "not implemented"
```

Make executable: `chmod +x gitea-ops/bin/gitea-pr-diff`

- [ ] **Step 4: Run test, verify pass**

Run: `sh gitea-ops/tests/test_gitea_pr_diff.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 5: Commit**

```sh
git add gitea-ops/bin/gitea-pr-diff gitea-ops/tests/test_gitea_pr_diff.sh
git commit -m "feat(gitea-ops): scaffold gitea-pr-diff with arg parsing"
```

---

## Task 3: `gitea-pr-diff` — meta + diff output (default mode)

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-diff`
- Modify: `gitea-ops/tests/test_gitea_pr_diff.sh`

- [ ] **Step 1: Write failing test for default mode**

Append to `gitea-ops/tests/test_gitea_pr_diff.sh` (before `echo OK`):

```sh
# --- default mode: meta header + diff ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"title":"Add widget","html_url":"https://gitea.test/owner/repo/pulls/42","state":"open","user":{"login":"alice"},"head":{"ref":"feat/widget","sha":"abc1234"},"base":{"ref":"main","sha":"def5678"}}'
fixture GET /api/v1/repos/owner/repo/pulls/42/files \
    '[{"filename":"src/a.go","status":"modified","additions":10,"deletions":3},{"filename":"src/b.sh","status":"added","additions":50,"deletions":0}]'
fixture GET /api/v1/repos/owner/repo/pulls/42.diff \
    'diff --git a/src/a.go b/src/a.go
@@ -1,1 +1,1 @@
-old
+new
'

out="$("$BIN/gitea-pr-diff" 42 2>&1)"
assert_contains "$out" "PR #42: Add widget" "header has PR title"
assert_contains "$out" "feat/widget" "header has head ref"
assert_contains "$out" "main" "header has base ref"
assert_contains "$out" "alice" "header has author"
assert_contains "$out" "src/a.go" "file list shows path"
assert_contains "$out" "+10 -3" "file list shows stats"
assert_contains "$out" "--- DIFF ---" "diff section header"
assert_contains "$out" "+new" "diff body included"
teardown
```

- [ ] **Step 2: Run test, verify failure**

Run: `sh gitea-ops/tests/test_gitea_pr_diff.sh`
Expected: FAIL — `not implemented`.

- [ ] **Step 3: Implement default mode**

In `gitea-ops/bin/gitea-pr-diff`, replace `die "not implemented"` with:

```sh
pr_path="/repos/$GITEA_REPO/pulls/$PR"

pr_json="$(gitea_get "$pr_path")"
err_msg="$(printf '%s' "$pr_json" | jq -r '.message // empty' 2>/dev/null || true)"
if [ -n "$err_msg" ]; then
    die "PR #$PR: $err_msg"
fi
title="$(printf '%s' "$pr_json" | jq -r '.title // empty')"
[ -n "$title" ] || die "PR #$PR not found"

files_json="$(gitea_get "$pr_path/files")"
diff_body="$(gitea_get "$pr_path.diff")"

if [ "$MODE" = "raw" ]; then
    printf '%s' "$diff_body"
    exit 0
fi

if [ "$MODE" = "json" ]; then
    jq -n \
        --arg title    "$(printf '%s' "$pr_json" | jq -r '.title // ""')" \
        --arg base_ref "$(printf '%s' "$pr_json" | jq -r '.base.ref // ""')" \
        --arg base_sha "$(printf '%s' "$pr_json" | jq -r '.base.sha // ""')" \
        --arg head_ref "$(printf '%s' "$pr_json" | jq -r '.head.ref // ""')" \
        --arg head_sha "$(printf '%s' "$pr_json" | jq -r '.head.sha // ""')" \
        --argjson files "$(printf '%s' "$files_json" | jq '[.[] | {path:.filename,status:.status,additions:.additions,deletions:.deletions}]')" \
        --arg diff     "$diff_body" \
        '{title:$title, base:{ref:$base_ref,sha:$base_sha}, head:{ref:$head_ref,sha:$head_sha}, files:$files, diff:$diff}'
    exit 0
fi

# Default mode: human header + diff.
url="$(printf '%s' "$pr_json" | jq -r '.html_url // empty')"
state="$(printf '%s' "$pr_json" | jq -r '.state // empty')"
author="$(printf '%s' "$pr_json" | jq -r '.user.login // empty')"
base_ref="$(printf '%s' "$pr_json" | jq -r '.base.ref // empty')"
base_sha="$(printf '%s' "$pr_json" | jq -r '.base.sha[0:7] // empty')"
head_ref="$(printf '%s' "$pr_json" | jq -r '.head.ref // empty')"
head_sha="$(printf '%s' "$pr_json" | jq -r '.head.sha[0:7] // empty')"

n_files="$(printf '%s' "$files_json" | jq 'length')"
total_add="$(printf '%s' "$files_json" | jq '[.[].additions] | add // 0')"
total_del="$(printf '%s' "$files_json" | jq '[.[].deletions] | add // 0')"

printf 'PR #%s: %s\n' "$PR" "$title"
[ -n "$url" ] && printf 'URL: %s\n' "$url"
printf 'Base: %s (%s)\n' "$base_ref" "$base_sha"
printf 'Head: %s (%s)\n' "$head_ref" "$head_sha"
printf 'State: %s\n' "$state"
printf 'Author: %s\n' "$author"
printf 'Files changed: %s (+%s -%s)\n' "$n_files" "$total_add" "$total_del"

# Per-file lines: status code (M/A/D/...) plus additions/deletions.
printf '%s' "$files_json" | jq -r '
    .[] |
    (.status[0:1] | ascii_upcase) as $s |
    "  \($s)  \(.filename)  (+\(.additions) -\(.deletions))"
'

printf '\n--- DIFF ---\n'
printf '%s' "$diff_body"
```

- [ ] **Step 4: Run test, verify pass**

Run: `sh gitea-ops/tests/test_gitea_pr_diff.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 5: Commit**

```sh
git add gitea-ops/bin/gitea-pr-diff gitea-ops/tests/test_gitea_pr_diff.sh
git commit -m "feat(gitea-ops): gitea-pr-diff default mode (meta+diff)"
```

---

## Task 4: `gitea-pr-diff` — `--raw`, `--json`, 404 cases

**Files:**
- Modify: `gitea-ops/tests/test_gitea_pr_diff.sh`

- [ ] **Step 1: Write failing tests for raw/json/404**

Append to `gitea-ops/tests/test_gitea_pr_diff.sh` (before `echo OK`):

```sh
# --- --raw: diff body only, no header ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"X","head":{"ref":"h","sha":"a"},"base":{"ref":"main","sha":"b"},"user":{"login":"u"},"state":"open","html_url":""}'
fixture GET /api/v1/repos/owner/repo/pulls/42/files '[]'
fixture GET /api/v1/repos/owner/repo/pulls/42.diff 'DIFF_BODY_42'

out="$("$BIN/gitea-pr-diff" 42 --raw 2>&1)"
assert_contains "$out" "DIFF_BODY_42" "raw includes diff"
case "$out" in *"PR #42:"*) echo FAIL: header leaked into raw >&2; exit 1 ;; esac
teardown

# --- --json: parseable JSON object ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"title":"My PR","head":{"ref":"feat","sha":"abc"},"base":{"ref":"main","sha":"def"},"user":{"login":"u"},"state":"open"}'
fixture GET /api/v1/repos/owner/repo/pulls/42/files \
    '[{"filename":"f.go","status":"modified","additions":5,"deletions":2}]'
fixture GET /api/v1/repos/owner/repo/pulls/42.diff 'D'

out="$("$BIN/gitea-pr-diff" 42 --json 2>&1)"
title="$(printf '%s' "$out" | jq -r '.title')"
assert_eq "$title" "My PR" "json has title"
fpath="$(printf '%s' "$out" | jq -r '.files[0].path')"
assert_eq "$fpath" "f.go" "json files[0].path"
diff_field="$(printf '%s' "$out" | jq -r '.diff')"
assert_eq "$diff_field" "D" "json diff field"
teardown

# --- 404: PR not found → die ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/999 '{"message":"Not found"}'
if "$BIN/gitea-pr-diff" 999 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on 404 >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "999" "error mentions PR number"
teardown
```

- [ ] **Step 2: Run test, verify all pass**

Run: `sh gitea-ops/tests/test_gitea_pr_diff.sh`
Expected: prints `OK`, exit 0. (Implementation from Task 3 already covers these branches; this task locks them in with tests.)

If any test fails because `--json` whitespace differs from expected, fix in `gitea-pr-diff` until tests pass.

- [ ] **Step 3: Commit**

```sh
git add gitea-ops/tests/test_gitea_pr_diff.sh
git commit -m "test(gitea-ops): cover gitea-pr-diff --raw, --json, 404 paths"
```

---

## Task 5: `gitea-pr-review` — argument parsing, token gating, `--help`

**Files:**
- Create: `gitea-ops/bin/gitea-pr-review`
- Create: `gitea-ops/tests/test_gitea_pr_review.sh`

- [ ] **Step 1: Write failing test for parsing and token gating**

Create `gitea-ops/tests/test_gitea_pr_review.sh`:

```sh
#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help ---
setup
out="$("$BIN/gitea-pr-review" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "--event" "--help mentions --event"
teardown

# --- missing PR# ---
setup
if "$BIN/gitea-pr-review" --event APPROVE --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
teardown

# --- missing --event ---
setup
if "$BIN/gitea-pr-review" 42 --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "event" "error mentions event"
teardown

# --- invalid --event ---
setup
if "$BIN/gitea-pr-review" 42 --event NOPE --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "invalid --event" "error mentions invalid event"
teardown

# --- missing --body and no inline ---
setup
if "$BIN/gitea-pr-review" 42 --event APPROVE 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "body" "error mentions body"
teardown

# --- both --body - and --inline - read stdin → die ---
setup
if echo x | "$BIN/gitea-pr-review" 42 --event APPROVE --body - --inline - 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "stdin" "error mentions stdin conflict"
teardown

# --- reviewer-token missing → die ---
setup
install_curl_stub
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/no-such-file"
unset GITEA_REVIEWER_TOKEN || true
if "$BIN/gitea-pr-review" 42 --event APPROVE --body ok 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "reviewer token" "error mentions reviewer token"
teardown

echo OK
```

Make executable: `chmod +x gitea-ops/tests/test_gitea_pr_review.sh`

- [ ] **Step 2: Run test, verify failure**

Run: `sh gitea-ops/tests/test_gitea_pr_review.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Create script skeleton**

Create `gitea-ops/bin/gitea-pr-review`:

```sh
#!/bin/sh
# Post a review on a Gitea PR using the reviewer token.
#
# Usage:
#   gitea-pr-review <PR#> --event <APPROVE|REQUEST_CHANGES|COMMENT>
#                          --body "..." | --body -
#                          [--inline FILE | --inline -]
#                          [-r owner/repo] [-u URL]
#
# Reads reviewer token from $GITEA_REVIEWER_TOKEN or ~/.config/gitea-ops/reviewer-token.

set -eu
. "$(dirname "$0")/_common.sh"
require_cmd curl jq

PR=""
EVENT=""
BODY=""
BODY_FROM_STDIN="false"
INLINE_FILE=""
INLINE_FROM_STDIN="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --event) EVENT="$2"; shift 2 ;;
        --body)
            if [ "$2" = "-" ]; then
                BODY_FROM_STDIN="true"
            else
                BODY="$2"
            fi
            shift 2 ;;
        --inline)
            if [ "$2" = "-" ]; then
                INLINE_FROM_STDIN="true"
            else
                INLINE_FILE="$2"
            fi
            shift 2 ;;
        -r|--repo) GITEA_REPO="$2"; shift 2 ;;
        -u|--url)  GITEA_URL="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *)
            [ -z "$PR" ] || die "unexpected positional: $1"
            PR="$1"; shift ;;
    esac
done

[ -n "$PR" ] || die "PR# required"
[ -n "$EVENT" ] || die "--event required"

case "$EVENT" in
    APPROVE)         API_EVENT="APPROVED" ;;
    REQUEST_CHANGES) API_EVENT="REQUEST_CHANGES" ;;
    COMMENT)         API_EVENT="COMMENT" ;;
    *) die "invalid --event: $EVENT (use APPROVE|REQUEST_CHANGES|COMMENT)" ;;
esac

if [ "$BODY_FROM_STDIN" = "true" ] && [ "$INLINE_FROM_STDIN" = "true" ]; then
    die "--body and --inline cannot both read stdin"
fi

if [ "$BODY_FROM_STDIN" = "true" ]; then
    BODY="$(cat)"
elif [ "$INLINE_FROM_STDIN" = "true" ]; then
    INLINE_JSON="$(cat)"
fi

# After resolving stdin, body must be non-empty unless event is COMMENT and inline supplied.
if [ -z "$BODY" ] && [ -z "${INLINE_JSON:-}" ] && [ -z "$INLINE_FILE" ]; then
    die "--body required (or --body -, or --inline)"
fi

resolve_remote
TOKEN="$(load_reviewer_token)"

# Body construction continues in next task.
die "not implemented"
```

Make executable: `chmod +x gitea-ops/bin/gitea-pr-review`

- [ ] **Step 4: Run test, verify pass**

Run: `sh gitea-ops/tests/test_gitea_pr_review.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 5: Commit**

```sh
git add gitea-ops/bin/gitea-pr-review gitea-ops/tests/test_gitea_pr_review.sh
git commit -m "feat(gitea-ops): scaffold gitea-pr-review with arg/token gating"
```

---

## Task 6: `gitea-pr-review` — POST review (summary + inline)

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-review`
- Modify: `gitea-ops/tests/test_gitea_pr_review.sh`

- [ ] **Step 1: Write failing tests for POST shape**

Append to `gitea-ops/tests/test_gitea_pr_review.sh` (before `echo OK`):

```sh
# --- summary-only: POST body has event+body, no comments ---
setup
install_curl_stub
fixture POST /api/v1/repos/owner/repo/pulls/42/reviews \
    '{"id":7,"html_url":"https://gitea.test/owner/repo/pulls/42#review-7"}'

out="$("$BIN/gitea-pr-review" 42 --event APPROVE --body "looks good" 2>&1)"
assert_contains "$out" "review-7" "review URL printed"

call="$(nth_call 1)"
method="$(printf '%s' "$call" | cut -f1)"
url="$(printf '%s'    "$call" | cut -f2)"
body="$(printf '%s'   "$call" | cut -f3)"
assert_eq "$method" "POST" "POST method"
assert_contains "$url" "/pulls/42/reviews" "reviews endpoint"
assert_contains "$body" '"event":"APPROVED"' "event mapped to APPROVED"
assert_contains "$body" '"body":"looks good"' "body string included"
case "$body" in *'"comments"'*) echo FAIL: comments key present without inline >&2; exit 1 ;; esac
teardown

# --- inline FILE: POST body includes comments[] ---
setup
install_curl_stub
fixture POST /api/v1/repos/owner/repo/pulls/42/reviews '{"id":8,"html_url":"u"}'

cat >"$TEST_TMP/inline.json" <<'EOF'
[{"path":"a.go","new_position":12,"body":"nit"},{"path":"b.sh","old_position":3,"body":"oops"}]
EOF

"$BIN/gitea-pr-review" 42 --event REQUEST_CHANGES --body "issues" --inline "$TEST_TMP/inline.json" >/dev/null 2>&1
body="$(nth_call 1 | cut -f3)"
assert_contains "$body" '"event":"REQUEST_CHANGES"' "event mapped"
assert_contains "$body" '"comments"' "comments array present"
assert_contains "$body" '"a.go"' "first comment path"
assert_contains "$body" '"new_position":12' "new_position numeric"
assert_contains "$body" '"old_position":3' "old_position numeric"
teardown

# --- --body - reads stdin ---
setup
install_curl_stub
fixture POST /api/v1/repos/owner/repo/pulls/42/reviews '{"id":9,"html_url":"u"}'
echo "from stdin" | "$BIN/gitea-pr-review" 42 --event COMMENT --body - >/dev/null 2>&1
body="$(nth_call 1 | cut -f3)"
assert_contains "$body" '"event":"COMMENT"' "event mapped"
assert_contains "$body" "from stdin" "body from stdin propagated"
teardown

# --- inline JSON missing required field → die ---
setup
install_curl_stub
echo '[{"path":"a.go","body":"missing position"}]' >"$TEST_TMP/bad.json"
if "$BIN/gitea-pr-review" 42 --event COMMENT --body x --inline "$TEST_TMP/bad.json" 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on bad inline >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "inline" "error mentions inline"
teardown

# --- 422 self-review → clear message ---
setup
install_curl_stub
fixture POST /api/v1/repos/owner/repo/pulls/42/reviews \
    '{"message":"Cannot create review for your own pull request"}'
if "$BIN/gitea-pr-review" 42 --event APPROVE --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on 422 >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "self-review" "error mentions self-review"
teardown
```

- [ ] **Step 2: Run test, verify failure**

Run: `sh gitea-ops/tests/test_gitea_pr_review.sh`
Expected: FAIL — `not implemented`.

- [ ] **Step 3: Implement POST logic**

In `gitea-ops/bin/gitea-pr-review`, replace `die "not implemented"` with:

```sh
# Resolve inline JSON source.
if [ -n "$INLINE_FILE" ]; then
    [ -r "$INLINE_FILE" ] || die "inline file not readable: $INLINE_FILE"
    INLINE_JSON="$(cat "$INLINE_FILE")"
fi

if [ -n "${INLINE_JSON:-}" ]; then
    # Validate: must be array; each element needs path, body, and one of new_position/old_position.
    if ! printf '%s' "$INLINE_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
        die "invalid inline JSON: not an array"
    fi
    bad="$(printf '%s' "$INLINE_JSON" | jq -r '
        [.[] |
         select((.path|type != "string") or
                (.body|type != "string") or
                ((.new_position|type) != "number" and (.old_position|type) != "number"))
        ] | length' 2>/dev/null || echo 1)"
    [ "$bad" = "0" ] || die "invalid inline JSON: each item needs path, body, and new_position or old_position"
fi

# Build POST body.
if [ -n "${INLINE_JSON:-}" ]; then
    body_json="$(jq -n \
        --arg event "$API_EVENT" \
        --arg body "$BODY" \
        --argjson comments "$INLINE_JSON" \
        '{event:$event, body:$body, comments:$comments}')"
else
    body_json="$(jq -n \
        --arg event "$API_EVENT" \
        --arg body "$BODY" \
        '{event:$event, body:$body}')"
fi

# POST with reviewer token (override Authorization header in api_json equivalent).
url="$GITEA_URL/api/v1/repos/$GITEA_REPO/pulls/$PR/reviews"
resp="$(printf '%s' "$body_json" | curl -sS -X POST \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    --data @- \
    "$url")"

err_msg="$(printf '%s' "$resp" | jq -r '.message // empty' 2>/dev/null || true)"
if [ -n "$err_msg" ]; then
    case "$err_msg" in
        *"own pull request"*|*"cannot review"*)
            die "self-review not allowed: $err_msg" ;;
        *)
            die "review failed: $err_msg" ;;
    esac
fi

review_url="$(printf '%s' "$resp" | jq -r '.html_url // empty')"
if [ -z "$review_url" ]; then
    printf '[gitea-pr-review] unexpected response:\n%s\n' "$resp" >&2
    exit 1
fi
printf '%s\n' "$review_url"
```

- [ ] **Step 4: Run test, verify pass**

Run: `sh gitea-ops/tests/test_gitea_pr_review.sh`
Expected: prints `OK`, exit 0.

- [ ] **Step 5: Commit**

```sh
git add gitea-ops/bin/gitea-pr-review gitea-ops/tests/test_gitea_pr_review.sh
git commit -m "feat(gitea-ops): gitea-pr-review POST + inline validation"
```

---

## Task 7: `gitea-pr-merge` — review gate (approved 1+ required)

**Files:**
- Modify: `gitea-ops/bin/gitea-pr-merge`
- Modify: `gitea-ops/tests/test_gitea_pr_merge.sh`

- [ ] **Step 1: Write failing tests for review gate**

Append to `gitea-ops/tests/test_gitea_pr_merge.sh` (before `echo OK`):

```sh
# --- review gate: APPROVED 1+ → merge proceeds ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews \
    '[{"id":1,"state":"APPROVED","dismissed":false,"user":{"login":"reviewer"}}]'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''

"$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree >/dev/null 2>&1
# 3 calls: GET pull, GET reviews, POST merge.
assert_eq "$(call_count)" "3" "three API calls (pull, reviews, merge)"
c2="$(nth_call 2)"
assert_contains "$c2" "/pulls/42/reviews" "second call is reviews"
c3="$(nth_call 3)"
assert_contains "$c3" "/pulls/42/merge" "third call is merge"
teardown

# --- review gate: empty reviews → die, no merge POST ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '[]'

if "$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on no APPROVED >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "no APPROVED" "error mentions no APPROVED"
assert_file_contains "$TEST_TMP/err" "--force" "error mentions --force"
# merge POST must NOT have been called.
if grep -q "/pulls/42/merge" "$CALL_LOG"; then
    echo FAIL: merge POST called when gate failed >&2; exit 1
fi
teardown

# --- review gate: dismissed APPROVED is ignored → die ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews \
    '[{"id":1,"state":"APPROVED","dismissed":true}]'

if "$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero (dismissed APPROVED) >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "no APPROVED" "dismissed does not count"
teardown

# --- review gate: --force skips reviews API entirely ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''

"$BIN/gitea-pr-merge" 42 --force --keep-branch --keep-worktree >/dev/null 2>&1
# Only 2 calls: GET pull, POST merge. No reviews GET.
assert_eq "$(call_count)" "2" "force skips reviews API"
if grep -q "/pulls/42/reviews" "$CALL_LOG"; then
    echo FAIL: --force must not GET reviews >&2; exit 1
fi
teardown

# --- already merged: gate skipped (idempotent re-run) ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 \
    '{"number":42,"merged":true,"head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
"$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree >/dev/null 2>&1 || true
# Only the GET pull. No reviews GET, no merge POST.
assert_eq "$(call_count)" "1" "already-merged short-circuits, no gate check"
teardown
```

- [ ] **Step 2: Run test, verify failure**

Run: `sh gitea-ops/tests/test_gitea_pr_merge.sh`
Expected: FAIL — gate not implemented; some pre-existing tests may also fail because they don't fixture the reviews endpoint.

**Pre-existing-test fix:** any pre-existing test that exercises the merge happy-path also needs an APPROVED reviews fixture. In `tests/test_gitea_pr_merge.sh`, every test that fixtures `GET /api/v1/repos/owner/repo/pulls/42` followed by a successful merge POST must add — immediately before the `out=...`/script invocation — this line:

```sh
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '[{"id":1,"state":"APPROVED","dismissed":false}]'
```

Apply this to every test in the file that calls `gitea-pr-merge` without `--force` and expects success. The "already merged" test does NOT need it (gate skipped). The "merge endpoint returns error" test DOES need it (gate runs first, then merge POST returns error). The "branch deletion / worktree cleanup" tests all need it.

- [ ] **Step 3: Implement gate in `gitea-pr-merge`**

In `gitea-ops/bin/gitea-pr-merge`, add `--force` to the flag parser. Find the existing `case "$1" in` block and add:

```sh
        --force) FORCE="true"; shift ;;
```

Initialize `FORCE="false"` near the other variable defaults at the top.

Then, between the existing comment `# 1. Fetch PR meta.` block and the `if [ "$merged" = "true" ]; then` line — i.e. after `[ -n "$head_ref" ] || die "PR #$PR not found or missing head.ref"` and before the merged-check — insert the gate:

```sh
# Review gate: require >=1 APPROVED non-dismissed review unless already merged or --force.
if [ "$merged" != "true" ] && [ "$FORCE" != "true" ]; then
    reviews_json="$(gitea_get "/repos/$GITEA_REPO/pulls/$PR/reviews")"
    if ! printf '%s' "$reviews_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        err_msg="$(printf '%s' "$reviews_json" | jq -r '.message // empty' 2>/dev/null || true)"
        die "failed to fetch reviews: ${err_msg:-unexpected response}"
    fi
    n_reviews="$(printf '%s' "$reviews_json" | jq 'length')"
    if [ "$n_reviews" -ge 50 ]; then
        printf '[gitea-pr-merge] warning: reviews list >= 50; pagination not implemented, gate may misfire\n' >&2
    fi
    n_approved="$(printf '%s' "$reviews_json" | jq '[.[] | select(.state=="APPROVED" and .dismissed==false)] | length')"
    if [ "$n_approved" -lt 1 ]; then
        die "no APPROVED review on PR #$PR; use --force to override"
    fi
fi
```

Update the `--help` block (the `sed -n '2,15p' "$0"` range) — extend the comment header at the top of the script to mention the gate and `--force`. Adjust the `sed` line range if the header grew.

- [ ] **Step 4: Update pre-existing tests with reviews fixtures**

Apply the fixture insertion described in Step 2 to each affected pre-existing test. For example, the `--method squash` test becomes:

```sh
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture GET /api/v1/repos/owner/repo/pulls/42/reviews '[{"id":1,"state":"APPROVED","dismissed":false}]'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
"$BIN/gitea-pr-merge" 42 --method squash --keep-branch --keep-worktree >/dev/null 2>&1
body2="$(nth_call 2 | cut -f3)"
# 1=GET pull, 2=GET reviews, 3=POST merge → adjust nth_call index from 2 to 3.
body3="$(nth_call 3 | cut -f3)"
assert_contains "$body3" '"Do":"squash"' "squash method propagates"
teardown
```

Apply analogous index adjustments wherever a test reads call positions: the merge POST is now `nth_call 3` (or `nth_call 2` if `--force` is used). The "merge endpoint returns error" test, branch-deletion tests, worktree-cleanup tests, "not on head branch" test, and "self-removal refusal" test all need this update.

- [ ] **Step 5: Run all merge tests, verify pass**

Run: `sh gitea-ops/tests/test_gitea_pr_merge.sh`
Expected: prints `OK`, exit 0. If any pre-existing test still fails, fix its fixtures or call-index assertions until green. Do not weaken the new gate tests to make pre-existing tests pass.

- [ ] **Step 6: Commit**

```sh
git add gitea-ops/bin/gitea-pr-merge gitea-ops/tests/test_gitea_pr_merge.sh
git commit -m "feat(gitea-ops): gitea-pr-merge requires APPROVED review (--force to override)"
```

---

## Task 8: `SKILL.md` documentation

**Files:**
- Modify: `gitea-ops/SKILL.md`

- [ ] **Step 1: Update Setup section**

In `gitea-ops/SKILL.md`, in the **Setup** section, after the existing item 3 (`Optional defaults`), add item 4:

```markdown
4. **Reviewer token** (separate Gitea account, repo write scope): generate at
   `https://<host>/user/settings/applications` while logged in as the reviewer
   account. Store at `~/.config/gitea-ops/reviewer-token` (mode 0600) **or**
   `GITEA_REVIEWER_TOKEN` env. Required only by `gitea-pr-review`. Run once
   to create an empty placeholder:
   ```sh
   mkdir -p ~/.config/gitea-ops
   touch ~/.config/gitea-ops/reviewer-token
   chmod 600 ~/.config/gitea-ops/reviewer-token
   ```
   Then paste the token into the file.
```

- [ ] **Step 2: Add `gitea-pr-diff` section**

In `gitea-ops/SKILL.md`, after the `gitea-pr` section and before `gitea-pr-merge`, add:

````markdown
### `gitea-pr-diff`

```
gitea-pr-diff <PR#> [--raw|--json] [-r owner/repo] [-u URL]
```

PR meta + unified diff을 stdout에 출력. 기본은 사람-친화 헤더 (title/base/head/files-changed) + diff. `--raw`는 diff body만, `--json`은 단일 JSON 객체.

Claude가 review 분석 input으로 사용:

```sh
gitea-pr-diff 42 > /tmp/pr-42.txt   # 분석용 dump
```
````

- [ ] **Step 3: Add `gitea-pr-review` section**

After the new `gitea-pr-diff` section, add:

````markdown
### `gitea-pr-review`

```
gitea-pr-review <PR#> --event <APPROVE|REQUEST_CHANGES|COMMENT>
                      --body "..." | --body -
                      [--inline FILE | --inline -]
                      [-r owner/repo] [-u URL]
```

reviewer token (separate from main token) 강제. Body는 `--body -`로 stdin에서, inline comments는 JSON file 또는 `--inline -` stdin.

Inline JSON schema (배열):
```json
[{"path":"file.go","new_position":42,"body":"..."},
 {"path":"old.sh","old_position":10,"body":"..."}]
```
각 항목은 `path`, `body`, `new_position` 또는 `old_position` 필수.

예시:
```sh
gitea-pr-review 42 --event APPROVE --body "Approved. Logic sound."
gitea-pr-review 42 --event REQUEST_CHANGES \
    --body "$(cat <<'EOF'
Several inline issues — see below.
EOF
)" --inline /tmp/review-42.json
```

422 self-review 응답은 명확한 메시지로 안내. PR author와 reviewer-token 계정이 같으면 발생.
````

- [ ] **Step 4: Update `gitea-pr-merge` section**

In the `gitea-pr-merge` section, update the Options block to add `--force` and update the workflow description:

```
gitea-pr-merge <PR#> [options]

Options:
  --method <merge|squash|rebase>   Merge strategy (default: merge)
  --force                          Skip review gate
  --keep-branch                    Keep remote head branch after merge
  --keep-worktree                  Keep local worktree after merge
  --worktree <path>                Explicit worktree path (default: cwd)
  -r owner/repo                    Override target repo
  -u URL                           Override Gitea base URL
```

Insert this paragraph immediately above the existing `기본 동작 (한 번에 끝내기):` line:

```markdown
**Review gate**: 머지 호출 직전 `GET /pulls/<n>/reviews`로 APPROVED & non-dismissed 리뷰가 1+개 있는지 확인. 없으면 거부, `--force`로 우회. PR이 이미 머지된 상태면 gate 자체를 스킵.
```

- [ ] **Step 5: Update workflow example**

Near the top of the file (after the "When to use" list, or wherever a workflow snippet feels natural — append to "When to use" if no existing example), add:

````markdown
## Workflow

```sh
# 1. Author creates PR
gitea-pr --title "Add widget" --head feat/widget

# 2. Reviewer (separate Claude session, reviewer-token):
gitea-pr-diff 42                    # dump meta+diff for analysis
gitea-pr-review 42 --event APPROVE \
    --body "Approved. Logic sound."

# 3. Author merges (gate auto-checks for APPROVED review):
gitea-pr-merge 42                   # passes gate, merges, cleans up
```
````

- [ ] **Step 6: Verify SKILL.md still parses cleanly**

Run: `head -40 gitea-ops/SKILL.md` (sanity check) and visually confirm code fences balance.

- [ ] **Step 7: Commit**

```sh
git add gitea-ops/SKILL.md
git commit -m "docs(gitea-ops): document gitea-pr-diff, gitea-pr-review, review gate"
```

---

## Task 9: Final integration check

**Files:** None (verification only)

- [ ] **Step 1: Run every test file**

```sh
sh gitea-ops/tests/test_common_helpers.sh
sh gitea-ops/tests/test_gitea_pr_diff.sh
sh gitea-ops/tests/test_gitea_pr_review.sh
sh gitea-ops/tests/test_gitea_pr_merge.sh
sh gitea-ops/tests/test_gitea_release_auto_notes.sh
```
Expected: every command prints `OK` and exits 0.

- [ ] **Step 2: Lint shell scripts**

```sh
shellcheck gitea-ops/bin/gitea-pr-diff gitea-ops/bin/gitea-pr-review gitea-ops/bin/_common.sh gitea-ops/bin/gitea-pr-merge
```
Expected: no warnings (existing scripts already pass; new ones should match).
If `shellcheck` is unavailable, skip with a note.

- [ ] **Step 3: Smoke test help output**

```sh
gitea-ops/bin/gitea-pr-diff --help
gitea-ops/bin/gitea-pr-review --help
gitea-ops/bin/gitea-pr-merge --help
```
Expected: each prints a usage block mentioning `<PR#>` (and for review, `--event`; for merge, `--force`).

- [ ] **Step 4: Verify file modes**

```sh
ls -l gitea-ops/bin/gitea-pr-diff gitea-ops/bin/gitea-pr-review gitea-ops/tests/test_gitea_pr_diff.sh gitea-ops/tests/test_gitea_pr_review.sh
```
Expected: all executable (`-rwxr-xr-x` or similar).

- [ ] **Step 5: Final commit if anything was tweaked**

If any minor fixes were applied during integration:
```sh
git add -u
git commit -m "chore(gitea-ops): integration cleanup"
```
Otherwise skip.

---

## Self-Review Notes

This plan covers each spec section:

- **Architecture** → Tasks 1, 2-4 (diff), 5-6 (review), 7 (merge gate)
- **Token 분리** → Task 1 + Task 5 token gating + Task 8 setup docs
- **Setup placeholder** → Task 8 Step 1 documents the `touch` step
- **`gitea-pr-diff`** → Tasks 2-4
- **`gitea-pr-review`** → Tasks 5-6
- **`gitea-pr-merge` 수정** → Task 7
- **Error handling table** → distributed across tasks (each error case has a test)
- **Testing strategy** → embedded in every implementation task (TDD), plus Task 9 integration
- **Migration / Rollout** → Task 8 (SKILL.md updates) + Task 9 (verification)
