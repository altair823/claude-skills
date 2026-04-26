#!/bin/sh
. "$(dirname "$0")/lib.sh"
export PATH="$BIN:$PATH"

install_docker_stub() {
    cat >"$STUB_DIR/docker" <<'DOCKER_EOF'
#!/bin/sh
log="${DOCKER_LOG:?DOCKER_LOG unset}"
# Read stdin if present (timeout near-zero by reading what's available).
stdin_data=""
if [ ! -t 0 ]; then
    stdin_data="$(cat)"
fi
printf 'argv:%s\nstdin:%s\n---\n' "$*" "$stdin_data" >>"$log"
exit 0
DOCKER_EOF
    chmod +x "$STUB_DIR/docker"
    export DOCKER_LOG="$TEST_TMP/docker.log"
    : >"$DOCKER_LOG"
}

# --- harbor-login: passes user + secret to docker via --password-stdin ---
setup; trap teardown EXIT
write_default_config
install_docker_stub
harbor-login >/dev/null 2>&1
log_content="$(cat "$DOCKER_LOG")"
assert_contains "$log_content" "login" "calls docker login"
assert_contains "$log_content" "harbor.test" "uses host"
assert_contains "$log_content" "-u alice" "user passed"
assert_contains "$log_content" "--password-stdin" "uses --password-stdin"
assert_contains "$log_content" "stdin:secret-1" "secret on stdin"

# --- harbor-login --profile staging ---
teardown; setup; trap teardown EXIT
cat >"$HOME/.config/harbor-ops/config" <<CFG
HARBOR_DEFAULT_PROFILE=prod
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER=alice
prod_HARBOR_SECRET=p1
staging_HARBOR_URL=https://staging.test
staging_HARBOR_USER=bob
staging_HARBOR_SECRET=s1
CFG
chmod 600 "$HOME/.config/harbor-ops/config"
install_docker_stub
harbor-login --profile staging >/dev/null 2>&1
log_content="$(cat "$DOCKER_LOG")"
assert_contains "$log_content" "staging.test" "staging host"
assert_contains "$log_content" "-u bob" "staging user"
assert_contains "$log_content" "stdin:s1" "staging secret"

echo "OK test_harbor_login"
