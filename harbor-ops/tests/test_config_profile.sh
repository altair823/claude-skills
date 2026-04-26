#!/bin/sh
# Test profile resolution and secret resolution in _common.sh::load_profile.
. "$(dirname "$0")/lib.sh"

run_in_subshell() {
    # $1 = setup (write configs, set env), $2 = call (load_profile + echo vars)
    bash -c "
        set -euo pipefail
        export HOME='$HOME'
        export PATH='$PATH'
        . '$BIN/_common.sh'
        $1
        $2
    "
}

# --- subtest: --profile flag wins over env and default ---
setup; trap teardown EXIT

cat >"$HOME/.config/harbor-ops/config" <<CFG
HARBOR_DEFAULT_PROFILE=prod
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER=alice
prod_HARBOR_SECRET=p1
staging_HARBOR_URL=https://staging.test
staging_HARBOR_USER=bob
staging_HARBOR_SECRET=s1
CFG

out="$(run_in_subshell '' "load_profile --profile staging; echo \$HARBOR_URL \$HARBOR_USER \$HARBOR_SECRET")"
assert_eq "$out" "https://staging.test bob s1" "--profile flag wins"

# --- subtest: env wins over default ---
out="$(run_in_subshell 'export HARBOR_PROFILE=staging' "load_profile; echo \$HARBOR_URL")"
assert_eq "$out" "https://staging.test" "HARBOR_PROFILE env wins"

# --- subtest: default used when no flag/env ---
out="$(run_in_subshell '' "load_profile; echo \$HARBOR_URL")"
assert_eq "$out" "https://prod.test" "HARBOR_DEFAULT_PROFILE used"

# --- subtest: sole profile auto-selected when no default set ---
teardown; setup; trap teardown EXIT
cat >"$HOME/.config/harbor-ops/config" <<CFG
solo_HARBOR_URL=https://solo.test
solo_HARBOR_USER=eve
solo_HARBOR_SECRET=z
CFG
out="$(run_in_subshell '' "load_profile; echo \$HARBOR_URL")"
assert_eq "$out" "https://solo.test" "sole profile auto-picked"

# --- subtest: missing config → exit 2 ---
teardown; setup; trap teardown EXIT
ec=0
run_in_subshell '' "load_profile" >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "2" "missing config exits 2"

# --- subtest: missing key in profile → exit 2 ---
teardown; setup; trap teardown EXIT
cat >"$HOME/.config/harbor-ops/config" <<CFG
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER=alice
CFG
ec=0
err="$(run_in_subshell '' "load_profile --profile prod" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "2" "missing SECRET exits 2"
assert_contains "$err" "HARBOR_SECRET" "error names missing key"

# --- subtest: SECRET_FILE used when inline absent ---
teardown; setup; trap teardown EXIT
printf 'from-file' >"$TEST_TMP/secret"
chmod 600 "$TEST_TMP/secret"
cat >"$HOME/.config/harbor-ops/config" <<CFG
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER=alice
prod_HARBOR_SECRET_FILE=$TEST_TMP/secret
CFG
out="$(run_in_subshell '' "load_profile --profile prod; echo \$HARBOR_SECRET")"
assert_eq "$out" "from-file" "SECRET_FILE read"

# --- subtest: unquoted $ in value emits clear hint, exits 2 ---
teardown; setup; trap teardown EXIT
cat >"$HOME/.config/harbor-ops/config" <<'CFG'
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER=robot$myrobot
prod_HARBOR_SECRET=secret-1
CFG
ec=0
err="$(run_in_subshell '' "load_profile --profile prod" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "2" "unquoted \$ exits 2"
assert_contains "$err" "single-quoted" "hint mentions single-quoting"

# --- subtest: properly single-quoted value with $ works ---
teardown; setup; trap teardown EXIT
cat >"$HOME/.config/harbor-ops/config" <<'CFG'
prod_HARBOR_URL=https://prod.test
prod_HARBOR_USER='robot$myrobot'
prod_HARBOR_SECRET='abc$xyz'
CFG
out="$(run_in_subshell '' "load_profile --profile prod; echo \$HARBOR_USER \$HARBOR_SECRET")"
assert_eq "$out" 'robot$myrobot abc$xyz' "single-quoted \$ values preserved"

echo "OK test_config_profile"
