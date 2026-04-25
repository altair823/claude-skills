#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

# --- --help prints usage and exits 0 ---
setup
out="$("$BIN/gitea-pr-merge" --help 2>&1 || true)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "PR#" "--help mentions PR# arg"
teardown

# --- missing PR# fails with clear error ---
setup
if "$BIN/gitea-pr-merge" 2>"$TEST_TMP/err"; then
    echo FAIL: expected exit non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "PR" "error mentions PR"
teardown

# --- unknown flag fails ---
setup
if "$BIN/gitea-pr-merge" 1 --bogus 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero on unknown flag >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "unknown" "error mentions unknown"
teardown

# --- happy path: PR mergeable → fetch + merge → success message ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"},"html_url":"https://gitea.test/owner/repo/pulls/42"}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''   # 200 empty body on success

# Skip git/worktree work for this test by passing --keep-branch and --keep-worktree.
out="$("$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree 2>&1)"
assert_contains "$out" "merged" "success message mentions merged"
assert_contains "$out" "feat/topic" "success message mentions branch"

# verify two API calls: GET pulls/42, then POST .../merge
assert_eq "$(call_count)" "2" "two API calls"
c1="$(nth_call 1)"; assert_contains "$c1" "GET" "1st is GET"
c2="$(nth_call 2)"; assert_contains "$c2" "POST" "2nd is POST"
assert_contains "$c2" "/pulls/42/merge" "2nd hits merge endpoint"
# body should be {"Do":"merge"}
body2="$(printf '%s' "$c2" | cut -f3)"
assert_contains "$body2" '"Do":"merge"' "merge body uses Do=merge"
teardown

# --- already merged: short-circuit, do not POST ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":true,"head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
out="$("$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree 2>&1)" || true
assert_contains "$out" "already merged" "warns already merged"
assert_eq "$(call_count)" "1" "no POST call when already merged"
teardown

# --- --method squash → body uses Do=squash ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
"$BIN/gitea-pr-merge" 42 --method squash --keep-branch --keep-worktree >/dev/null 2>&1
body2="$(nth_call 2 | cut -f3)"
assert_contains "$body2" '"Do":"squash"' "squash method propagates"
teardown

# --- merge endpoint returns error JSON → script dies with message ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"head":{"ref":"feat/topic"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge '{"message":"Pull request is not mergeable"}'
if "$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree 2>"$TEST_TMP/err"; then
    echo "FAIL: expected non-zero on merge error" >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "not mergeable" "error message propagated"
teardown

# --- branch deletion: default behavior calls `git push origin --delete <head>` ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''

# git stub: log all args; treat `rev-parse --is-inside-work-tree` as inside, everything else success.
GIT_LOG="$TEST_TMP/git.log"; export GIT_LOG
cat >"$STUB_DIR/git" <<'GIT_EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GIT_LOG"
case "$*" in
    "rev-parse --is-inside-work-tree") echo true; exit 0 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

"$BIN/gitea-pr-merge" 42 --keep-worktree >/dev/null 2>&1
assert_file_contains "$GIT_LOG" "push origin --delete feat/topic" "deletes remote branch"
teardown

# --- --keep-branch suppresses deletion ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
GIT_LOG="$TEST_TMP/git.log"; export GIT_LOG
cat >"$STUB_DIR/git" <<'GIT_EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GIT_LOG"
case "$*" in
    "rev-parse --is-inside-work-tree") echo true; exit 0 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

"$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree >/dev/null 2>&1
if [ -e "$GIT_LOG" ] && grep -q "push origin --delete" "$GIT_LOG"; then
    echo "FAIL: --keep-branch should suppress deletion" >&2; exit 1
fi
teardown

# --- branch delete failure is non-fatal ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
cat >"$STUB_DIR/git" <<'GIT_EOF'
#!/bin/sh
case "$*" in
    "rev-parse --is-inside-work-tree") echo true; exit 0 ;;
    "push origin --delete feat/topic") exit 1 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

# Should still exit 0 even though `git push --delete` failed.
"$BIN/gitea-pr-merge" 42 --keep-worktree >"$TEST_TMP/out" 2>&1
assert_eq "$?" "0" "delete failure does not abort"
assert_file_contains "$TEST_TMP/out" "could not delete remote branch" "warns on failure"
teardown

# --- worktree cleanup: cwd is on head branch → fetch/checkout/remove sequence ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
GIT_LOG="$TEST_TMP/git.log"; export GIT_LOG

# Pretend we're on feat/topic in worktree /tmp/wt/feat-topic, main is at /tmp/wt/main.
WT_HEAD="$TEST_TMP/wt/feat-topic"
WT_MAIN="$TEST_TMP/wt/main"
mkdir -p "$WT_HEAD" "$WT_MAIN"
cd "$WT_HEAD"

cat >"$STUB_DIR/git" <<GIT_EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$GIT_LOG"
case "\$*" in
    "rev-parse --is-inside-work-tree") echo true; exit 0 ;;
    "rev-parse --abbrev-ref HEAD") echo feat/topic; exit 0 ;;
    "worktree list --porcelain")
        printf 'worktree %s\nHEAD abc\nbranch refs/heads/main\n\nworktree %s\nHEAD def\nbranch refs/heads/feat/topic\n' "$WT_MAIN" "$WT_HEAD"; exit 0 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

"$BIN/gitea-pr-merge" 42 >/dev/null 2>&1
cd /tmp || cd /
# Verify the cleanup sequence appeared in order.
assert_file_contains "$GIT_LOG" "fetch --prune" "fetched"
assert_file_contains "$GIT_LOG" "checkout main" "checked out main"
assert_file_contains "$GIT_LOG" "pull" "pulled"
assert_file_contains "$GIT_LOG" "worktree remove $WT_HEAD" "removed worktree"
teardown

# --- --keep-worktree suppresses cleanup ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
GIT_LOG="$TEST_TMP/git.log"; export GIT_LOG
cat >"$STUB_DIR/git" <<'GIT_EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GIT_LOG"
case "$*" in
    "rev-parse --is-inside-work-tree") echo true; exit 0 ;;
    "rev-parse --abbrev-ref HEAD") echo feat/topic; exit 0 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

"$BIN/gitea-pr-merge" 42 --keep-branch --keep-worktree >/dev/null 2>&1
if [ -e "$GIT_LOG" ] && grep -q "worktree remove" "$GIT_LOG"; then
    echo "FAIL: --keep-worktree should not call remove" >&2; exit 1
fi
teardown

# --- not on head branch → skip cleanup with warning ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
GIT_LOG="$TEST_TMP/git.log"; export GIT_LOG
cat >"$STUB_DIR/git" <<'GIT_EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GIT_LOG"
case "$*" in
    "rev-parse --is-inside-work-tree") echo true; exit 0 ;;
    "rev-parse --abbrev-ref HEAD") echo main; exit 0 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

out="$("$BIN/gitea-pr-merge" 42 --keep-branch 2>&1)"
assert_contains "$out" "not on head branch" "warns when not on head"
if [ -e "$GIT_LOG" ] && grep -q "worktree remove" "$GIT_LOG"; then
    echo "FAIL: should not call remove from non-head cwd" >&2; exit 1
fi
teardown

# --- self-removal refusal: cwd IS the main worktree → skip with warning, exit 0 ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42,"merged":false,"state":"open","head":{"ref":"feat/topic"},"base":{"ref":"main"}}'
fixture POST /api/v1/repos/owner/repo/pulls/42/merge ''
GIT_LOG="$TEST_TMP/git.log"; export GIT_LOG

WT_MAIN="$TEST_TMP/wt/main"
mkdir -p "$WT_MAIN"
cd "$WT_MAIN"

cat >"$STUB_DIR/git" <<GIT_EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$GIT_LOG"
case "\$*" in
    "rev-parse --is-inside-work-tree") echo true; exit 0 ;;
    "rev-parse --abbrev-ref HEAD") echo feat/topic; exit 0 ;;
    "worktree list --porcelain")
        printf 'worktree %s\nHEAD abc\nbranch refs/heads/main\n' "$WT_MAIN"; exit 0 ;;
    *) exit 0 ;;
esac
GIT_EOF
chmod +x "$STUB_DIR/git"

out="$("$BIN/gitea-pr-merge" 42 --keep-branch 2>&1)"
exit_code=$?
assert_eq "$exit_code" "0" "self-removal refusal exits 0"
assert_contains "$out" "refusing self-removal" "warns about self-removal"
if [ -e "$GIT_LOG" ] && grep -q "worktree remove" "$GIT_LOG"; then
    echo "FAIL: self-removal must not call worktree remove" >&2; exit 1
fi
cd /tmp || cd /
teardown

echo OK
