#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"
. "$BIN/_common.sh"

# --- detect_gitea_host: GITEA_URL env wins ---
setup
GITEA_URL="https://override.example" host="$(detect_gitea_host)"
assert_eq "$host" "https://override.example" "GITEA_URL env takes precedence"
teardown

# --- detect_gitea_host: parses https git remote ---
setup
work="$TEST_TMP/work"
mkdir -p "$work"
(cd "$work" && git init -q && git remote add origin https://gitea.example/owner/repo.git)
unset GITEA_URL
host="$(cd "$work" && detect_gitea_host)"
assert_eq "$host" "https://gitea.example" "https remote → host"
teardown

# --- detect_gitea_host: parses ssh git remote ---
setup
work="$TEST_TMP/work"
mkdir -p "$work"
(cd "$work" && git init -q && git remote add origin git@gitea.example:owner/repo.git)
unset GITEA_URL
host="$(cd "$work" && detect_gitea_host)"
assert_eq "$host" "https://gitea.example" "ssh remote → https host"
teardown

# --- detect_gitea_host: outside git tree, no env → fails ---
setup
unset GITEA_URL
if (cd "$TEST_TMP" && detect_gitea_host) 2>/dev/null; then
    echo "FAIL: expected detect_gitea_host to fail outside git tree" >&2; exit 1
fi
teardown

# --- ensure_tea_login: skips when login already exists (stub claims it does) ---
setup
install_curl_stub
ensure_tea_login gitea-ops-author GITEA_TOKEN "$GITEA_TOKEN_FILE"
# ensure_tea_login should not call `tea logins add`; if it did, the stub would
# log nothing for that command (logins ls/add are no-op log-wise) but exit 0.
# The success criterion is simply that the call returned without error.
teardown

# --- ensure_tea_login: missing token + missing file → die ---
setup
install_curl_stub
# Override stub to claim no logins exist so the add path is taken.
cat >"$STUB_DIR/tea" <<'EOF'
#!/bin/sh
case "${1:-}" in
    logins) printf 'NAME,URL,SSH HOST,USER,DEFAULT\n'; exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$STUB_DIR/tea"
unset GITEA_TOKEN || true
export GITEA_TOKEN_FILE="$TEST_TMP/no-such-file"
if (ensure_tea_login gitea-ops-author GITEA_TOKEN "$GITEA_TOKEN_FILE") 2>"$TEST_TMP/err"; then
    echo "FAIL: expected ensure_tea_login to die on missing token" >&2; exit 1
fi
assert_file_contains "$TEST_TMP/err" "token 없음" "error mentions missing token"
teardown

# --- tea_api: routes to author login by default ---
setup
install_curl_stub
fixture GET /api/v1/repos/owner/repo/pulls/42 '{"number":42}'
out="$(tea_api GET "/repos/{owner}/{repo}/pulls/42")"
assert_contains "$out" '"number":42' "tea_api returns fixture body"
call="$(nth_call 1)"
method="$(printf '%s' "$call" | cut -f1)"
assert_eq "$method" "GET" "method recorded as GET"
teardown

# --- tea_api_json: pipes stdin body via @- ---
setup
install_curl_stub
fixture POST /api/v1/repos/owner/repo/issues '{"number":7,"html_url":"https://gitea.test/x"}'
out="$(printf '{"title":"x"}' | tea_api_json POST "/repos/{owner}/{repo}/issues")"
assert_contains "$out" '"number":7' "tea_api_json returns fixture body"
call="$(nth_call 1)"
body="$(printf '%s' "$call" | cut -f3)"
assert_eq "$body" '{"title":"x"}' "stdin body forwarded verbatim"
teardown

# --- TEA_LOGIN env switches the login (review path) ---
setup
install_curl_stub
fixture POST /api/v1/repos/owner/repo/pulls/9/reviews '{"html_url":"https://gitea.test/r"}'
TEA_LOGIN="$GITEA_LOGIN_REVIEWER" out="$(printf '{"event":"APPROVED"}' \
    | tea_api_json POST "/repos/{owner}/{repo}/pulls/9/reviews")"
assert_contains "$out" '"html_url"' "reviewer login path returns body"
teardown

echo OK
