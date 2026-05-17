#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_backend 2>/dev/null || true
export PVE_TOKEN="stub-token-value"

# 테이블을 셸로 로드해 키를 열거 (probe 패턴 재사용).
cat > /tmp/_tblprobe.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
case "$1" in
  keys)    for k in "${!ACTIONS[@]}"; do echo "$k ${ACTIONS[$k]}"; done ;;
  aliases) for k in "${!ACTION_ALIASES[@]}"; do echo "$k ${ACTION_ALIASES[$k]}"; done ;;
esac
EOF
cp /tmp/_tblprobe.sh bin/_tblprobe.sh
trap 'rm -f bin/_tblprobe.sh' EXIT

# Direction 1: 모든 비-safe 액션은 backend 에서 라우팅되어 "no backend
# mapping" 으로 떨어지지 않는다 (dry-run 안전 계약 하에).
while read -r act grade _trans; do
  [[ "$grade" == "safe" ]] && continue
  o="$(bin/_backend "$act" vm-100 --dry-run -- probe-arg 2>&1 || true)"
  assert_not_contains "$o" "no backend mapping for action '$act'" \
    "table action '$act' is backend-routed"
done < <(bash bin/_tblprobe.sh keys)

# Direction 2: backend 가 디스패치하는 모든 mutating verb 는 테이블에 있다.
tbl_keys="$(bash bin/_tblprobe.sh keys | awk '{print $1}' | sort -u | tr '\n' ' ')"
backend_verbs="$(grep -oE '[a-z][a-z-]*:\*' bin/_backend | sed 's/:\*$//' | sort -u)"
for v in $backend_verbs; do
  case " $tbl_keys " in
    *" $v "*) echo "  ok: backend verb '$v' present in ACTIONS" ;;
    *) echo "  FAIL: backend verb '$v' missing from ACTIONS table"; exit 1 ;;
  esac
done

# Direction 3: 모든 별칭은 실재하는 ACTIONS 키를 가리킨다.
while read -r alias target; do
  case " $tbl_keys " in
    *" $target "*) echo "  ok: alias '$alias'→'$target' targets a real action" ;;
    *) echo "  FAIL: alias '$alias' targets non-existent action '$target'"; exit 1 ;;
  esac
done < <(bash bin/_tblprobe.sh aliases)

finish; echo "PASS test_action_table"
