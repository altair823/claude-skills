#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/guard bin/_backend bin/_classify 2>/dev/null || true
export HOMELAB_SESSION_ID="exec-sess"
cat > /tmp/fake-backend <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *--dry-run* ]]; then echo "DRYRUN action=$1 target=$2 extra=$*"; exit 0; fi
echo "BACKEND action=$1 target=$2 extra=$*"; exit 0
EOF
chmod +x /tmp/fake-backend
export HOMELAB_BACKEND=/tmp/fake-backend HL_SSH_KEY=x PVE_TOKEN=x
: > logs/audit.jsonl

# 동적 등급: read-only → caution(비-prod 즉시 실행)
o="$(bin/guard exec lab-vm-900 -- --via guest cat /etc/os-release)"
assert_contains "$o" "BACKEND action=exec" "exec caution(ro) 즉시 실행"
assert_eq "caution" "$(tail -1 logs/audit.jsonl | jq -r .grade)" "ro 명령 caution 감사"

# 미지 명령 → destructive(approve 없으면 exit 10)
assert_status 10 "bin/guard exec lab-vm-900 -- --via guest frobnicate" "미지 명령 → destructive, --approve 없으면 exit 10"
o2="$(bin/guard exec lab-vm-900 -- --via guest frobnicate 2>&1 || true)"
assert_contains "$o2" "fallback-deny" "dry-run impact 에 classify_rule 표기"

# --grade-override 는 상향만: caution 명령을 destructive 로 승격
assert_status 10 "bin/guard exec lab-vm-900 --grade-override destructive -- --via guest cat /x" "override 상향 → exit 10"

# 하향 인자(safe/caution) 거부 → die 기본 exit code = 1
assert_status 1 "bin/guard exec lab-vm-900 --grade-override safe -- --via guest frobnicate" "override 하향 거부(exit 1)"

assert_status 1 "bin/guard exec lab-vm-900 -- --via docker cat /etc/os-release" "잘못된 --via 는 실행 전 거부(die exit 1)"
assert_status 1 "bin/guard exec lab-vm-900 -- --via guest" "exec --via 만 있고 명령 없음 → 거부"

# node transport 라우팅 + pve transport 라우팅이 backend 로 흐른다 (실 backend, dry-run 경로)
# vm-100(prod env): caution+prod → needs_approval=1 → DRY-RUN path through real backend.
# _backend exec arm 이 출력하는 "via=node" / "via=pve" 문자열로 via 미스라우팅을 검출.
# (guard 자체 dry-run 요약에는 "via=" 가 없으므로 backend 도달 여부가 명확히 구분됨.)
export HOMELAB_BACKEND=bin/_backend
on="$(bin/guard exec vm-100 -- --via node qm config 301 2>&1 || true)"
assert_contains "$on" "via=node" "node 라우팅: backend exec arm 이 via=node 로 실행"
op="$(bin/guard exec vm-100 -- --via pve --method GET --path /version 2>&1 || true)"
assert_contains "$op" "via=pve" "pve 라우팅: backend exec arm 이 via=pve 로 실행"
export HOMELAB_BACKEND=/tmp/fake-backend
# 감사: via/classify_grade/classify_rule 항상 존재
: > logs/audit.jsonl
bin/guard exec lab-vm-900 --approve -- --via guest ls / >/dev/null 2>&1 || true
rec="$(tail -1 logs/audit.jsonl)"
assert_eq "guest" "$(jq -r .via <<<"$rec")" "via 감사"
assert_eq "caution" "$(jq -r .classify_grade <<<"$rec")" "classify_grade 감사"
assert_eq "ro-allowlist:ls" "$(jq -r .classify_rule <<<"$rec")" "classify_rule 감사"

finish; echo "PASS test_exec"
