#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
export BW_STUB_DB="$(mktemp)"
_NL_CHK="$(mktemp)"
trap 'rm -f "$BW_STUB_DB" "$BW_STUB_DB.synced" "$_NL_CHK"' EXIT
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"id1","name":"site","login":{"username":"u","password":"pw-secret"},
  "notes":"-----BEGIN OPENSSH PRIVATE KEY-----\nKEYBODY\n-----END OPENSSH PRIVATE KEY-----",
  "fields":[{"name":"api","value":"tok-123","type":1}]},
 {"id":"id2","name":"memo","type":2,"login":null,"notes":"note-body","fields":[]},
 {"id":"id3","name":"dup","login":{"password":"d1"},"notes":null,"fields":[]},
 {"id":"id4","name":"dup","login":{"password":"d2"},"notes":null,"fields":[]},
 {"id":"id5","name":"nopw","type":1,"login":{"username":"only-user","password":null},"notes":null,"fields":[]},
 {"id":"id6","name":"legacy","type":1,"login":{"username":null,"password":null},"notes":null,
  "fields":[{"name":"username","value":"f-user","type":0},{"name":"password","value":"f-pass","type":1}]}]
JSON

# 예약어와 같은 이름의 사용자 정의 필드: 로그인 값이 비어 있으면 필드 값을 쓴다.
assert_eq "f-pass" "$(BW_SESSION=x bash bin/bw-get 'bw://legacy/password')" "password falls back to same-named field"
assert_eq "f-user" "$(BW_SESSION=x bash bin/bw-get 'bw://legacy/username')" "username falls back to same-named field"
assert_eq "u" "$(BW_SESSION=x bash bin/bw-get 'bw://site/username')" "login username wins"

assert_eq "pw-secret" "$(BW_SESSION=x bash bin/bw-get 'bw://site')" "password ref"
_exp_field="tok-123"   # single source: also drives the byte-length check below
assert_eq "$_exp_field" "$(BW_SESSION=x bash bin/bw-get 'bw://site/api')" "field ref"
# Field path must not append a trailing newline — it has to stay byte-consistent
# with `bw get password`, which bw-get forwards verbatim. $() would strip the
# newline and mask the bug, so capture to a file and assert the exact length.
# $(( )) normalizes the count: BSD/macOS `wc` left-pads it with spaces. The
# fixture token is ASCII so its char length (${#...}) equals its byte length.
BW_SESSION=x bash bin/bw-get 'bw://site/api' > "$_NL_CHK"
assert_eq "${#_exp_field}" "$(( $(wc -c < "$_NL_CHK") ))" "field ref: no trailing newline (exact bytes)"
assert_contains "$(BW_SESSION=x bash bin/bw-get 'bw://site/notes')" "BEGIN OPENSSH" "notes ref"
assert_contains "$(BW_SESSION=x bash bin/bw-get --ssh 'bw://site')" "KEYBODY" "--ssh returns notes key"
assert_status 1 'BW_SESSION=x bash bin/bw-get "bw://nope"' "missing item → error"
assert_status 1 'BW_SESSION=x bash bin/bw-get "bw://site/nofield"' "missing field → error"
assert_status 3 'env -u BW_SESSION bash bin/bw-get "bw://site"' "locked vault → exit 3"

# 예약어: /username, /password
assert_eq "u" "$(BW_SESSION=x bash bin/bw-get 'bw://site/username')" "username ref"
assert_eq "pw-secret" "$(BW_SESSION=x bash bin/bw-get 'bw://site/password')" "explicit password ref"
BW_SESSION=x bash bin/bw-get 'bw://site/username' > "$_NL_CHK"
assert_eq "1" "$(( $(wc -c < "$_NL_CHK") ))" "username ref: no trailing newline"

# 보안 메모 항목을 필드 없이 참조하면 /notes를 안내한다.
err="$(BW_SESSION=x bash bin/bw-get 'bw://memo' 2>&1 >/dev/null || true)"
assert_contains "$err" "보안 메모 항목입니다" "note item without /notes → explains"
assert_contains "$err" "bw://memo/notes" "note item → suggests /notes ref"
assert_not_contains "$err" "note-body" "note error hides value"
assert_eq "note-body" "$(BW_SESSION=x bash bin/bw-get 'bw://memo/notes')" "note item /notes works"

# 없는 필드: 쓸 수 있는 참조 이름만 보여주고 값은 보여주지 않는다.
err="$(BW_SESSION=x bash bin/bw-get 'bw://site/nofield' 2>&1 >/dev/null || true)"
assert_contains "$err" "nofield" "missing field named"
assert_contains "$err" "username, password, notes, api" "missing field lists refs"
assert_not_contains "$err" "tok-123" "missing field error hides field value"
assert_not_contains "$err" "pw-secret" "missing field error hides password"
err="$(BW_SESSION=x bash bin/bw-get 'bw://nopw' 2>&1 >/dev/null || true)"
assert_contains "$err" "password 값이 없습니다" "empty password reported as missing"
assert_contains "$err" "쓸 수 있는 참조: username" "empty password lists username"
assert_not_contains "$err" "only-user" "error hides username value"

# 없는 항목은 bw-sync를 안내한다.
err="$(BW_SESSION=x bash bin/bw-get 'bw://nope' 2>&1 >/dev/null || true)"
assert_contains "$err" "항목이 없습니다" "missing item message"
assert_contains "$err" "bw-sync" "missing item suggests bw-sync"

# 같은 이름이 여럿이면 그 사실을 알린다.
err="$(BW_SESSION=x bash bin/bw-get 'bw://dup' 2>&1 >/dev/null || true)"
assert_contains "$err" "여러 항목" "duplicate names reported"

# 세션은 있지만 만료되어 금고가 잠긴 경우도 exit 3.
assert_status 3 'BW_SESSION=x BW_STUB_STATUS=locked bash bin/bw-get "bw://site"' "expired session → exit 3"

finish
echo "PASS test_get"
