#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_backend 2>/dev/null || true
export PVE_TOKEN="stub-token-value"  # 방어적 설정: dry-run 시 bin/pve 는 호출되지 않지만 set -u 환경에서 guard/_backend 가 변수 참조 시 오류 없이 동작하도록 보장

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
[[ -n "$(bash bin/_tblprobe.sh keys)" ]] || { echo "  FAIL: _tblprobe.sh produced no ACTIONS keys"; exit 1; }

# Direction 1: 모든 비-safe 액션은 backend 에서 라우팅되어 "no backend
# mapping" 으로 떨어지지 않는다 (dry-run 안전 계약 하에).
# dynamic 등급 센티넬(exec 등)은 backend arm 이 나중 태스크에서 추가되므로 제외.
while read -r act grade _trans; do
  [[ "$grade" == "safe" ]] && continue
  [[ "$grade" == "dynamic" ]] && continue   # exec: dynamic arm 은 Plan Task 6 에서 추가
  o="$(bin/_backend "$act" vm-100 --dry-run -- probe-arg 2>&1 || true)"
  assert_not_contains "$o" "no backend mapping for action '$act'" \
    "table action '$act' is backend-routed"
done < <(bash bin/_tblprobe.sh keys)

# Direction 2: backend 가 디스패치하는 모든 mutating verb 는 테이블에 있다.
tbl_keys="$(bash bin/_tblprobe.sh keys | awk '{print $1}' | sort -u | tr '\n' ' ')"
backend_verbs="$(grep -oE '[a-z][a-z-]*:\*' bin/_backend | sed 's/:\*$//' | sort -u)"
[[ -n "$backend_verbs" ]] || { echo "  FAIL: no backend verbs extracted from bin/_backend — grep pattern or _backend arm syntax changed"; exit 1; }
for v in $backend_verbs; do
  case " $tbl_keys " in
    *" $v "*) echo "  ok: backend verb '$v' present in ACTIONS" ;;
    *) echo "  FAIL: backend verb '$v' missing from ACTIONS table"; _FAILS=$((_FAILS+1)) ;;
  esac
done

# Direction 3: 모든 별칭은 실재하는 ACTIONS 키를 가리킨다.
while read -r al target; do
  case " $tbl_keys " in
    *" $target "*) echo "  ok: alias '$al'→'$target' targets a real action" ;;
    *) echo "  FAIL: alias '$al' targets non-existent action '$target'"; _FAILS=$((_FAILS+1)) ;;
  esac
done < <(bash bin/_tblprobe.sh aliases)

# exec 는 동적 등급 센티넬(첫 토큰 dynamic), 정적 verb 엔 dynamic 토큰 없음.
exec_spec="$(bash -c 'source bin/_lib.sh; echo "${ACTIONS[exec]:-MISSING}"')"
assert_eq "dynamic exec" "$exec_spec" "ACTIONS[exec]=dynamic exec (동적 센티넬)"
while read -r act spec; do
  [[ "$act" == "exec" ]] && continue
  case "$spec" in
    dynamic*) echo "  FAIL: 정적 verb '$act' 에 dynamic 토큰"; _FAILS=$((_FAILS+1)) ;;
    *) : ;;
  esac
done < <(bash bin/_tblprobe.sh keys)
# 큐레이티드 신규 verb 등급·transport 고정
for kv in "service:caution ssh" "logs:caution ssh" "pkg-update:caution ssh" "reboot:caution ssh"; do
  k="${kv%%:*}"; want="${kv#*:}"
  got="$(bash -c "source bin/_lib.sh; echo \"\${ACTIONS[$k]:-MISSING}\"")"
  assert_eq "$want" "$got" "ACTIONS[$k]=$want"
done

finish; echo "PASS test_action_table"
