# homelab-ops 하드닝 설계

작성: 2026-05-18
브랜치: `feat/homelab-ops-hardening`
스킬: `homelab-ops`

## 목적

운영자가 `homelab-ops/TODO.md` 및 직접 검토에서 식별한 개선점 중, 서로
강결합된 5개 영역을 **하나의 하드닝 spec**으로 묶어 처리한다. 핵심 가치는
스킬의 존재 이유와 동일하다: **파괴적 실수는 어렵게, 모든 작업은 정확히
포렌식 재구성 가능하게.**

범위:

- **A·B** — PVE 비동기 task 폴링: 감사 기록이 "API 수락"이 아니라 "작업
  결과"를 반영하도록. `provisioning/phase1`의 거짓 `CREATED` 제거.
- **C** — 유령 verb 정리: `GRADE[]`에 있으나 backend 미구현인
  `kill`/`net-change`/`storage-remove` 제거, `delete`는 `destroy` 별칭으로
  명시. SKILL.md 광고 문구 정정.
- **D** — 라우팅 단일 테이블화: grade·transport 결정을 `_lib.sh` 단일 출처
  연관배열로. 4곳 수동 동기 계약을 패리티 테스트로 대체.
- **인벤토리 경로 발견** — `bin/inv`가 `~/.config/homelab-ops`(XDG)를
  자동 발견하도록 3단계 탐색. SKILL.md에 위치·발견 순서 명문화.
- **`backup` verb** — vzdump (caution, transport pve). TODO #1.

비범위(후속, 본 spec 비구현):

- `disk-attach`/`disk-detach` — SSH(root) 전송 + vault에 노드 root SSH 키
  `bw-put` 등록이라는 선행 데이터 작업에 막혀 있음.
- `remote-migrate` — SKILL.md "Not for: …migration" 정책 변경 결정이 선행.
- E(감사 원자적 append)·F(해시 체인)·G(마스킹 sed 중복 제거) — 이번
  범위에서 의도적으로 제외(A·B에 필요한 감사 레코드 *필드 추가*만 포함).

## 구현 순서 (바텀업 — 토대부터)

재작업·드리프트 위험을 최소화하기 위해 토대를 먼저 깐다.

1. **D** (단일 테이블) — 라우팅을 한 곳으로 모음.
2. **C** (유령 verb 제거) — 테이블에서 자연 탈락 + 별칭 + SKILL.md.
3. **A·B** (task 폴링 + 감사 필드 + phase1) — 정돈된 단일 지점만 수정.
4. **인벤토리 경로 발견**.
5. **`backup` verb** — 완성된 테이블 + 폴링 헬퍼 재사용.

각 단계는 독립적으로 TDD 가능하고, 단계별 테스트가 회귀를 차단한다.

## 아키텍처 & 컴포넌트 맵

| 파일 | 현재 | 변경 후 |
|---|---|---|
| `bin/_lib.sh` | `op_transport()`, `owner_host()`, mask, audit | 단일 액션 테이블 `ACTIONS[]`·`ACTION_ALIASES[]` 추가(grade+transport 단일 출처). `op_transport()`는 테이블 조회 래퍼로 축소. PVE task 폴링 헬퍼 `pve_wait_task()` 추가 |
| `bin/guard` | `GRADE[]` 로컬 정의 | `GRADE[]` 제거 → `_lib.sh` 테이블 조회. 입력 별칭 정규화. 감사 레코드에 `task_upid`·`task_exitstatus` 추가 |
| `bin/_backend` | case arm 디스패치 | 라우팅을 테이블 기준으로. 미구현 verb 자연 제거 |
| `bin/pve` | start/stop/… verb가 curl만 | mutating verb가 UPID 폴링 후 `exitstatus` 반영. `backup`(vzdump) verb 추가 |
| `bin/inv` | env→repo 2단계 | 3단계 발견(env→XDG→repo) |
| `provisioning/phase1` | 거짓 `CREATED` | clone task 폴링 후 실제 완료 보고 |
| `SKILL.md` | 광고/셋업 문구 | 유령 verb 제거, 인벤토리 위치·발견 순서 명문화 |
| `tests/` | 기존 | 패리티 테스트 + task 폴링/인벤토리 발견/backup 케이스 추가 |

핵심 원칙: **라우팅은 단일 테이블, verb별 행위는 `bin/pve`에 국소화,
드리프트는 테스트가 차단, 감사는 "수락"이 아닌 "결과"를 기록.**

## D — 단일 액션 테이블

`_lib.sh`에 단일 출처 연관배열:

```bash
# action -> "<grade> <transport>"
#   grade:     safe | caution | destructive
#   transport: none | pve | ssh | guest
#     guest = 대상 kind 가 proxmox-host/vm/lxc 면 pve, 그 외면 ssh
declare -gA ACTIONS=(
  [status]="safe none"        [list]="safe none"     [metrics]="safe none"
  [get]="safe none"           [inventory]="safe none"
  [start]="caution guest"     [stop]="caution guest"  [restart]="caution guest"
  [snapshot]="caution guest"  [pkg-install]="caution ssh"
  [backup]="caution pve"
  [provision]="destructive pve"  [destroy]="destructive guest"
)
declare -gA ACTION_ALIASES=( [delete]="destroy" )
```

- **별칭 정규화**: 조회 전 한 곳(`_lib.sh`의 `canon_action()`)에서
  `ACTION_ALIASES`를 해소. `guard`/`_backend`/`op_transport`는 정규화된
  액션만 다룬다.
- `guard_grade()`: `ACTIONS[$action]`의 첫 토큰 + 기존 critical 1단계
  승급 로직(safe는 절대 승급 안 함 — 기존 규칙 유지) 그대로.
- `op_transport()`: 둘째 토큰을 읽고, 값이 `guest`면 대상 kind를 보고
  `pve`/`ssh`로 해석하는 얇은 래퍼. (기존 kind 분기 로직이 여기로 이동 —
  분기는 한 곳에만 존재.)
- `GRADE[]`(bin/guard)와 `op_transport`의 case 본문은 제거되고 전부
  테이블 조회로 대체된다.

### 패리티 테스트 (`tests/test_action_table.sh`)

기존 "4곳 수동 동기" 주석 계약을 대체하는 드리프트 차단 장치:

1. 테이블의 모든 **비-safe** 액션이 `_backend`에서 디스패치되어
   "no backend mapping"으로 떨어지지 않는다.
2. `_backend`/`bin/pve`가 처리하는 모든 verb가 테이블에 존재한다.
3. `ACTION_ALIASES`의 모든 별칭이 실재하는 `ACTIONS` 키를 가리킨다.

## C — 유령 verb 정리

D의 테이블이 단일 출처가 되면 대부분 자동 해결:

- `kill`/`net-change`/`storage-remove` → 테이블에 **없음**.
  deny-by-default가 grade 미정 액션을 destructive 취급 후 `_backend`가
  거부 → "정직하게 미지원". (Hard Rule 3 준수: ad-hoc 추가 금지.)
- `delete` → `ACTION_ALIASES[delete]="destroy"`. `guard delete <vm>`은
  `destroy`와 동일 경로·grade·dry-run.
- **감사 `action` 기록**: 정규화된 `destroy`로 기록한다(같은 작업이 두
  이름으로 분기 기록되면 timeline 혼란 → 포렌식 일관성 우선). 사용자가
  입력한 원형 별칭은 run-log 헤더에만 흔적으로 남긴다.
- `SKILL.md` "When to use"의 `destroy/delete/storage/network change`
  문구 → 실제 지원(`destroy`(=`delete`)/`snapshot`/`backup`)만 광고.
  storage/network는 "미지원(Phase 2 후보)"로 명시.

## A·B — PVE task 폴링 & 포렌식 정확성

### `_lib.sh`: `pve_wait_task()` (단일 출처)

- 입력: host_id, UPID.
- `GET /nodes/{node}/tasks/{upid}/status`를 폴링(`bin/pve` 의 인증·CA
  경로 재사용).
- 종료 판정: `.status == "stopped"` → `.exitstatus`. `"OK"`면 성공(0),
  그 외면 실패(비-0, `exitstatus` 문자열 보존).
- 폴링 간격: 고정 2초(홈랩 규모에 충분, backoff 불필요).
- 타임아웃: 기본 600초, `HOMELAB_TASK_TIMEOUT` env override. 타임아웃
  시 전용 exit code **75**("제출됨·결과 미상")로 반환하고 UPID는 보존.

### `bin/pve`

start/stop/restart/snapshot/destroy의 `call`이 UPID
(`{"data":"UPID:..."}`)를 반환하면 `pve_wait_task`로 완료까지 대기 후
그 결과를 exit으로 전파. status/vm-config 등 동기 GET은 변경 없음.

### `provisioning/phase1`

clone API 응답의 UPID를 `pve_wait_task`로 대기. 완료·성공 확인 후에만
`CREATED:` 출력. 미완료/실패면 die + 비-0. (거짓 `CREATED` 제거.)

### 감사 스키마 확장 (추가 전용, 하위호환)

- 레코드에 `task_upid`(string|null), `task_exitstatus`(string|null) 추가.
- 캡처 방식: `bin/pve`/`provisioning/phase1`가 작업의 마지막 줄에
  구조화 라인 `HO-TASK upid=<u> exitstatus=<s>` 를 stdout에 emit.
  `guard`의 `_audit`가 backend 출력에서 이 라인을 파싱해 두 필드를
  채우고, run-log엔 그대로 남긴다.
- 타임아웃(exit 75)도 레코드에 `exit:75` + `task_upid` 보존 →
  forensics에서 "수락됐으나 결과 미확인" 추적 가능.
- `forensics timeline`은 기존대로 동작(추가 필드 무시). timeline 출력
  포맷 변경은 YAGNI로 보류 — 레코드에만 보존.

## 인벤토리 경로 발견

`bin/inv`, 첫 매치 승:

1. `$HOMELAB_INVENTORY_DIR` (명시 override — 테스트 fixture 경로, 최우선)
2. `${XDG_CONFIG_HOME:-$HOME/.config}/homelab-ops` (운영자-로컬 정식 위치)
3. `$REPO_ROOT/inventory` (레거시·예시·테스트 호환)

- "매치" 판정 = 그 디렉터리에 `fleet.yaml` 존재.
- 셋 다 없으면 명확한 에러로 die: 세 후보 경로 전부 + "예시를
  `~/.config/homelab-ops/`로 복사" 안내 출력 → 다음 세션의 Claude가
  안내 없이도 위치를 파악할 수 있게.
- CA 경로 해석(`access.api.ca_path`)의 repo-root-상대 기준은 그대로
  (인벤토리 위치와 독립).
- `SKILL.md` "First-time setup"을 `~/.config/homelab-ops/`로 복사하도록
  갱신 + 발견 순서 3줄 명문화.

## `backup` verb (vzdump)

- 등급/전송: `backup="caution pve"` (테이블이 grade 공급 — guard 코드
  변경 불필요. prod면 기존 규칙대로 `--approve` 필요).
- 인터페이스: `guard backup <target> -- <storage> [mode] [compress]`
  (mode 기본 `snapshot`, compress 기본 `zstd`).
- `bin/pve` verb arm 추가: `POST /nodes/{node}/vzdump`
  (params: `vmid`, `storage`, `mode`, `compress`, `notes-template`).
  vzdump도 UPID 반환 → `pve_wait_task` 재사용.
- dry-run: 실행 없이 대상 vmid·storage·mode·예상 산출물명만 출력
  (SAFETY CONTRACT 준수: 미실행·exit 0).

## 테스트 전략

전부 기존 stub 하니스 + `HOMELAB_INVENTORY_DIR=tests/fixtures` 기반
(라이브 인벤토리와 비결합):

- `test_action_table.sh`: 패리티 3종 + 별칭 해소.
- `test_guard_grade.sh`: `delete`→`destroy` 동일 grade; 유령 verb는
  deny-default destructive.
- `pve_wait_task` 단위: stub PVE가 `running→stopped/OK` /
  `stopped/<err>` / 무한 running(타임아웃 75) 시나리오.
- `test_provision.sh`: clone UPID 완료 후에만 `CREATED` / 실패 시 비-0.
- 감사 스키마: `task_upid`·`task_exitstatus` 채워짐; 타임아웃 시
  `exit:75`+UPID 보존.
- `test_inv.sh`: 3단계 발견 우선순위 + 셋 다 부재 시 에러 메시지에
  세 후보 경로 포함.
- backup: dry-run 비실행·exit 0; prod면 `--approve` 게이트; UPID 폴링.
- 기존 회귀(`test_mask_parity.sh`, `test_guard_exec.sh`,
  `test_guard_plan.sh`, `test_ssh_run.sh`, `test_pve.sh`,
  `test_forensic_sufficiency.sh` 등) 전부 통과.

## 후속 항목 (Follow-on — 본 spec 비구현)

`homelab-ops/TODO.md`에 상태를 갱신해 남긴다:

- **`disk-attach`/`disk-detach`**: PVE API 토큰은 임의 fs 경로
  패스스루를 거부(`Only root can pass arbitrary filesystem paths`)하므로
  전송은 노드 root SSH(`qm set`)여야 함. 인벤토리
  `access.ssh.key_ref: bw://ssh-<id>` ↔ vault 항목 정합화 +
  `bw-put --type note --from-file`로 키 등록이 선행 데이터 작업.
  (#25에서 SSH 전송 경로 자체는 구비됨 — 남은 건 vault 등록.)
- **`remote-migrate`**: SKILL.md가 migration을 명시적 비대상으로 둠.
  스코프 확장 vs 운영자-only 유지(read 검증만 제공)의 정책 결정이 선행.
