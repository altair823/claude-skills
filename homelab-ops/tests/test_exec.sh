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

finish; echo "PASS test_exec"
