# homelab-ops 범용 exec hatch + 큐레이티드 운영 verb 묶음 설계

작성: 2026-05-19
브랜치: `feat/homelab-ops-exec-and-curated-verbs`
스킬: `homelab-ops`
선행: `2026-05-18-homelab-ops-guard-verbs-design.md` (단일 출처 `ACTIONS` 테이블·패리티 테스트·`host-ssh`/`pdm` transport·`pve_wait_task`·감사 토대를 이 설계가 계승). `homelab-ops/TODO.md` 의 "PVE 가상디스크 확장 자동화" 항목을 포함 구현.

## 목적

운영자가 "웬만한 PVE·서버 운영 SSH 작업"을 homelab-ops 안에서 처리할 수 있게 한다. 단, homelab-ops 의 핵심 불변식(단일 출처 `ACTIONS`, deny-by-default, guard-only mutation, `bw://` 자격 via bitwarden-ops, 포렌식 감사, 패리티 테스트 녹색)을 깨지 않는다.

**계층형** 접근:

1. **큐레이티드 verb 묶음** — 자주 쓰는 운영 작업을 1급 정적 verb 로 추가(기존 패턴 동일).
2. **단일 `exec` 범용 hatch** — 임의 명령을, 보수적 휴리스틱 분류기가 동적으로 등급 매겨 실행. deny-by-default 정신을 동적-등급을 *단 하나의 verb* 에 국한 + fail-closed + 패리티/분류기 테스트로 봉인.

## 비범위 (YAGNI)

- `disk-grow` 외 PVE 스토리지/네트워크 *구조화* verb (여전히 Phase 2 — ad-hoc 은 `exec --via pve` 로 충분).
- 인터랙티브 세션, 에디터, attach 된 장기 실행 프로세스.
- 기존 best-effort TOCTOU 이상의 동시성/락.
- `exec` 의 grade 하향 override (변경성 명령을 safe 로 주장하는 경로 — 원천 금지).

## 범위 (2 묶음)

### 묶음 A — 큐레이티드 verb (ACTIONS 정적 행)

| verb | 등급 / transport | 동작 | 안전 가드 |
|---|---|---|---|
| `service` | `caution guest` | `-- <start\|stop\|restart\|status> <unit>` (게스트 systemctl) | 서브커맨드 4종 + unit 명 charset 화이트리스트; 그 외 거부 |
| `logs` | `caution ssh` | `-- --unit <u> [-n N]` (journalctl) 또는 `-- --file <path> [-n N]` (tail). 읽기 전용 | "safe" 는 자격 불필요 인벤토리 읽기 전용 전용 — 원격 읽기는 transport 자격이 필요하므로 최소 `caution`. unit/path charset 가드 |
| `disk-grow` (확장) | `destructive host-ssh` | 기존 verb 에 `--to <size>` 옵션 추가: owner 노드에서 `qm resize <vmid> <disk> <size>` → 이어서 기존 게스트 내부 시퀀스. `--to` 없으면 기존 동작 그대로(하위호환) | `--to` 절대값·증가만; 목표 ≤ 현재 거부. 대상 디스크 단일 자동탐지, 다중이면 `--disk` 명시 요구. size charset 가드 |
| `pkg-update` | `caution ssh` | 게스트 apt/dnf update + upgrade (비대화식) | 기존 `pkg-install` 미러; 패키지 매니저 자동탐지(apt/dnf) |
| `reboot` | `caution guest` | 게스트 OS 재부팅 | `restart`(VM 재시작)와 구분 — 게스트 내부 `systemctl reboot`. prod 는 기존 caution 규칙대로 --approve |

### 묶음 B — `exec` 범용 hatch (동적 등급 verb)

- 시그니처:
  - `guard exec <target> [--approve] [--grade-override destructive] -- --via guest <argv...>`
  - `guard exec <target> [--approve] -- --via node <argv...>` (owner 노드 root)
  - `guard exec <target> [--approve] -- --via pve --method GET|POST|PUT|DELETE --path /... [--body k=v ...]`
- ACTIONS 에 `[exec]="dynamic exec"` **센티넬 행** 1개 (둘째 토큰 `exec` = "transport 는 런타임 결정" 마커). guard(등급)·_backend(라우팅)·op_transport(자격)·--plan 이 `dynamic` 토큰을 만나면 분류기 모듈 `bin/_classify` 에 위임 — 이 verb 의 등급·transport 단일 출처 = `_classify` + `--via`.

## 아키텍처 & 컴포넌트

### 1. 단일-출처 계약 확장 (`bin/_lib.sh`)

- `ACTIONS["exec"]="dynamic exec"`. `action_grade` / `op_transport` 가 spec 첫 토큰이 `dynamic` 이면 정적 해석 대신 `_classify` 호출(action·via·argv 전달)로 분기. 정적 verb 경로는 전부 불변.
- `dynamic` 은 **문서화된 유일한 동적 훅**. 새 동적 verb 를 임의 추가하는 경로는 만들지 않는다(deny-by-default 유지). 패리티 테스트가 "정적 verb 는 전부 정적, `exec` 만 `dynamic`" 을 단언.

### 2. 분류기 모듈 `bin/_classify`

입력: `--via <guest|node|pve>` + 명령(argv 또는 pve method/path). 출력: `safe|caution|destructive` + `classify_rule=<matched>`.

보수적 allowlist 규칙(순서대로, 첫 매치 승):

1. **메타문자 차단**: argv 어느 토큰이든 셸 체이닝/리다이렉트 메타(`; | & $ \` ( ) < > && ||` 및 개행) 포함, 또는 `--shell`/`bash -c`/`sh -c` 형태 → **destructive** (`rule=metachar`).
2. **pve transport**: `--method GET` 만 → `caution` (`rule=pve-get`); `POST|PUT|DELETE` 또는 미지 method → **destructive** (`rule=pve-write`).
3. **읽기 전용 바이너리 allowlist** (guest/node): 첫 토큰이 알려진 read-only 집합 — `cat ls stat df du lsblk findmnt blkid free uptime hostname id whoami date uname ip ss netstat journalctl dmesg pvs lvs vgs` + 서브커맨드 한정 화이트리스트(`systemctl status|is-active|is-enabled|show|list-units`, `qm config|list|status`, `pct config|list|status`, `pvesm status|list`, `apt list`, `dpkg -l`) → `caution` (`rule=ro-allowlist:<bin>`).
4. **그 외 전부** (미지 바이너리, 비-화이트리스트 서브커맨드, 인자 파싱 실패) → **destructive** (`rule=fallback-deny`).

`caution` 이 분류기가 낼 수 있는 **최저** 등급(원격+자격이라 `safe` 없음). `--grade-override destructive` 는 상향만 허용; 하향 인자는 파싱 단계에서 거부.

### 3. 라우팅 `bin/_backend`

- `exec:*` arm 추가: `--via` 로 transport 결정 → `guest`=게스트 `access.ssh` 경유 `bin/ssh-run`, `node`=owner 노드 root `bin/ssh-run`, `pve`=`bin/pve api`. argv 는 배열로 전달(셸 문자열 eval 금지). pve 는 기존 task 면 `pve_wait_task` 폴링.
- 묶음 A verb arm 추가: `service`/`logs`/`pkg-update`/`reboot` 는 게스트 ssh, `disk-grow --to` 는 owner 노드 `qm resize` 선행 후 기존 게스트 시퀀스 재사용.

### 4. 자격 (`guard --plan` / op_transport)

기존 메커니즘 그대로. `exec --via guest` → 게스트 `key_ref`/`pass_ref`; `--via node` → owner 노드 `HL_SSH_KEY`; `--via pve` → `PVE_TOKEN`. 자격 부재 시 exit 3 + bw-exec 힌트(불변).

### 5. 포렌식 감사

`exec` 감사 레코드에 추가 필드: `via`, `classify_grade`, `classify_rule`, masked 전체 명령, dry-run hash. Hard Rule 5(재구성 가능성) 충족. `disk-grow --to` 는 resize 단계와 게스트 단계를 각각 감사.

## 데이터 흐름 (`exec` 기준)

```
user → guard exec <target> --via X -- <cmd>
  → guard: ACTIONS[exec]="dynamic exec" → _classify(X, cmd) → grade + rule
  → critical/prod 승급 (기존 규칙; exec 는 절대 safe 산출 안 함)
  → destructive/prod-caution & --approve 없음 → DRY-RUN + impact + classify_rule, exit 10
  → --approve: guard --plan → bw-exec 래핑 → bin/ssh-run(guest/node) | bin/pve(api)
  → pve task 면 pve_wait_task 폴링 → 감사 append
```

큐레이티드 verb 는 기존 정적 경로(테이블 등급 → 라우팅 → 자격 → 감사) 그대로.

## 에러 처리 (전부 fail-closed)

- 미지 verb → 기존 deny-by-default destructive (불변).
- `_classify` 파싱 모호/실패 → destructive (`rule=fallback-deny`).
- `exec --via pve` 쓰기 method → 항상 destructive.
- `disk-grow --to` 목표 ≤ 현재 → 거부; 다중 디스크면 `--disk` 요구; resize·게스트 단계 사이 TOCTOU 는 best-effort 한계 명시(기존 disk-attach 주석 수준).
- transport 자격 부재 → exit 3 + bw-exec 힌트.
- grade 하향 override → 파싱 단계 거부.

## 테스트 (기존 `tests/` 패턴 + TDD)

- `test_action_table.sh` 확장: 정적 verb 패리티 유지 + `ACTIONS[exec]="dynamic exec"` 단언 + "정적 verb 에 `dynamic` 토큰 없음" 단언.
- 신규 `test_classify.sh`: 코퍼스 — 읽기전용 allowlist→caution, 메타문자→destructive, pve GET→caution / POST→destructive, 미지 바이너리→destructive, override 상향만, 하향 거부.
- `disk-grow --to`: resize 경로 / 축소·비증가 거부 / 다중 디스크 `--disk` 요구 / `--to` 없는 하위호환.
- `service`·`logs`·`pkg-update`·`reboot`: dry-run + 등급 + 인자 화이트리스트 거부.
- `exec`: dry-run + 분류근거 감사 기록 + transport별 자격 plan.
- 매 단계 `tests/run.sh` 전체 녹색(중간 커밋 회귀 없음).

## 구현 순서 (바텀업 — 토대 우선)

1. `_lib.sh` 단일-출처 `dynamic` 훅 + 패리티 테스트 확장 (토대, 외부 의존 없음).
2. `bin/_classify` + `test_classify.sh` (독립 모듈, 순수 함수 — TDD 적합).
3. `exec` arm (`_backend` 라우팅 + guard 통합 + 감사 필드) — guest/node/pve 순.
4. 묶음 A 큐레이티드 verb: `disk-grow --to`(TODO 구현) → `service` → `logs` → `pkg-update` → `reboot`.
5. SKILL.md / TODO.md 문서 갱신(TODO 항목 닫기) + 최종 회귀.

각 단계 종료 시 패리티 테스트가 단일-출처 드리프트를 차단한다.

## 런타임 블로커 (코드 아님 — 이번 작업의 코드+테스트는 완결)

- 게스트/owner 노드 SSH 자격의 vault 등록(`bw-put`) — 운영자 데이터 작업.
- `exec --via pve` 의 PVE 토큰 권한 범위 — 운영자 보유 토큰에 의존.
- 큐레이티드 verb 대상 게스트의 QEMU guest-agent 동작(disk-grow 계열).
