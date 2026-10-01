#!/bin/sh
set -eu
. "$(dirname "$0")/lib.sh"

TOKEN='0123456789abcdef0123456789abcdef01234567'
REPO_JSON='{"html_url":"https://gitea.test/altair823-org/demo","clone_url":"https://gitea.test/altair823-org/demo.git"}'

# 스크립트를 실제 디렉토리 구조와 같게 복사한다:
#   $TEST_TMP/skills/gitea-ops/bin/gitea-repo-create
#   $TEST_TMP/skills/bitwarden-ops/bin/bw-get (stub)
# curl stub은 argv, stdin으로 받은 헤더, --data를 기록하고
# $FIXTURE_DIR/<METHOD>_<path>.body/.code로 응답한다 (없으면 404).
sandbox() {
    setup
    SK="$TEST_TMP/skills"
    mkdir -p "$SK/gitea-ops/bin" "$SK/bitwarden-ops/bin"
    cp "$BIN/gitea-repo-create" "$BIN/_common.sh" "$SK/gitea-ops/bin/"
    RC="$SK/gitea-ops/bin/gitea-repo-create"
    export BW_LOG="$TEST_TMP/bw.log" TOKEN
    cat >"$SK/bitwarden-ops/bin/bw-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$BW_LOG"
printf '%s \n\n' "$TOKEN"
EOF
    chmod +x "$SK/bitwarden-ops/bin/bw-get"
    cat >"$STUB_DIR/curl" <<'EOF'
#!/bin/sh
method=GET; url=""; data=""; hdr=""
printf 'ARGV\t%s\n' "$*" >>"$CALL_LOG"
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -H) [ "$2" = "@-" ] && hdr="$(cat)"; shift 2 ;;
        --data) data="$2"; shift 2 ;;
        -w) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
path="/${url#*://*/}"
printf 'CALL\t%s\t%s\t%s\t%s\n' "$method" "$path" "$hdr" "$data" >>"$CALL_LOG"
key="$(printf '%s_%s' "$method" "$path" | tr '/' '_')"
cat "$FIXTURE_DIR/$key.body" 2>/dev/null || true
printf '\n%s' "$(cat "$FIXTURE_DIR/$key.code" 2>/dev/null || echo 404)"
EOF
    chmod +x "$STUB_DIR/curl"
}

respond() {  # METHOD PATH CODE BODY
    key="$(printf '%s_%s' "$1" "$2" | tr '/' '_')"
    printf '%s' "$3" >"$FIXTURE_DIR/$key.code"
    printf '%s' "$4" >"$FIXTURE_DIR/$key.body"
}

calls() { grep "^CALL" "$CALL_LOG" | cut -f2,3; }

# --- --help ---
sandbox
out="$("$RC" --help 2>&1)"
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "--org" "--help mentions --org"
teardown

# --- 인자 오류는 토큰을 읽기 전에 거부 ---
sandbox
if "$RC" 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "저장소 이름 인자 필요" "missing name"
if "$RC" ../etc 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "저장소 이름에는" "path-like name rejected"
if "$RC" demo --org x --user 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "함께 쓸 수 없음" "--org and --user exclusive"
[ ! -e "$BW_LOG" ] || { echo "FAIL: bw-get called on bad args" >&2; exit 1; }
[ ! -s "$CALL_LOG" ] || { echo "FAIL: curl called on bad args" >&2; exit 1; }
teardown

# --- 이미 있음: GET만 하고 URL 출력, 0 종료. 토큰은 argv에 없고 공백이 제거됨 ---
sandbox
respond GET /api/v1/repos/altair823-org/demo 200 "$REPO_JSON"
out="$("$RC" demo 2>"$TEST_TMP/err")"
assert_eq "$out" "https://gitea.test/altair823-org/demo
https://gitea.test/altair823-org/demo.git" "web and clone URL printed"
assert_file_contains "$TEST_TMP/err" "이미 있음" "exists notice"
assert_eq "$(calls)" "GET	/api/v1/repos/altair823-org/demo" "only one GET"
assert_file_contains "$BW_LOG" "bw://GITEA_ADMIN_TOKEN/notes" "default token ref"
if grep "^ARGV" "$CALL_LOG" | grep -q "$TOKEN"; then echo "FAIL: token in curl argv" >&2; exit 1; fi
hdr="$(grep '^CALL' "$CALL_LOG" | cut -f4)"
assert_eq "$hdr" "Authorization: token $TOKEN" "trimmed token sent via stdin header"
teardown

# --- 없음: 조직에 비공개로 생성 ---
sandbox
respond POST /api/v1/orgs/altair823-org/repos 201 "$REPO_JSON"
out="$("$RC" demo 2>"$TEST_TMP/err")"
assert_contains "$out" "demo.git" "clone URL printed after create"
assert_file_contains "$TEST_TMP/err" "비공개" "private by default"
assert_contains "$(calls | sed -n 2p)" "POST	/api/v1/orgs/altair823-org/repos" "POST to org repos"
data="$(grep '^CALL' "$CALL_LOG" | sed -n 2p | cut -f5)"
assert_eq "$data" '{"name":"demo","description":"","private":true}' "create payload"
teardown

# --- --public --description, GITEA_DEFAULT_ORG, 호스트는 tea 로그인에서 ---
sandbox
install_curl_stub   # tea stub: gitea-ops-author,https://gitea.test
unset GITEA_URL
export GITEA_DEFAULT_ORG=team
respond POST /api/v1/orgs/team/repos 201 "$REPO_JSON"
"$RC" demo --public --description "설명 문장" >/dev/null 2>&1
assert_contains "$(grep '^CALL' "$CALL_LOG" | sed -n 1p)" "/api/v1/repos/team/demo" "GITEA_DEFAULT_ORG used"
assert_contains "$(grep '^ARGV' "$CALL_LOG" | sed -n 1p)" "https://gitea.test/api/v1/" "host from tea login"
data="$(grep '^CALL' "$CALL_LOG" | sed -n 2p | cut -f5)"
assert_eq "$data" '{"name":"demo","description":"설명 문장","private":false}' "public payload"
unset GITEA_DEFAULT_ORG
teardown

# --- --user: 토큰 계정 이름을 조회해 개인 저장소로 생성 ---
sandbox
respond GET /api/v1/user 200 '{"login":"alice"}'
respond POST /api/v1/user/repos 201 "$REPO_JSON"
"$RC" demo --user >/dev/null 2>&1
assert_eq "$(calls)" "GET	/api/v1/user
GET	/api/v1/repos/alice/demo
POST	/api/v1/user/repos" "user flow"
teardown

# --- 생성 실패: 상태 코드와 메시지 출력 ---
sandbox
respond POST /api/v1/orgs/altair823-org/repos 403 '{"message":"token does not have at least one of required scope(s)"}'
if "$RC" demo 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "HTTP 403" "status code reported"
assert_file_contains "$TEST_TMP/err" "required scope" "API message reported"
teardown

# --- 조회가 404, 200이 아니면 생성하지 않음 ---
sandbox
respond GET /api/v1/repos/altair823-org/demo 401 '{"message":"token is required"}'
if "$RC" demo 2>"$TEST_TMP/err"; then echo FAIL: expected non-zero >&2; exit 1; fi
assert_file_contains "$TEST_TMP/err" "HTTP 401" "lookup failure reported"
if grep -q "^CALL	POST" "$CALL_LOG"; then echo "FAIL: POST after failed lookup" >&2; exit 1; fi
teardown

echo OK
