#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
# Throwaway probe: source _common.sh, print the resolved BW_SESSION.

cat > bin/_sprobe <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/_common.sh"
echo "${BW_SESSION:-<unset>}"
EOF
chmod +x bin/_sprobe

CDIR="$(mktemp -d)"
export BITWARDEN_OPS_CACHE_DIR="$CDIR/c"      # not created yet → no session file
export BW_STUB_DB="$(mktemp)"
cat > "$BW_STUB_DB" <<'JSON'
[{"id":"i","name":"x","login":{"username":"u","password":"pw-secret"},"notes":null,"fields":[]}]
JSON
trap 'rm -rf "$CDIR" "$BW_STUB_DB" "$BW_STUB_DB.synced"; rm -f bin/_sprobe' EXIT

# 1) both absent → locked (exit 3) and probe shows unset
assert_eq "<unset>" "$(env -u BW_SESSION bash bin/_sprobe)" "no env, no file → unset"
assert_status 3 'env -u BW_SESSION bash bin/bw-get "bw://x"' "no env, no file → exit 3"

# 2) file present → adopted (probe) and functional (bw-get via stub)
mkdir -p "$CDIR/c"; chmod 700 "$CDIR/c"
printf 'file-sess' > "$CDIR/c/session"; chmod 600 "$CDIR/c/session"
assert_eq "file-sess" "$(env -u BW_SESSION bash bin/_sprobe)" "file adopted when env unset"
assert_eq "pw-secret" "$(env -u BW_SESSION bash bin/bw-get 'bw://x')" "file fallback is functional"
printf 'nl-sess\n' > "$CDIR/c/session"; chmod 600 "$CDIR/c/session"
assert_eq "nl-sess" "$(env -u BW_SESSION bash bin/_sprobe)" "trailing newline in session file is stripped"

# 3) env-wins: env set + file present → env value used, file ignored
assert_eq "env-sess" "$(BW_SESSION=env-sess bash bin/_sprobe)" "env wins over file"

# 4) empty file treated as absent → locked
: > "$CDIR/c/session"
assert_eq "<unset>" "$(env -u BW_SESSION bash bin/_sprobe)" "empty session file → unset"
assert_status 3 'env -u BW_SESSION bash bin/bw-get "bw://x"' "empty file → exit 3"

# 5) mask still hides a leaked session value
printf 'BW_SESSION=supersecretvalue plain\n' | \
  (cd "$PWD" && bash -c '. bin/_common.sh; mask') > "$CDIR/m" 2>/dev/null || true
assert_not_contains "$(cat "$CDIR/m")" "supersecretvalue" "mask still hides session"

finish
echo "PASS test_session_file"
