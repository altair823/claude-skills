#!/bin/sh
. "$(dirname "$0")/lib.sh"

run_with_lib() {
    # $1 = cwd, $2 = command
    bash -c "
        set -euo pipefail
        export HOME='$HOME' PATH='$PATH'
        . '$BIN/_common.sh'
        load_profile
        cd '$1'
        $2
    "
}

# --- match in Dockerfile ---
setup; trap teardown EXIT
write_default_config
install_curl_stub
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/Dockerfile" <<DF
FROM harbor.test/myproj/myrepo:v1
DF
out="$(run_with_lib "$TEST_TMP/proj" "detect_project")"
assert_eq "$out" "myproj/myrepo" "Dockerfile match"

# --- match in compose, image: key ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/docker-compose.yml" <<DC
services:
  api:
    image: harbor.test/team-a/api:latest
DC
out="$(run_with_lib "$TEST_TMP/proj" "detect_project")"
assert_eq "$out" "team-a/api" "compose match"

# --- match in k8s yaml ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/deploy.yaml" <<K8S
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: c
          image: harbor.test/billing/worker:v2.3.4
K8S
out="$(run_with_lib "$TEST_TMP/proj" "detect_project")"
assert_eq "$out" "billing/worker" "k8s yaml match"

# --- walk up to git root ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/repo/sub/deeper"
( cd "$TEST_TMP/repo" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init )
cat >"$TEST_TMP/repo/Dockerfile" <<DF
FROM harbor.test/upstream/img:v1
DF
out="$(run_with_lib "$TEST_TMP/repo/sub/deeper" "detect_project")"
assert_eq "$out" "upstream/img" "walks up to git root"

# --- HARBOR_NO_DETECT skips ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/Dockerfile" <<DF
FROM harbor.test/myproj/myrepo:v1
DF
ec=0
err="$(run_with_lib "$TEST_TMP/proj" "HARBOR_NO_DETECT=1 detect_project" 2>&1 >/dev/null)" || ec=$?
assert_exit_code "$ec" "3" "no-detect skips and errors"

# --- host mismatch → no match → exit 3 ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/Dockerfile" <<DF
FROM other-registry.example.com/x/y:v1
DF
ec=0
run_with_lib "$TEST_TMP/proj" "detect_project" >/dev/null 2>&1 || ec=$?
assert_exit_code "$ec" "3" "host mismatch exits 3"

# --- lexicographic file order: aaa.yaml beats zzz.yaml ---
teardown; setup; trap teardown EXIT
write_default_config
mkdir -p "$TEST_TMP/proj"
cat >"$TEST_TMP/proj/zzz.yaml" <<Y
image: harbor.test/last/one:v1
Y
cat >"$TEST_TMP/proj/aaa.yaml" <<Y
image: harbor.test/first/one:v1
Y
out="$(run_with_lib "$TEST_TMP/proj" "detect_project")"
assert_eq "$out" "first/one" "lexicographic file order"

echo "OK test_project_detect"
