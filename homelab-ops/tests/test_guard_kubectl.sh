#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend bin/_classify bin/kube 2>/dev/null || true
export HOMELAB_SESSION_ID="guard-kubectl-sess"

cat > /tmp/fake-backend <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *--dry-run* ]]; then echo "DRYRUN action=$1 target=$2 extra=$*"; exit 0; fi
echo "BACKEND action=$1 target=$2 extra=$*"; exit 0
EOF
chmod +x /tmp/fake-backend
export HOMELAB_BACKEND=/tmp/fake-backend
: > logs/audit.jsonl

# ── --plan: kubeconfig ref 가 출력된다 (k8s-cluster 엔트리만) ──────────
plan_dev="$(bin/guard --plan kubectl k8s-dev 2>&1)"
assert_contains "$plan_dev" "HL_KUBECONFIG=bw://kubeconfig-k8s-dev/notes" \
  "--plan kubectl k8s-dev → HL_KUBECONFIG ref"
assert_not_contains "$plan_dev" "PVE_TOKEN=" "--plan kubectl: PVE_TOKEN 미출력"
assert_not_contains "$plan_dev" "HL_SSH_KEY=" "--plan kubectl: HL_SSH_KEY 미출력"

# ── --plan: 비-k8s-cluster 타깃은 거부 ─────────────────────────────────
assert_status 1 'bin/guard --plan kubectl vm-100' \
  "--plan kubectl on vm target dies (kind 검증)"

# ── 자격 게이트: HL_KUBECONFIG 없으면 exit 3 ──────────────────────────
assert_status 3 'env -u HL_KUBECONFIG bin/guard kubectl k8s-dev -- get pods -A' \
  "kubectl without HL_KUBECONFIG exits 3"

# ── 동적 등급: read → caution (dev env, no critical) → 즉시 실행 ──────
out="$(HL_KUBECONFIG=x bin/guard kubectl k8s-dev -- get pods -A)"
assert_contains "$out" "BACKEND action=kubectl" "caution kube-ro 즉시 실행"
rec="$(tail -1 logs/audit.jsonl)"
assert_eq "caution" "$(jq -r .grade <<<"$rec")" "kubectl get caution 감사"
assert_eq "kube" "$(jq -r .via <<<"$rec")" "via=kube 감사"
assert_eq "caution" "$(jq -r .classify_grade <<<"$rec")" "classify_grade 감사"
assert_eq "kube-ro:get" "$(jq -r .classify_rule <<<"$rec")" "classify_rule 감사"

# ── 동적 등급: write → destructive → DRY-RUN + classify_rule 표기 ─────
set +e
out_w="$(HL_KUBECONFIG=x bin/guard kubectl k8s-dev -- apply -f x.yaml 2>&1)"
rc=$?
set -e
assert_eq "10" "$rc" "kubectl apply (dev) destructive → exit 10 without --approve"
assert_contains "$out_w" "DRY-RUN [destructive] kubectl k8s-dev" "kubectl apply dry-run 헤더"
assert_contains "$out_w" "classify_rule: kube-write:apply" "dry-run 에 classify_rule 표기"

# ── critical 승급: prod cluster + read → destructive ─────────────────
set +e
out_p="$(HL_KUBECONFIG=x bin/guard kubectl k8s-prod -- get pods -A 2>&1)"
rc_p=$?
set -e
assert_eq "10" "$rc_p" "kubectl get on critical-prod → destructive → exit 10"
assert_contains "$out_p" "DRY-RUN [destructive]" "prod-critical caution → destructive 승급"
# --approve 시 실행
out_pa="$(HL_KUBECONFIG=x bin/guard kubectl k8s-prod --approve -- get pods -A 2>&1)"
assert_contains "$out_pa" "BACKEND action=kubectl" "prod-critical 승급 + --approve → 실행"

# ── --grade-override 상향 ────────────────────────────────────────────
set +e
out_ov="$(HL_KUBECONFIG=x bin/guard kubectl k8s-dev --grade-override destructive -- get pods 2>&1)"
rc_ov=$?
set -e
assert_eq "10" "$rc_ov" "override 상향 → exit 10"
assert_contains "$out_ov" "kube-ro:get+override" "override 표기 in classify_rule"

# ── --grade-override 하향 거부 ───────────────────────────────────────
assert_status 1 'HL_KUBECONFIG=x bin/guard kubectl k8s-dev --grade-override safe -- get pods' \
  "override 하향(safe) 거부"

# ── 인자 없음 거부 ───────────────────────────────────────────────────
assert_status 1 'HL_KUBECONFIG=x bin/guard kubectl k8s-dev' \
  "kubectl 인자 없음 거부"
assert_status 1 'HL_KUBECONFIG=x bin/guard kubectl k8s-dev --' \
  "kubectl '--' 만 있고 인자 없음 거부"

# ── 누락 타깃도 감사 기록 (Critical 2 parity) ────────────────────────
: > logs/audit.jsonl
HL_KUBECONFIG=x bin/guard kubectl NON-EXIST-CLUSTER -- get pods 2>&1 || true
assert_eq "kubectl" "$(tail -1 logs/audit.jsonl | jq -r '.action // empty')" \
  "missing-target: audit record present with action=kubectl"

# ── 실 _backend 라우팅 확인: kubectl → bin/kube ────────────────────
# k8s-dev 에 dev env(env=dev) 라 caution 자동실행. _backend 가 bin/kube 호출,
# bin/kube 가 stub kubectl 호출 → KUBECTL-STUB 문자열 검출.
export HOMELAB_BACKEND=bin/_backend
out_real="$(HL_KUBECONFIG="apiVersion: v1
clusters: []
contexts: []
kind: Config" bin/guard kubectl k8s-dev -- get pods 2>&1 || true)"
assert_contains "$out_real" "KUBECTL-STUB args=[get pods]" "kubectl 라우팅: backend → kube → kubectl stub"

# 비-k8s-cluster 타깃을 강제로 kubectl action 으로 호출 → backend 가 거부 (kind 가드)
export HOMELAB_BACKEND=bin/_backend
set +e
out_bad="$(HL_KUBECONFIG=x bin/guard kubectl vm-100 -- get pods 2>&1)"
rc_bad=$?
set -e
[[ $rc_bad -ne 0 ]] && echo "  ok: kubectl on non-cluster target rejected (backend kind guard)" \
  || { echo "  FAIL: kubectl on vm-100 should have been rejected"; _FAILS=$((_FAILS+1)); }

finish; echo "PASS test_guard_kubectl"
