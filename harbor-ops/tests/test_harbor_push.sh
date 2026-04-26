#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

# Docker stub that logs argv, stdin, and DOCKER_CONFIG. Returns 0 always.
install_docker_stub() {
    cat >"$STUB_DIR/docker" <<'DOCKER_EOF'
#!/bin/sh
log="${DOCKER_LOG:?DOCKER_LOG unset}"
stdin_data=""
if [ ! -t 0 ]; then
    stdin_data="$(cat)"
fi
printf 'argv:%s\nstdin:%s\nDOCKER_CONFIG:%s\n---\n' \
    "$*" "$stdin_data" "${DOCKER_CONFIG:-<unset>}" >>"$log"
exit 0
DOCKER_EOF
    chmod +x "$STUB_DIR/docker"
    export DOCKER_LOG="$TEST_TMP/docker.log"
    : >"$DOCKER_LOG"
}

# --- happy path: nginx push ---
setup; trap teardown EXIT
write_default_config; install_docker_stub
# Pre-create user's docker config to verify it stays untouched.
mkdir -p "$HOME/.docker"
echo '{"existing":"untouched"}' >"$HOME/.docker/config.json"

harbor-push nginx:1.27 mylib/nginx:v1 >/dev/null 2>&1
log="$(cat "$DOCKER_LOG")"

# Assert all three invocations happened in order
assert_contains "$log" "login harbor.test -u alice --password-stdin" "docker login call"
assert_contains "$log" "stdin:secret-1" "secret on stdin"
assert_contains "$log" "tag nginx:1.27 harbor.test/mylib/nginx:v1" "docker tag call"
assert_contains "$log" "push harbor.test/mylib/nginx:v1" "docker push call"

# DOCKER_CONFIG must be set, and not equal to user's $HOME/.docker
docker_config_used="$(grep '^DOCKER_CONFIG:' "$DOCKER_LOG" | head -1 | sed 's/^DOCKER_CONFIG://')"
assert_not_contains "$docker_config_used" "$HOME/.docker" "DOCKER_CONFIG isolated from user dir"

# User's docker config file must be untouched
assert_eq "$(cat "$HOME/.docker/config.json")" '{"existing":"untouched"}' "user docker config preserved"

# Temp DOCKER_CONFIG dir must be cleaned up (no longer exists)
[ ! -d "$docker_config_used" ] || { echo "FAIL: tmp dir $docker_config_used not cleaned up" >&2; exit 1; }

# --- failure: docker push fails → tmp dir still cleaned + non-zero exit ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/docker" <<'DOCKER_EOF'
#!/bin/sh
log="${DOCKER_LOG:?DOCKER_LOG unset}"
printf 'argv:%s\nDOCKER_CONFIG:%s\n---\n' "$*" "${DOCKER_CONFIG:-<unset>}" >>"$log"
case "$1" in
    push) exit 7 ;;
    *) exit 0 ;;
esac
DOCKER_EOF
chmod +x "$STUB_DIR/docker"
export DOCKER_LOG="$TEST_TMP/docker.log"
: >"$DOCKER_LOG"

ec=0
harbor-push nginx:1.27 mylib/nginx:v1 >/dev/null 2>&1 || ec=$?
[ "$ec" -ne 0 ] || { echo "FAIL: expected non-zero exit on push failure" >&2; exit 1; }

docker_config_used="$(grep '^DOCKER_CONFIG:' "$DOCKER_LOG" | head -1 | sed 's/^DOCKER_CONFIG://')"
[ ! -d "$docker_config_used" ] || { echo "FAIL: tmp dir $docker_config_used leaked on push failure" >&2; exit 1; }

# --- arg validation: missing destination → exit 4 ---
teardown; setup; trap teardown EXIT
write_default_config; install_docker_stub
ec=0
harbor-push nginx:1.27 2>/dev/null || ec=$?
assert_exit_code "$ec" "4" "missing dest exits 4"

echo "OK test_harbor_push"
