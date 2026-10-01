#!/bin/sh
# _HARBOR_USER_REF / _HARBOR_SECRET_REF: values come from bitwarden-ops bw-get.
. "$(dirname "$0")/lib.sh"

# Fake bw-get: maps refs to values, logs each call. STUB_BW_LOCKED=1 → exit 3.
install_bw_get_stub() {
    cat >"$STUB_DIR/bw-get" <<'BW_EOF'
#!/bin/sh
echo "$1" >>"${BW_LOG:?BW_LOG unset}"
[ "${STUB_BW_LOCKED:-0}" = "1" ] && { echo "bitwarden-ops: locked vault" >&2; exit 3; }
case "$1" in
    bw://h/username) printf 'ref-user' ;;
    bw://h) printf 'ref-secret' ;;
    *) echo "bitwarden-ops: 항목이 없습니다: $1" >&2; exit 1 ;;
esac
BW_EOF
    chmod +x "$STUB_DIR/bw-get"
    export HARBOR_BW_GET="$STUB_DIR/bw-get"
    export BW_LOG="$TEST_TMP/bw.log"
    : >"$BW_LOG"
}

write_ref_config() {
    cat >"$HOME/.config/harbor-ops/config" <<CFG
HARBOR_DEFAULT_PROFILE=home
home_HARBOR_URL=https://harbor.test
home_HARBOR_USER_REF=bw://h/username
home_HARBOR_SECRET_REF=bw://h
$1
CFG
    chmod 600 "$HOME/.config/harbor-ops/config"
}

load() { # $1 = common.sh path (default: $BIN/_common.sh)
    bash -c "
        set -euo pipefail
        . '${1:-$BIN/_common.sh}'
        load_profile
        echo \"\$HARBOR_USER \$HARBOR_SECRET\"
    "
}

# --- refs resolve user and secret ---
setup; trap teardown EXIT
install_bw_get_stub; write_ref_config ""
assert_eq "$(load)" "ref-user ref-secret" "user and secret from refs"
assert_eq "$(cat "$BW_LOG" | tr '\n' ' ')" "bw://h/username bw://h " "bw-get called with both refs"

# --- inline values win over refs (bw-get not called) ---
: >"$BW_LOG"
write_ref_config "home_HARBOR_USER=alice
home_HARBOR_SECRET=inline-secret"
assert_eq "$(load)" "alice inline-secret" "inline wins over refs"
assert_eq "$(cat "$BW_LOG")" "" "bw-get not called when inline set"

# --- SECRET_FILE wins over SECRET_REF ---
: >"$BW_LOG"
printf 'from-file' >"$TEST_TMP/secret"; chmod 600 "$TEST_TMP/secret"
write_ref_config "home_HARBOR_SECRET_FILE=$TEST_TMP/secret"
assert_eq "$(load)" "ref-user from-file" "SECRET_FILE wins over SECRET_REF"
assert_eq "$(cat "$BW_LOG")" "bw://h/username" "only the user ref resolved"

# --- locked vault → exit 2 with a clear message ---
write_ref_config ""
ec=0; err="$(STUB_BW_LOCKED=1 load 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "2" "locked vault exits 2"
assert_contains "$err" "Bitwarden이 잠겨 있습니다" "locked message"
assert_contains "$err" "bw-unlock" "locked message names bw-unlock"

# --- unresolvable ref → exit 2 naming the ref ---
write_ref_config "home_HARBOR_USER_REF=bw://missing/username"
ec=0; err="$(load 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "2" "bad ref exits 2"
assert_contains "$err" "bw://missing/username" "bad ref named"

# --- bw-get not found → exit 2 ---
write_ref_config ""
ec=0; err="$(HARBOR_BW_GET=/nonexistent/bw-get load 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "2" "missing bw-get exits 2"
assert_contains "$err" "bw-get not found" "missing bw-get message"

# --- default bw-get path follows the real (symlink-resolved) location ---
teardown; setup; trap teardown EXIT
install_bw_get_stub; unset HARBOR_BW_GET
write_ref_config ""
mkdir -p "$TEST_TMP/repo/harbor-ops/bin" "$TEST_TMP/repo/bitwarden-ops/bin" "$TEST_TMP/skills"
cp "$BIN/_common.sh" "$TEST_TMP/repo/harbor-ops/bin/"
cp "$STUB_DIR/bw-get" "$TEST_TMP/repo/bitwarden-ops/bin/bw-get"
ln -s "$TEST_TMP/repo/harbor-ops" "$TEST_TMP/skills/harbor-ops"
assert_eq "$(load "$TEST_TMP/skills/harbor-ops/bin/_common.sh")" "ref-user ref-secret" "default bw-get path via readlink -f"

# --- harbor-push with refs: user in -u, secret only on stdin ---
teardown; setup; trap teardown EXIT
install_bw_get_stub; write_ref_config ""
cat >"$STUB_DIR/docker" <<'DOCKER_EOF'
#!/bin/sh
stdin_data=""
if [ "$1" = "login" ] && [ ! -t 0 ]; then stdin_data="$(cat)"; fi
printf 'argv:%s\nstdin:%s\n' "$*" "$stdin_data" >>"${DOCKER_LOG:?}"
exit 0
DOCKER_EOF
chmod +x "$STUB_DIR/docker"
export DOCKER_LOG="$TEST_TMP/docker.log"; : >"$DOCKER_LOG"
"$BIN/harbor-push" nginx:1.27 mylib/nginx:v1 >/dev/null 2>&1 </dev/null
log="$(cat "$DOCKER_LOG")"
assert_contains "$log" "argv:login harbor.test -u ref-user --password-stdin" "push logs in with ref user"
assert_contains "$log" "stdin:ref-secret" "push passes ref secret on stdin"
assert_not_contains "$(grep '^argv:' "$DOCKER_LOG")" "ref-secret" "secret never in docker argv"
assert_contains "$log" "argv:push harbor.test/mylib/nginx:v1" "push called"

echo "OK test_bw_ref"
