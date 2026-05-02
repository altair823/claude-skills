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
assert_file_contains "$TEST_TMP/err" "PR# 인자" "error mentions PR# requirement"
teardown

# --- missing --event ---
setup
if "$BIN/gitea-pr-review" 42 --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "--event 인자" "error mentions --event requirement"
teardown

# --- invalid --event ---
setup
if "$BIN/gitea-pr-review" 42 --event NOPE --body x 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "--event 값 오류" "error mentions invalid event"
teardown

# --- missing --body and no inline ---
setup
if "$BIN/gitea-pr-review" 42 --event APPROVE 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "--body 또는 --inline" "error mentions body/inline requirement"
teardown

# --- both --body - and --inline - read stdin → die ---
setup
if echo x | "$BIN/gitea-pr-review" 42 --event APPROVE --body - --inline - 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "stdin 사용 불가" "error mentions stdin conflict"
teardown

# --- reviewer login + token both missing → die ---
# Override the stub's `tea logins ls` so it returns no entries — that forces
# ensure_tea_login down the registration path, which then needs a token file
# (also absent here), producing the expected die() message.
setup
install_curl_stub
cat >"$STUB_DIR/tea" <<'EOF'
#!/bin/sh
case "${1:-}" in
    logins) printf 'NAME,URL,SSH HOST,USER,DEFAULT\n'; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$STUB_DIR/tea"
export GITEA_REVIEWER_TOKEN_FILE="$TEST_TMP/no-such-file"
unset GITEA_REVIEWER_TOKEN || true
if "$BIN/gitea-pr-review" 42 --event APPROVE --body ok 2>"$TEST_TMP/err"; then
    echo FAIL: expected non-zero >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "gitea-ops-reviewer" "error mentions reviewer login name"
assert_file_contains "$TEST_TMP/err" "token 없음" "error mentions missing token"
teardown

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

out="$("$BIN/gitea-pr-review" 42 --event REQUEST_CHANGES --body "issues" --inline "$TEST_TMP/inline.json" 2>&1)"
assert_contains "$out" "u" "review URL printed (matches fixture html_url)"
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
out="$(echo "from stdin" | "$BIN/gitea-pr-review" 42 --event COMMENT --body - 2>&1)"
assert_contains "$out" "u" "review URL printed (matches fixture html_url)"
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
assert_file_contains "$TEST_TMP/err" "inline JSON 오류" "error mentions inline JSON failure"
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

echo OK
