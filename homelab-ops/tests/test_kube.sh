#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/kube 2>/dev/null || true

# ── gate: HL_KUBECONFIG 없으면 exit 3 ────────────────────────────────────
assert_status 3 'env -u HL_KUBECONFIG bin/kube k8s-dev -- get pods' \
  "kube without HL_KUBECONFIG exits 3"

# ── kind 검증: k8s-cluster 아니면 die ───────────────────────────────────
assert_status 1 'env HL_KUBECONFIG=dummy bin/kube vm-100 -- get pods' \
  "kube on non-cluster target (vm) dies"
assert_status 1 'env HL_KUBECONFIG=dummy bin/kube pve-01 -- get pods' \
  "kube on non-cluster target (proxmox-host) dies"

# ── --kubeconfig 인자 거부 (자격 단일 출처) ─────────────────────────────
assert_status 1 'env HL_KUBECONFIG=dummy bin/kube k8s-dev -- --kubeconfig=/tmp/x get pods' \
  "kube refuses --kubeconfig= injection"
assert_status 1 'env HL_KUBECONFIG=dummy bin/kube k8s-dev -- --kubeconfig /tmp/x get pods' \
  "kube refuses --kubeconfig injection (separate value)"

# ── 실 경로: 더미 kubeconfig 가 stub kubectl 로 흘러간다 ────────────────
out="$(HL_KUBECONFIG="apiVersion: v1
clusters: []
contexts: []
kind: Config" bin/kube k8s-dev -- get pods -A)"
assert_contains "$out" "KUBECTL-STUB args=[get pods -A]" "kube args forwarded to kubectl"
assert_contains "$out" "kubeconfig_path=" "kubeconfig tmpfile path set"
# tmpfile 모드 0600 (다른 사용자 가시성 차단)
assert_contains "$out" "kubeconfig_mode=600" "kubeconfig tmpfile is 0600"

# ── tmpfile 청소: kube 종료 후 tmpfile 부재 확인 ────────────────────────
# kubectl stub 이 KUBECONFIG 경로를 보고하므로, 종료 후 그 경로가 없어야 한다.
tmppath="$(HL_KUBECONFIG="apiVersion: v1
clusters: []
contexts: []
kind: Config" bin/kube k8s-dev -- get pods 2>/dev/null | sed -n 's/.*kubeconfig_path=\([^ ]*\).*/\1/p')"
[[ -n "$tmppath" && ! -e "$tmppath" ]] && echo "  ok: kubeconfig tmpfile removed on exit" \
  || { echo "  FAIL: kubeconfig tmpfile leaked: $tmppath"; _FAILS=$((_FAILS+1)); }

# ── 자격이 argv 에 누출되지 않는다(보안 회귀 가드) ────────────────────
# stub 은 인자를 그대로 echo 한다. HL_KUBECONFIG 값 자체가 echo 출력에 등장하면 안 됨.
out2="$(HL_KUBECONFIG="VERYSECRETKUBECONFIG123" bin/kube k8s-dev -- get pods)"
assert_not_contains "$out2" "VERYSECRETKUBECONFIG123" "kubeconfig secret 이 stub argv 에 누출되지 않는다"

finish; echo "PASS test_kube"
