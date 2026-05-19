# homelab-ops 범용 exec hatch + 큐레이티드 운영 verb 묶음 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** homelab-ops에 큐레이티드 운영 verb(service/logs/disk-grow --to/pkg-update/reboot)와, 보수적 휴리스틱 분류기로 동적 등급되는 단일 `exec` 범용 hatch를 추가한다.

**Architecture:** 단일 출처 `ACTIONS` 테이블에 `[exec]="dynamic exec"` 센티넬 1행 + 정적 큐레이티드 행들을 추가한다. `action_grade`/`op_transport`가 첫 토큰 `dynamic`을 만나면 순수 분류기 모듈 `bin/_classify`에 위임한다. 분류기는 read-only allowlist 외 전부 destructive로 폴백(fail-closed)한다. guard-only mutation·포렌식 감사·bw:// 자격·패리티 테스트 불변식은 보존한다.

**Tech Stack:** bash, jq. 테스트는 `tests/test_*.sh` (source `tests/lib.sh`; `assert_eq`/`assert_contains`/`assert_not_contains`/`assert_status`/`finish`). 회귀: `bash tests/run.sh`. 작업 디렉토리: `/home/altair823/claude-skills/homelab-ops`. 브랜치: `feat/homelab-ops-exec-and-curated-verbs` (이미 생성·spec 커밋됨).

스펙: `docs/superpowers/specs/2026-05-19-homelab-ops-exec-and-curated-verbs-design.md`

---

## File Structure

- **Modify** `homelab-ops/bin/_lib.sh` — `ACTIONS`에 `exec`+큐레이티드 행 추가; `action_grade`/`op_transport`에 `dynamic` 첫-토큰 분기 추가.
- **Create** `homelab-ops/bin/_classify` — 순수 분류기. 입력 `<via> -- <argv...>` 또는 `pve --method M --path P`, 출력 `grade<TAB>rule`. 외부 의존 없음(테스트 용이).
- **Modify** `homelab-ops/bin/_backend` — `exec:*` arm + 큐레이티드 arm(`service`/`logs`/`pkg-update`/`reboot`) 추가; `disk-grow:*` arm에 `--to`(qm resize 선행) 추가.
- **Modify** `homelab-ops/bin/guard` — `exec` 시 `_classify`로 동적 등급; `--plan`이 `exec`의 `--via`를 읽어 transport 결정; 감사 레코드에 `via`/`classify_grade`/`classify_rule` 추가.
- **Modify** `homelab-ops/tests/test_action_table.sh` — `exec=dynamic` + "정적 verb엔 dynamic 토큰 없음" 단언.
- **Create** `homelab-ops/tests/test_classify.sh` — 분류기 코퍼스.
- **Create** `homelab-ops/tests/test_exec.sh` — exec 등급/transport/dry-run/감사/override.
- **Create** `homelab-ops/tests/test_curated_verbs.sh` — service/logs/pkg-update/reboot.
- **Modify** `homelab-ops/tests/test_disk_grow.sh` — `--to` resize·축소거부·하위호환.
- **Modify** `homelab-ops/SKILL.md` — 신규 verb 문서 + TODO 항목 닫음 명시.

모든 단계 종료 시 `bash tests/run.sh`가 `ALL TESTS PASSED`여야 한다.

---

## Phase 1 — 단일-출처 `dynamic` 훅 + 테이블 행

### Task 1: ACTIONS 테이블에 exec + 큐레이티드 행 추가

**Files:**
- Modify: `homelab-ops/bin/_lib.sh:61-71` (declare -gA ACTIONS 블록)
- Test: `homelab-ops/tests/test_action_table.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_action_table.sh` 끝의 `finish; echo "PASS test_action_table"` 직전에 삽입:

```bash
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
for kv in "service:caution guest" "logs:caution ssh" "pkg-update:caution ssh" "reboot:caution guest"; do
  k="${kv%%:*}"; want="${kv#*:}"
  got="$(bash -c "source bin/_lib.sh; echo \"\${ACTIONS[$k]:-MISSING}\"")"
  assert_eq "$want" "$got" "ACTIONS[$k]=$want"
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd homelab-ops && bash tests/test_action_table.sh`
Expected: FAIL — `ACTIONS[exec]=dynamic exec` 단언에서 `MISSING`.

- [ ] **Step 3: Write minimal implementation** — `bin/_lib.sh`의 `declare -gA ACTIONS=( ... )` 블록에 행 추가 (기존 행은 그대로, 닫는 `)` 앞에 삽입):

```bash
  [pkg-update]="caution ssh"
  [service]="caution guest"   [logs]="caution ssh"   [reboot]="caution guest"
  [exec]="dynamic exec"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd homelab-ops && bash tests/test_action_table.sh`
Expected: `PASS test_action_table` (단, Direction 2에서 backend 미구현 verb 경고가 날 수 있음 → Task 다음 단계에서 해소되므로 이 시점엔 신규 verb를 backend arm에 아직 안 넣었다면 _backend에 임시 no-op이 아니라 Phase 3/4에서 채운다. Direction 2는 "backend가 디스패치하는 verb는 테이블에 있어야 한다"는 방향이라 테이블에만 있고 backend에 없는 것은 통과한다 — 실패하지 않음).

- [ ] **Step 5: Commit**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_lib.sh homelab-ops/tests/test_action_table.sh
git commit -m "feat(homelab-ops): ACTIONS 에 exec(dynamic) + 큐레이티드 verb 행 추가"
```

### Task 2: action_grade / op_transport 의 dynamic 분기

**Files:**
- Modify: `homelab-ops/bin/_lib.sh:98-118` (`action_grade`, `op_transport`)
- Test: `homelab-ops/tests/test_lib.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_lib.sh` 끝(있다면 `finish` 직전, 없으면 파일 끝에 `source tests/lib.sh` 가정하고)에 추가:

```bash
# dynamic 첫 토큰: action_grade 는 리터럴 'dynamic' 을 반환(guard 가 _classify 로 위임).
g="$(bash -c 'source bin/_lib.sh; action_grade exec')"
assert_eq "dynamic" "$g" "action_grade exec → dynamic (정적 산출 안 함)"
# op_transport 도 dynamic 토큰이면 'dynamic' 을 반환(실 transport 는 --via 로 guard 결정).
t="$(bash -c 'source bin/_lib.sh; op_transport exec vm')"
assert_eq "dynamic" "$t" "op_transport exec → dynamic"
# 정적 verb 회귀
assert_eq "destructive" "$(bash -c 'source bin/_lib.sh; action_grade disk-grow')" "정적 disk-grow 회귀"
assert_eq "host-ssh" "$(bash -c 'source bin/_lib.sh; op_transport disk-grow vm')" "정적 disk-grow transport 회귀"
```

(만약 `tests/test_lib.sh`에 `finish` 호출이 있으면 그 줄 직전에 삽입.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd homelab-ops && bash tests/test_lib.sh`
Expected: FAIL — `action_grade exec`가 `destructive`(spec=`dynamic exec`, `${spec%% *}`=`dynamic`이므로 실제론 `dynamic`을 반환할 수도 있으나, 현재 코드 경로 확인용. op_transport는 `dynamic` 케이스가 없어 `none` 반환 → FAIL 확정).

- [ ] **Step 3: Write minimal implementation** — `bin/_lib.sh`:

`action_grade`는 이미 `echo "${spec%% *}"`이므로 `dynamic exec`의 첫 토큰 `dynamic`을 자연히 반환한다(수정 불필요 — 단 주석만 보강). `op_transport`의 `case "$t"` 첫 분기에 `dynamic` 추가:

```bash
  case "$t" in
    dynamic) echo dynamic ;;
    none|pve|ssh|host-ssh|pdm) echo "$t" ;;
    guest) case "$kind" in proxmox-host|vm|lxc) echo pve ;; *) echo ssh ;; esac ;;
    *) echo none ;;
  esac
```

그리고 `action_grade` 함수 주석에 한 줄 추가: `# 'dynamic' 첫 토큰(exec)이면 'dynamic' 을 반환 — guard 가 bin/_classify 로 동적 위임한다.`

- [ ] **Step 4: Run test to verify it passes**

Run: `cd homelab-ops && bash tests/test_lib.sh && bash tests/test_action_table.sh`
Expected: 둘 다 PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_lib.sh homelab-ops/tests/test_lib.sh
git commit -m "feat(homelab-ops): action_grade/op_transport 에 dynamic 토큰 분기"
```

---

## Phase 2 — 분류기 모듈 `bin/_classify`

### Task 3: _classify 골격 + 메타문자/fallback-deny

**Files:**
- Create: `homelab-ops/bin/_classify`
- Test: `homelab-ops/tests/test_classify.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_classify.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_classify 2>/dev/null || true
C() { bin/_classify "$@"; }   # prints "grade<TAB>rule"

# 메타문자 → destructive
assert_eq "destructive	metachar" "$(C guest -- sh -c 'rm -rf /')" "sh -c → metachar"
assert_eq "destructive	metachar" "$(C guest -- ls\; rm)" "세미콜론 → metachar"
assert_eq "destructive	metachar" "$(C node -- cat /etc/x \&\& reboot)" "&& → metachar"
# 미지 바이너리 → fallback-deny
assert_eq "destructive	fallback-deny" "$(C guest -- frobnicate --now)" "미지 바이너리 → fallback-deny"
finish; echo "PASS test_classify"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd homelab-ops && bash tests/test_classify.sh`
Expected: FAIL — `bin/_classify` 없음 ("command not found" 또는 chmod 실패).

- [ ] **Step 3: Write minimal implementation** — `bin/_classify` 생성:

```bash
#!/usr/bin/env bash
# 순수 분류기: exec 의 동적 등급 단일 출처. 외부 의존 없음.
# 사용:
#   _classify <guest|node> -- <argv...>
#   _classify pve --method <M> --path <P> [--body ...]
# 출력(stdout): "<grade>\t<rule>"  grade ∈ {caution,destructive} (safe 없음)
set -euo pipefail
via="${1:?_classify: via required}"; shift

emit() { printf '%s\t%s\n' "$1" "$2"; exit 0; }

# pve transport: GET 만 caution, 그 외 destructive
if [[ "$via" == pve ]]; then
  method=""
  while [[ $# -gt 0 ]]; do
    case "$1" in --method) method="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  case "$method" in
    GET) emit caution pve-get ;;
    *)   emit destructive pve-write ;;
  esac
fi

# guest/node: argv 는 '--' 다음
[[ "${1:-}" == "--" ]] && shift || true
(( $# > 0 )) || emit destructive fallback-deny

# 메타문자/셸 차단: 어떤 토큰이든 셸 체이닝·리다이렉트·치환·개행 포함,
# 또는 첫 토큰이 셸 인터프리터(-c 동반)면 destructive.
for tok in "$@"; do
  case "$tok" in
    *';'*|*'|'*|*'&'*|*'$'*|*'`'*|*'('*|*')'*|*'<'*|*'>'*|*$'\n'*)
      emit destructive metachar ;;
  esac
done
case "$1" in
  sh|bash|dash|zsh|ash) for a in "$@"; do [[ "$a" == "-c" ]] && emit destructive metachar; done ;;
esac

# (Task 4 에서 read-only allowlist 채움) — 현재는 전부 fallback-deny
emit destructive fallback-deny
```

```bash
chmod +x bin/_classify
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd homelab-ops && bash tests/test_classify.sh`
Expected: `PASS test_classify`.

- [ ] **Step 5: Commit**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_classify homelab-ops/tests/test_classify.sh
git commit -m "feat(homelab-ops): _classify 골격 — metachar/pve-write/fallback-deny"
```

### Task 4: read-only allowlist → caution

**Files:**
- Modify: `homelab-ops/bin/_classify` (마지막 `emit destructive fallback-deny` 직전)
- Test: `homelab-ops/tests/test_classify.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_classify.sh`의 `finish;` 직전에 추가:

```bash
# 단순 read-only 바이너리 → caution
assert_eq "caution	ro-allowlist:cat" "$(C guest -- cat /etc/os-release)" "cat → caution"
assert_eq "caution	ro-allowlist:journalctl" "$(C node -- journalctl -u sshd -n 50)" "journalctl → caution"
# 서브커맨드 한정 화이트리스트
assert_eq "caution	ro-allowlist:systemctl-status" "$(C guest -- systemctl status sshd)" "systemctl status → caution"
assert_eq "destructive	fallback-deny" "$(C guest -- systemctl restart sshd)" "systemctl restart → fallback-deny"
assert_eq "caution	ro-allowlist:qm-config" "$(C node -- qm config 301)" "qm config → caution"
assert_eq "destructive	fallback-deny" "$(C node -- qm stop 301)" "qm stop → fallback-deny"
# pve GET 회귀
assert_eq "caution	pve-get" "$(C pve --method GET --path /nodes/x/qemu)" "pve GET → caution"
assert_eq "destructive	pve-write" "$(C pve --method POST --path /nodes/x/qemu/301/status/stop)" "pve POST → pve-write"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd homelab-ops && bash tests/test_classify.sh`
Expected: FAIL — `cat → caution`이 `destructive fallback-deny` 반환.

- [ ] **Step 3: Write minimal implementation** — `bin/_classify`의 `# (Task 4 ...)` 주석과 마지막 `emit destructive fallback-deny`를 다음으로 교체:

```bash
# read-only allowlist (첫 토큰 = 바이너리). 단순 바이너리는 인자 무관 caution.
case "$1" in
  cat|ls|stat|df|du|lsblk|blkid|findmnt|free|uptime|hostname|id|whoami|date|uname|ip|ss|netstat|journalctl|dmesg|pvs|lvs|vgs)
    emit caution "ro-allowlist:$1" ;;
esac
# 서브커맨드 한정 화이트리스트: <bin> <sub> 형태만 caution
sub="${2:-}"
case "$1 $sub" in
  "systemctl status"|"systemctl is-active"|"systemctl is-enabled"|"systemctl show"|"systemctl list-units")
    emit caution "ro-allowlist:systemctl-${sub}" ;;
  "qm config"|"qm list"|"qm status")
    emit caution "ro-allowlist:qm-${sub}" ;;
  "pct config"|"pct list"|"pct status")
    emit caution "ro-allowlist:pct-${sub}" ;;
  "pvesm status"|"pvesm list")
    emit caution "ro-allowlist:pvesm-${sub}" ;;
  "apt list"|"dpkg -l")
    emit caution "ro-allowlist:pkg-query" ;;
esac
# 그 외 전부 — 미지/비화이트리스트 → fail-closed
emit destructive fallback-deny
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd homelab-ops && bash tests/test_classify.sh`
Expected: `PASS test_classify`.

- [ ] **Step 5: Commit**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_classify homelab-ops/tests/test_classify.sh
git commit -m "feat(homelab-ops): _classify read-only allowlist → caution"
```

---

## Phase 3 — `exec` verb (guard 동적 등급 + _backend 라우팅 + 감사)

### Task 5: guard 의 exec 동적 등급 + --grade-override

**Files:**
- Modify: `homelab-ops/bin/guard` (`guard_grade` 및 `*)` 메인 arm; `--plan`)
- Test: `homelab-ops/tests/test_exec.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_exec.sh` 생성:

```bash
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

# 동적 등급: read-only → caution(비-prod 즉시 실행), 미지 → destructive(approve 필요)
o="$(bin/guard exec lab-vm-900 -- --via guest cat /etc/os-release)"
assert_contains "$o" "BACKEND action=exec" "exec caution(ro) 즉시 실행"
assert_eq "caution" "$(tail -1 logs/audit.jsonl | jq -r .grade)" "ro 명령 caution 감사"
assert_eq "guest" "$(tail -1 logs/audit.jsonl | jq -r .via)" "via=guest 감사"
assert_eq "ro-allowlist:cat" "$(tail -1 logs/audit.jsonl | jq -r .classify_rule)" "classify_rule 감사"

assert_status 10 "bin/guard exec lab-vm-900 -- --via guest frobnicate" "미지 명령 → destructive, --approve 없으면 exit 10"
o2="$(bin/guard exec lab-vm-900 -- --via guest frobnicate 2>&1 || true)"
assert_contains "$o2" "fallback-deny" "dry-run impact 에 classify_rule 표기"

# --grade-override 는 상향만: caution 명령을 destructive 로 승격
assert_status 10 "bin/guard exec lab-vm-900 --grade-override destructive -- --via guest cat /x" "override 상향 → exit 10"
# 하향 인자(safe/caution) 거부
assert_status 2 "bin/guard exec lab-vm-900 --grade-override safe -- --via guest frobnicate" "override 하향 거부(exit≠0/10)"
finish; echo "PASS test_exec"
```

(`assert_status 2`는 "비-0·비-10 거부"를 의도 — guard의 `die`가 exit 1/2를 쓰면 그에 맞춰 코드 조정. 실제 `die` 종료코드 확인 후 기대값 일치시킬 것.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd homelab-ops && bash tests/test_exec.sh`
Expected: FAIL — guard가 `exec`를 동적 등급하지 않아 `_bump` 없는 정적 경로로 `dynamic` 등급이 그대로 흘러 backend 라우팅/감사가 깨짐.

- [ ] **Step 3: Write minimal implementation** — `bin/guard`:

(a) 메인 `*)` arm의 인자 파싱 루프(`while [[ $# -gt 0 ]]`)에 `--grade-override` 수집 추가:

```bash
        --grade-override) gov="${2:?--grade-override 값 필요}"; shift 2 ;;
```
루프 진입 전 `gov=""` 초기화.

(b) `extra=("$@")` 확정 후, 등급 계산 직전에 exec 동적 등급 블록 삽입:

```bash
  if [[ "$action" == "exec" ]]; then
    # extra 에서 --via 추출(나머지는 명령). _classify 에 그대로 전달.
    via=""; cargs=()
    set -- "${extra[@]}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --via) via="${2:?exec: --via <guest|node|pve> 필요}"; shift 2 ;;
        --) shift; cargs=("$@"); break ;;
        *) cargs+=("$1"); shift ;;
      esac
    done
    [[ "$via" =~ ^(guest|node|pve)$ ]] || die "exec: --via 는 guest|node|pve"
    cls="$("$HERE/_classify" "$via" -- "${cargs[@]}")"
    cgrade="${cls%%	*}"; crule="${cls##*	}"
    if [[ -n "$gov" ]]; then
      case "$gov" in
        destructive) cgrade=destructive; crule="${crule}+override" ;;
        *) die "exec: --grade-override 는 상향(destructive)만 허용 (받음: $gov)" ;;
      esac
    fi
    EXEC_VIA="$via"; EXEC_GRADE="$cgrade"; EXEC_RULE="$crule"
  else
    [[ -n "$gov" ]] && die "--grade-override 는 exec 전용"
  fi
```

(c) 등급 산출부에서 `exec`면 `EXEC_GRADE`를 쓰도록. `guard_grade` 호출 결과 `g`를 정하는 지점 근처에서:

```bash
  if [[ "$action" == "exec" ]]; then
    g="$EXEC_GRADE"
    # critical/prod 승급: 기존 _bump 규칙 동일 적용(여기선 safe 산출 불가)
    tj="$("$HERE/inv" get "$target")" || exit $?
    if jq -e '(.tags? // []) | index("critical")' >/dev/null 2>&1 <<<"$tj"; then
      [[ "$g" != "safe" ]] && g="$(_bump "$g")"
    fi
  else
    g="$(guard_grade "$action" "$target")"
  fi
```

(기존 `g="$(guard_grade ...)"` 한 줄을 위 분기로 교체. `_bump`는 guard 상단에 이미 정의됨.)

(d) `--plan` arm: `exec`면 `--via`로 transport 결정하도록. `--plan` 케이스에서 `[[ $# -ge 3 ]]` 검증 뒤, `pa="$2"; pt="$3"` 다음에:

```bash
    if [[ "$pa" == "exec" ]]; then
      shift 3; [[ "${1:-}" == "--" ]] && shift || true
      pvia=""
      while [[ $# -gt 0 ]]; do case "$1" in --via) pvia="${2:-}"; shift 2 ;; *) shift ;; esac; done
      case "$pvia" in
        guest) ptrans_override=ssh ;;
        node)  ptrans_override=host-ssh ;;
        pve)   ptrans_override=pve ;;
        *) die "--plan exec: --via guest|node|pve 필요" ;;
      esac
    fi
```
그리고 `ptrans="$(op_transport "$pa" "$pkind")"` 직후:
```bash
    [[ -n "${ptrans_override:-}" ]] && ptrans="$ptrans_override"
```
(이때 `--plan exec`는 등급이 dynamic이라 `[[ "$pgrade" == "safe" ]] && exit 0`에 안 걸린다 — exec는 safe 산출 불가이므로 항상 자격 산출로 진행. `guard_grade exec <t>`가 `dynamic`을 반환하더라도 `safe`가 아니므로 통과.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd homelab-ops && bash tests/test_exec.sh`
Expected: `PASS test_exec`. (`assert_status 2`의 기대 코드는 `bin/guard`의 `die` 실제 종료코드로 맞출 것 — `grep -n "^die\|die()" bin/_lib.sh`로 확인.)

- [ ] **Step 5: Commit**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/guard homelab-ops/tests/test_exec.sh
git commit -m "feat(homelab-ops): guard exec 동적 등급(_classify) + grade-override 상향"
```

### Task 6: 감사 레코드에 via/classify 필드 + _backend exec arm

**Files:**
- Modify: `homelab-ops/bin/guard` (감사 레코드 생성부)
- Modify: `homelab-ops/bin/_backend` (`exec:*` arm 추가)
- Test: `homelab-ops/tests/test_exec.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_exec.sh`의 `finish;` 직전에 추가:

```bash
# node transport 라우팅 + pve transport 라우팅이 backend 로 흐른다
export HOMELAB_BACKEND=bin/_backend   # 실제 backend(dry-run 경로만)
on="$(bin/guard exec lab-vm-900 -- --via node qm config 301 2>&1 || true)"
assert_contains "$on" "DRY-RUN" "node ro→caution 도 prod면 dry-run/실행; 비-prod면 즉시 — fixture 의존"
op="$(bin/guard exec lab-vm-900 -- --via pve --method GET --path /version 2>&1 || true)"
assert_contains "$op" "exec" "pve GET 라우팅"
export HOMELAB_BACKEND=/tmp/fake-backend
# 감사: via/classify_grade/classify_rule 항상 존재
bin/guard exec lab-vm-900 -- --via guest ls / >/dev/null
rec="$(tail -1 logs/audit.jsonl)"
assert_eq "guest" "$(jq -r .via <<<"$rec")" "via 감사"
assert_eq "caution" "$(jq -r .classify_grade <<<"$rec")" "classify_grade 감사"
assert_eq "ro-allowlist:ls" "$(jq -r .classify_rule <<<"$rec")" "classify_rule 감사"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd homelab-ops && bash tests/test_exec.sh`
Expected: FAIL — `jq -r .classify_grade`가 `null`(감사에 필드 없음) 또는 `_backend`에 `exec:*` arm 없어 "no backend mapping".

- [ ] **Step 3: Write minimal implementation**

(a) `bin/_backend`: `case "$action:$kind"`에 arm 추가(disk-grow arm 부근, remote-migrate 위):

```bash
  exec:*)
    via=""; cargs=()
    while [[ $# -gt 0 ]]; do
      case "$1" in --via) via="${2:-}"; shift 2 ;; --) shift; cargs+=("$@"); break ;; *) cargs+=("$1"); shift ;; esac
    done
    [[ "$via" =~ ^(guest|node|pve)$ ]] || die "exec: --via guest|node|pve"
    if [[ $dry -eq 1 ]]; then
      echo "DRY-RUN: exec $target via=$via -- ${cargs[*]}"
      echo "  분류근거는 guard 감사 레코드 classify_rule 참조"
      exit 0
    fi
    case "$via" in
      guest) "$HERE/ssh-run" "$target" -- "${cargs[@]}" ;;
      node)  "$HERE/ssh-run" "$(owner_host "$target")" -- "${cargs[@]}" ;;
      pve)
        method=""; path=""; body=()
        set -- "${cargs[@]}"
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --method) method="${2:-}"; shift 2 ;;
            --path) path="${2:-}"; shift 2 ;;
            --body) body+=("${2:-}"); shift 2 ;;
            *) shift ;;
          esac
        done
        [[ -n "$method" && -n "$path" ]] || die "exec --via pve: --method 와 --path 필요"
        "$HERE/pve" "$(owner_host "$target")" api "$method" "$path" "${body[@]}" ;;
    esac ;;
```

(b) `bin/guard`: 감사 JSON 생성부를 찾아(`jq -n` 또는 `printf` 로 audit.jsonl append 하는 지점), exec일 때 필드 추가. 기존 레코드 빌드가 `jq -n --arg ...` 형태라면 다음 인자를 조건부로 추가:

```bash
  audit_extra=()
  if [[ "$action" == "exec" ]]; then
    audit_extra=(--arg via "$EXEC_VIA" --arg classify_grade "$EXEC_GRADE" --arg classify_rule "$EXEC_RULE")
  fi
```
그리고 `jq -n` 객체에 `${audit_extra[@]}`를 전달하고 객체 본문에 조건부 키를 넣되, exec가 아니면 빈 문자열 대신 키 자체를 생략하기 위해 다음 패턴 사용 — 기존 jq 호출이 한 곳이므로, exec 분기에서만 `+ {via:$via, classify_grade:$classify_grade, classify_rule:$classify_rule}`를 머지:

```bash
  # 기존: rec="$(jq -n --arg ... '{...}')"
  if [[ "$action" == "exec" ]]; then
    rec="$(jq -n --arg via "$EXEC_VIA" --arg cg "$EXEC_GRADE" --arg cr "$EXEC_RULE" \
              --argjson base "$rec" '$base + {via:$via, classify_grade:$cg, classify_rule:$cr}')"
  fi
```
(감사 레코드를 만드는 변수명이 `rec`가 아니면 실제 변수명으로 치환. `grep -n "audit.jsonl" bin/guard`로 append 지점·변수 확인 후 적용.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd homelab-ops && bash tests/test_exec.sh && bash tests/test_guard_exec.sh`
Expected: 둘 다 PASS (기존 `test_guard_exec.sh` 회귀 없음).

- [ ] **Step 5: Commit**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/guard homelab-ops/bin/_backend homelab-ops/tests/test_exec.sh
git commit -m "feat(homelab-ops): _backend exec arm(guest/node/pve) + 감사 via/classify 필드"
```

---

## Phase 4 — 큐레이티드 verb

### Task 7: disk-grow --to (qm resize 선행, 축소 거부, 하위호환)

**Files:**
- Modify: `homelab-ops/bin/_backend` (`disk-grow:*` arm)
- Test: `homelab-ops/tests/test_disk_grow.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_disk_grow.sh` 끝의 `finish` 직전에 추가:

```bash
# --to: dry-run 에 qm resize 선행 단계 명시
o2="$(eval "$PV bin/_backend disk-grow lab-vm-900 --dry-run -- --to 128G 2>&1")"
assert_contains "$o2" "qm resize" "--to dry-run 에 qm resize 단계"
assert_contains "$o2" "128G" "목표 크기 표기"
# --to 없으면 기존 동작(하위호환): qm resize 미포함
o3="$(eval "$PV bin/_backend disk-grow lab-vm-900 --dry-run -- 2>&1")"
assert_not_contains "$o3" "qm resize" "--to 없으면 qm resize 없음(하위호환)"
# 잘못된 size 형식 거부
assert_status 1 "$(printf '%s ' $PV) bin/_backend disk-grow lab-vm-900 --dry-run -- --to 128GB; echo" "size 형식 가드(128GB 거부, G/T 만)"
```

(`disk-grow`의 owner 노드 ssh stub은 기존 `$gd/ssh`가 `qm guest exec` JSON만 처리하므로, `qm resize`/`qm config` 호출 시에도 무해한 JSON을 반환하도록 stub에 분기 추가: `elif [[ "$all" == *"qm config"* ]]; then echo 'scsi0: local-lvm:vm-301-disk-0,size=96G';` 와 `elif [[ "$all" == *"qm resize"* ]]; then echo '{"out-data":"","exitcode":0}';`. dry-run 경로는 실제 ssh 미호출이므로 dry-run 단언엔 영향 없음.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd homelab-ops && bash tests/test_disk_grow.sh`
Expected: FAIL — `--to dry-run 에 qm resize 단계`에서 `qm resize` 미출력.

- [ ] **Step 3: Write minimal implementation** — `bin/_backend`의 `disk-grow:*` arm 인자 파싱(`while [[ $# -gt 0 ]]; do case "$1" in --lv) ...`)에 `--to`/`--disk` 추가하고, dry-run/apply 시퀀스에 resize 선행:

파싱 루프에 추가:
```bash
      case "$1" in
        --lv) lv="${2:-}"; shift 2 ;;
        --to) to="${2:-}"; shift 2 ;;
        --disk) disksel="${2:-}"; shift 2 ;;
        *) shift ;;
      esac
```
루프 전 `to=""; disksel=""` 초기화. 탐지 블록 시작 전에 size 가드 + disk 결정:
```bash
    if [[ -n "$to" ]]; then
      [[ "$to" =~ ^[0-9]+[GT]$ ]] || die "disk-grow --to: 크기 형식 [0-9]+(G|T) 만 (받음: '$to')"
      vmid="$(jq -r '.vmid // empty' <<<"$inv")"
      [[ "$vmid" =~ ^[0-9]+$ ]] || die "disk-grow --to: vmid 비정상"
      oh="$(owner_host "$target")"
      # 대상 디스크: --disk 명시 우선, 없으면 qm config 에서 단일 디스크 자동탐지
      if [[ -z "$disksel" ]]; then
        cfg="$("$HERE/ssh-run" "$oh" -- qm config "$vmid" 2>/dev/null || true)"
        disks="$(grep -oE '^(scsi|virtio|sata|ide)[0-9]+:' <<<"$cfg" | tr -d ':' || true)"
        [[ "$(wc -l <<<"$disks")" -eq 1 && -n "$disks" ]] || die "disk-grow --to: 디스크 단일 자동탐지 실패 — --disk <scsi0|...> 명시 필요"
        disksel="$disks"
      fi
      [[ "$disksel" =~ ^(scsi|virtio|sata|ide)[0-9]+$ ]] || die "disk-grow --to: --disk 형식 비정상 (받음: '$disksel')"
    fi
```
dry-run 출력 블록(`echo "DRY-RUN: disk-grow ..."` 다음 줄)에 조건부 추가:
```bash
      [[ -n "$to" ]] && echo "  선행(PVE): qm resize $vmid $disksel $to (owner=$oh, 절대값·증가만 — qm resize 는 축소 거부)"
```
apply 경로(`_ga growpart ...` 직전)에 추가:
```bash
    if [[ -n "$to" ]]; then
      "$HERE/ssh-run" "$oh" -- qm resize "$vmid" "$disksel" "$to" \
        || die "disk-grow --to: qm resize 실패 (목표<현재면 PVE 가 거부 — 증가만 가능)"
    fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd homelab-ops && bash tests/test_disk_grow.sh`
Expected: `PASS test_disk_grow`.

- [ ] **Step 5: Commit**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_backend homelab-ops/tests/test_disk_grow.sh
git commit -m "feat(homelab-ops): disk-grow --to — qm resize 선행 1단계 확장(TODO 구현)"
```

### Task 8: service / logs / pkg-update / reboot arm

**Files:**
- Modify: `homelab-ops/bin/_backend` (4개 arm 추가)
- Test: `homelab-ops/tests/test_curated_verbs.sh`

- [ ] **Step 1: Write the failing test** — `tests/test_curated_verbs.sh` 생성:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/lib.sh
chmod +x bin/_backend bin/guard 2>/dev/null || true

# 등급 회귀
assert_eq "caution" "$(bin/guard grade service lab-vm-900)" "service caution"
assert_eq "caution" "$(bin/guard grade logs lab-vm-900)" "logs caution"
assert_eq "caution" "$(bin/guard grade pkg-update lab-vm-900)" "pkg-update caution"
assert_eq "caution" "$(bin/guard grade reboot lab-vm-900)" "reboot caution"

# dry-run 라우팅(미실행, exit 0)
assert_contains "$(bin/_backend service lab-vm-900 --dry-run -- restart sshd 2>&1)" "DRY-RUN" "service dry-run"
assert_contains "$(bin/_backend logs lab-vm-900 --dry-run -- --unit sshd -n 20 2>&1)" "DRY-RUN" "logs dry-run"
assert_contains "$(bin/_backend pkg-update lab-vm-900 --dry-run -- 2>&1)" "DRY-RUN" "pkg-update dry-run"
assert_contains "$(bin/_backend reboot lab-vm-900 --dry-run -- 2>&1)" "DRY-RUN" "reboot dry-run"

# 인자 화이트리스트: service 의 미지 서브커맨드 거부
assert_status 1 "bin/_backend service lab-vm-900 --dry-run -- frobnicate sshd; echo" "service 미지 서브커맨드 거부"
# service unit 명 charset 거부
assert_status 1 "bin/_backend service lab-vm-900 --dry-run -- restart 'a;b'; echo" "service unit charset 거부"
finish; echo "PASS test_curated_verbs"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd homelab-ops && bash tests/test_curated_verbs.sh`
Expected: FAIL — "no backend mapping for action 'service'".

- [ ] **Step 3: Write minimal implementation** — `bin/_backend` `case`에 4개 arm 추가:

```bash
  service:*)
    svc_sub="${1:-}"; svc_unit="${2:-}"
    case "$svc_sub" in start|stop|restart|status) : ;; *) die "service: 서브커맨드는 start|stop|restart|status (받음: '$svc_sub')" ;; esac
    [[ "$svc_unit" =~ ^[A-Za-z0-9_.@:-]+$ ]] || die "service: unit 명 charset 위반 (받음: '$svc_unit')"
    if [[ $dry -eq 1 ]]; then echo "DRY-RUN: service $svc_sub $svc_unit on $target (guest ssh)"; exit 0; fi
    "$HERE/ssh-run" "$target" -- systemctl "$svc_sub" "$svc_unit" ;;
  logs:*)
    lg_unit=""; lg_file=""; lg_n="100"
    while [[ $# -gt 0 ]]; do case "$1" in --unit) lg_unit="${2:-}"; shift 2 ;; --file) lg_file="${2:-}"; shift 2 ;; -n) lg_n="${2:-}"; shift 2 ;; *) shift ;; esac; done
    [[ "$lg_n" =~ ^[0-9]+$ ]] || die "logs: -n 은 정수 (받음: '$lg_n')"
    if [[ -n "$lg_unit" ]]; then
      [[ "$lg_unit" =~ ^[A-Za-z0-9_.@:-]+$ ]] || die "logs: --unit charset 위반"
      if [[ $dry -eq 1 ]]; then echo "DRY-RUN: logs journalctl -u $lg_unit -n $lg_n on $target"; exit 0; fi
      "$HERE/ssh-run" "$target" -- journalctl -u "$lg_unit" -n "$lg_n" --no-pager
    elif [[ -n "$lg_file" ]]; then
      [[ "$lg_file" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "logs: --file 은 절대경로·안전문자만"
      if [[ $dry -eq 1 ]]; then echo "DRY-RUN: logs tail -n $lg_n $lg_file on $target"; exit 0; fi
      "$HERE/ssh-run" "$target" -- tail -n "$lg_n" "$lg_file"
    else die "logs: --unit <u> 또는 --file <path> 필요"; fi ;;
  pkg-update:*)
    if [[ $dry -eq 1 ]]; then echo "DRY-RUN: pkg-update (apt/dnf update+upgrade) on $target (guest ssh)"; exit 0; fi
    "$HERE/ssh-run" "$target" -- sh -lc 'if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade; else dnf -y upgrade; fi' ;;
  reboot:*)
    if [[ $dry -eq 1 ]]; then echo "DRY-RUN: reboot guest OS on $target (systemctl reboot via guest ssh)"; exit 0; fi
    "$HERE/ssh-run" "$target" -- systemctl reboot ;;
```

(주: `pkg-update`의 `sh -lc`는 _backend 내부에서 의도적으로 구성한 신뢰 명령이며 운영자 임의 입력이 아니다 — `exec` 분류기의 metachar 규칙과 무관. 주석으로 명시할 것.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd homelab-ops && bash tests/test_curated_verbs.sh && bash tests/test_action_table.sh`
Expected: 둘 다 PASS (이제 backend arm이 있으니 Direction 1/2 패리티도 충족).

- [ ] **Step 5: Commit**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/bin/_backend homelab-ops/tests/test_curated_verbs.sh
git commit -m "feat(homelab-ops): service/logs/pkg-update/reboot 큐레이티드 arm"
```

---

## Phase 5 — 문서 + 최종 회귀

### Task 9: SKILL.md 갱신 + 전체 회귀

**Files:**
- Modify: `homelab-ops/SKILL.md`
- Test: `homelab-ops/tests/run.sh` (전체)

- [ ] **Step 1: Write the failing test** — 회귀가 곧 검증. 먼저 전체 스위트 실행:

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED` (Phase 1–4 누적 — 만약 실패하면 해당 test로 복귀해 수정).

- [ ] **Step 2: SKILL.md "When to use" 에 신규 verb 추가** — 기존 verb 나열 패턴에 맞춰 항목 추가:

```markdown
- "서비스 start/stop/restart/status" → `"$HL/bin/guard" service <id> -- <start|stop|restart|status> <unit>` (caution; guest ssh)
- "로그 조회" → `"$HL/bin/guard" logs <id> -- --unit <unit> [-n N]` 또는 `-- --file <path> [-n N]` (caution; 읽기 전용)
- "패키지 업데이트/재부팅" → `"$HL/bin/guard" pkg-update <id>` / `"$HL/bin/guard" reboot <id>` (caution; guest ssh)
- "디스크 1단계 확장(PVE+게스트)" → `"$HL/bin/guard" disk-grow <id> -- --to <NG|NT> [--disk scsiN]` (destructive; qm resize 선행, 증가만)
- "임의 명령(범용 hatch)" → `"$HL/bin/guard" exec <id> -- --via <guest|node|pve> <cmd...>` (동적 등급: read-only allowlist→caution, 그 외 destructive; `--grade-override destructive` 상향만)
```

`disk-grow` 기존 항목의 "PVE 디스크는 사전 확장 전제" 문구 옆에 "(`--to` 사용 시 qm resize 까지 1단계로 수행)" 추가. SKILL.md 상단 "storage/network 변경은 미지원" 문장에 "단, `disk-grow --to` 의 qm resize 와 `exec --via pve` 는 예외(전자는 단일 디스크 증가, 후자는 분류기 가드 하 범용)" 단서 추가.

- [ ] **Step 3: 회귀 재확인**

Run: `cd homelab-ops && bash tests/run.sh`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 4: 스펙 커버리지 셀프체크** — 스펙의 묶음 A 5개 verb + 묶음 B exec(guest/node/pve, 분류기 4규칙, override, 감사 필드) + 단일출처/패리티가 모두 Task로 구현됐는지 확인. 누락 시 해당 Task 보완.

- [ ] **Step 5: Commit + 푸시 준비**

```bash
cd /home/altair823/claude-skills
git add homelab-ops/SKILL.md
git commit -m "docs(homelab-ops): SKILL.md 에 exec/service/logs/pkg-update/reboot/disk-grow --to 문서화"
git log --oneline origin/main..HEAD
```

(푸시·PR 생성은 사용자 승인 시 별도 진행 — `gitea-ops` 스킬 사용.)

---

## Self-Review (작성자 체크 — 완료)

**1. 스펙 커버리지:** 묶음 A(service/logs/disk-grow --to/pkg-update/reboot)=Task 1·7·8; 묶음 B exec(guest/node/pve)=Task 5·6; 분류기 4규칙(metachar/pve-write/ro-allowlist/fallback-deny)=Task 3·4; 단일출처 dynamic 훅·패리티=Task 1·2; 감사 via/classify=Task 6; 문서·TODO 닫기=Task 9. 갭 없음.

**2. 플레이스홀더 스캔:** TBD/TODO/"적절히 처리" 없음. 모든 코드 단계에 실제 bash 포함. (단 Task 5·6에 "변수명이 다르면 실제명으로 치환" 가이드가 있는데, 이는 기존 미공개 코드 변수에 대한 명시적 적응 지시이지 플레이스홀더가 아님 — `grep` 명령으로 확정 방법 제시.)

**3. 타입/시그니처 일관성:** `_classify` 출력 계약 `grade<TAB>rule` Task 3·4·5에서 일관. `EXEC_VIA/EXEC_GRADE/EXEC_RULE` guard 내부 변수명 Task 5·6 일관. `--via guest|node|pve` 토큰 guard/_classify/_backend 전 Task 일관. `--to [0-9]+[GT]` 형식 Task 7 일관.
