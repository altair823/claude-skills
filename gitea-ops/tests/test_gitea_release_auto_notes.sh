#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --auto-notes prepends "## 변경사항 (since v0.1.0)" with merged PRs ---
setup
install_curl_stub
# Two releases — newest first; the second is the "previous" tag.
fixture GET /api/v1/repos/owner/repo/releases '[{"tag_name":"v0.1.1","created_at":"2026-04-25T00:00:00Z"},{"tag_name":"v0.1.0","created_at":"2026-04-20T00:00:00Z"}]'
# Merged PRs since v0.1.0 (merged_at > 2026-04-20).
fixture GET /api/v1/repos/owner/repo/pulls '[{"number":42,"title":"feat: add foo","merged":true,"merged_at":"2026-04-22T00:00:00Z","base":{"ref":"main"}},{"number":41,"title":"fix: bar","merged":true,"merged_at":"2026-04-21T00:00:00Z","base":{"ref":"main"}},{"number":40,"title":"chore: pre-v0.1.0 work","merged":true,"merged_at":"2026-04-19T00:00:00Z","base":{"ref":"main"}}]'
# Release create response.
fixture POST /api/v1/repos/owner/repo/releases '{"id":99,"html_url":"https://gitea.test/owner/repo/releases/tag/v0.1.2"}'

# Run inside a fake (non-)git work tree (release skips tag push if not in a repo).
cd "$TEST_TMP"
cat >"$STUB_DIR/git" <<'GIT_EOF'
#!/bin/sh
case "$*" in
    "rev-parse --is-inside-work-tree") exit 1 ;;   # treat as not-a-repo so push step skips
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

"$BIN/gitea-release" v0.1.2 --auto-notes --notes "Image: harbor.test/foo:v0.1.2" >/dev/null 2>&1

# 3rd call should be POST releases with body containing both sections.
post_call="$(grep -P '^POST\thttps://gitea.test/api/v1/repos/owner/repo/releases\t' "$CALL_LOG" | head -1)"
[ -n "$post_call" ] || { echo "FAIL: no POST /releases call" >&2; exit 1; }
body="$(printf '%s' "$post_call" | cut -f3)"

# Decode the .body field from the JSON sent to the create-release endpoint.
sent_notes="$(printf '%s' "$body" | jq -r '.body')"
assert_contains "$sent_notes" "## 변경사항 (since v0.1.0)" "header present"
assert_contains "$sent_notes" "#42" "PR #42 listed"
assert_contains "$sent_notes" "feat: add foo" "PR title listed"
assert_contains "$sent_notes" "#41" "PR #41 listed"
# PR #40 merged before v0.1.0 → must NOT appear.
case "$sent_notes" in *"#40"*) echo "FAIL: pre-tag PR #40 leaked" >&2; exit 1 ;; esac
# User --notes appended below the PR section.
assert_contains "$sent_notes" "Image: harbor.test/foo:v0.1.2" "user notes appended"
teardown

# --- no previous release → header uses "(initial release)" ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/releases '[]'
fixture GET /api/v1/repos/owner/repo/pulls '[{"number":1,"title":"feat: bootstrap","merged":true,"merged_at":"2026-04-10T00:00:00Z","base":{"ref":"main"}}]'
fixture POST /api/v1/repos/owner/repo/releases '{"id":1,"html_url":"https://gitea.test/owner/repo/releases/tag/v0.1.0"}'
cd "$TEST_TMP"
cat >"$STUB_DIR/git" <<'GIT_EOF'
#!/bin/sh
case "$*" in
    "rev-parse --is-inside-work-tree") exit 1 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

"$BIN/gitea-release" v0.1.0 --auto-notes >/dev/null 2>&1
post_call="$(grep -P '^POST\thttps://gitea.test/api/v1/repos/owner/repo/releases\t' "$CALL_LOG" | head -1)"
body="$(printf '%s' "$post_call" | cut -f3)"
sent_notes="$(printf '%s' "$body" | jq -r '.body')"
assert_contains "$sent_notes" "## 변경사항 (initial release)" "initial release header"
assert_contains "$sent_notes" "#1" "PR listed"
teardown

# --- zero merged PRs since prev → section omitted entirely (no empty header) ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/releases '[{"tag_name":"v0.1.1","created_at":"2026-04-25T00:00:00Z"},{"tag_name":"v0.1.0","created_at":"2026-04-20T00:00:00Z"}]'
fixture GET /api/v1/repos/owner/repo/pulls '[]'
fixture POST /api/v1/repos/owner/repo/releases '{"id":99,"html_url":"x"}'
cd "$TEST_TMP"
cat >"$STUB_DIR/git" <<'GIT_EOF'
#!/bin/sh
case "$*" in
    "rev-parse --is-inside-work-tree") exit 1 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

"$BIN/gitea-release" v0.1.2 --auto-notes --notes "manual note only" >/dev/null 2>&1
post_call="$(grep -P '^POST\thttps://gitea.test/api/v1/repos/owner/repo/releases\t' "$CALL_LOG" | head -1)"
body="$(printf '%s' "$post_call" | cut -f3)"
sent_notes="$(printf '%s' "$body" | jq -r '.body')"
case "$sent_notes" in *"## 변경사항"*) echo "FAIL: empty PR section leaked" >&2; exit 1 ;; esac
assert_contains "$sent_notes" "manual note only" "user notes preserved"
teardown

echo OK
