# homelab-ops guard verb 확장 설계

작성: 2026-05-18
브랜치: `feat/homelab-ops-guard-verbs`
스킬: `homelab-ops`
선행: `2026-05-18-homelab-ops-hardening-design.md` (PR #26, main 머지 완료 — 단일 출처 `ACTIONS` 테이블·패리티 테스트·`pve_wait_task`·감사 `task_upid` 토대를 이 설계가 계승)

## 목적

`homelab-ops/TODO.md` 의 잔여 guard 확장 항목 + 하드닝 final-review 후속을 **단일 통합 PR** 로 정식화한다. 운영자 명시 승인 하 guard 우회로 실행되던 동작들을 1급 guard 지원으로 끌어올려 Hard Rule 1(guard 우회 금지)·Rule 5(감사 무결성)를 정식 충족한다.

범위(4):

1. **인터럽트-UPID 캡처** — guard INT/TERM 경로에서 발행 UPID 를 감사 레코드에 기록(코드 전용, 외부 의존 없음).
2. **`disk-attach` / `disk-detach`** — 물리 디스크 패스스루(`qm set`), transport `host-ssh`, 엄격 안전(by-id 강제 + serial 대조).
3. **`disk-grow`** — 게스트 내부 LVM/파티션/FS 확장, transport `host-ssh` → `qm guest exec`, 레이아웃 자동탐지.
4. **`remote-migrate`** — 노드 간 마이그레이션, transport `pdm`(신규 PDM 클라이언트), SKILL.md 경계 완화.

신규 transport 어휘 2종(`host-ssh`, `pdm`)을 단일 출처 `ACTIONS` 테이블에 1급으로 추가하는 것이 공통 토대다.

비범위(런타임 블로커 — 코드 아님, 이번 PR 의 코드+stub 테스트는 완결):

- disk-attach/detach·disk-grow 의 owner 노드 root SSH 자격 vault 등록(`bw-put`) — 운영자 데이터 작업.
- disk-grow 대상 게스트의 QEMU guest-agent 동작.
- `remote-migrate` 의 인벤토리 `kind: pdm` 엔트리 작성(운영자-로컬). PDM 토큰 자체는 운영자 보유.
- **PDM-disk-attach**: PDM 노드 연결 자격이 `root@pam` 이면 임의 fs 경로 패스스루가 PDM 경유로 풀릴 가능성 — 미검증. `host-ssh` 가 known-correct 기본이고 PDM 경로는 TODO future-probe 로 잔존.

## 구현 순서 (바텀업 — 토대 우선)

1. 공통 transport 인프라.
2. 인터럽트-UPID 캡처(독립·소형).
3. `disk-attach` / `disk-detach`.
4. `disk-grow`.
5. `remote-migrate`.
6. SKILL.md / TODO.md 문서 + 최종 회귀.

각 단계 종료 시 전체 `tests/run.sh` 녹색(중간 커밋도 회귀 없음). 패리티 테스트가 매 단계 단일-출처 드리프트를 차단한다.

## 아키텍처 & 컴포넌트 맵

| 파일 | 변화 |
|---|---|
| `bin/_lib.sh` | `ACTIONS` 에 4 verb 추가; transport 어휘 `none\|pve\|ssh\|guest` 에 `host-ssh`·`pdm` 추가; `op_transport` 가 신규 토큰 해석; `pve_wait_task` 옆 `pdm_wait_task`(동일 계약) 추가 |
| `bin/pdm` (신규) | PDM API 클라이언트. PVE 와 별개 base URL(인벤토리 `kind: pdm` 엔트리 address), `PDM_TOKEN` env(bw-exec 주입) 헤더, `access.api.ca_path` → `--cacert`(TLS ON, 미주입 fail-closed exit 3). `bin/pve` CA/실패-닫힘 패턴 미러. `pdm api <M> <path> [data]` + remote-migrate 고수준 sub |
| `bin/_backend` | `disk-attach:*`/`disk-detach:*`/`disk-grow:*` → `ssh-run "$(owner_host "$t")" -- ...`; `remote-migrate:*` → `bin/pdm`. 각 dry-run 안전 계약(미실행·exit 0) |
| `bin/guard` | 자격 게이트 + `--plan` 이 `host-ssh`→`owner_host(target)` 의 `access.ssh` ref, `pdm`→`kind: pdm` 엔트리 `access.api.token_ref` 산출; `_finish_trap`(INT/TERM)이 감사 전 `$rl` 에서 raw UPID 스크레이프 |
| 인벤토리 (`fleet.example.yaml`) | `kind: pdm` 엔트리(address + `access.api.token_ref` + `ca_path`); 게스트 디스크 `serial` 필드 예시. 실 인벤토리는 운영자-로컬(gitignored) |
| `SKILL.md` | "Not for: …migration" 경계 완화; 신규 verb·transport·인벤토리 문서화; frontmatter description 갱신 |
| `TODO.md` | #2/#4 해소 표시; PDM-disk-attach future-probe; 잔여 런타임 블로커 기록 |
| `tests/` | 패리티 확장 + 신규 stub(`pdm`, `qm`, `qm guest exec`) + 신규 fixture + verb별 테스트 |

핵심 원칙(하드닝 계승): **transport 는 단일 출처 테이블, verb 행위는 backend/클라이언트에 국소화, 드리프트는 패리티 테스트가 차단, 모든 변경은 dry-run + `--approve` + 감사.**

## 1. 공통 transport 인프라

### ACTIONS 테이블 (단일 출처)

```bash
[disk-attach]="destructive host-ssh"  [disk-detach]="destructive host-ssh"
[disk-grow]="destructive host-ssh"    [remote-migrate]="destructive pdm"
```

### `op_transport` 토큰 해석 확장

기존 반환값은 `pve|ssh|none`. 신규 토큰:

- `host-ssh` → `ssh` 로 해석하되 **대상이 `owner_host(target)`**. backend 는 `ssh-run "$(owner_host "$target")" -- ...`. 자격 게이트/`--plan` 은 owner_host 엔트리의 `access.ssh`(키→`HL_SSH_KEY` / 패스워드→`HL_SSH_PASS`) ref 산출 — target 자신 아님.
- `pdm` → backend 는 `bin/pdm`. 게이트/`--plan` 은 `kind: pdm` 엔트리의 `access.api.token_ref` → `PDM_TOKEN`.

`op_transport` 시그니처는 유지하되, `host-ssh` 의 owner_host 치환은 backend·게이트·`--plan` 의 공통 헬퍼(`resolve_cred_target`: transport=host-ssh 면 `owner_host(target)`, 아니면 target)로 일원화해 세 곳이 같은 판단을 쓴다.

### `bin/pdm` 클라이언트 (신규)

- 인벤토리에서 `kind: pdm` 엔트리 1개 조회(0개 또는 2개 이상이면 명확한 die). `address` 로 PDM API base URL 구성, `PDM_TOKEN` 헤더, `access.api.ca_path` 로 `--cacert`(절대/`~`/repo-root-상대 해석은 `bin/pve` 와 동일 규칙; 선언됐으나 미독출 시 fail-closed). `PDM_TOKEN` 미주입 시 exit 3 + 정확한 `bw-exec` 안내.
- sub: `api <METHOD> <path> [data]`(범용) + `remote-migrate` 고수준 sub(아래 §5).
- PDM 비동기 작업은 PDM task 식별자 반환.

### `pdm_wait_task` (`_lib.sh`)

`pve_wait_task` 와 **동일 계약**: PDM task 상태를 `bin/pdm api GET` 로 폴링, 완료 시 `HO-TASK upid=<id> exitstatus=<s>` 를 stdout emit, 반환 `0`(OK)/`1`(실패)/`75`(타임아웃). `HOMELAB_TASK_TIMEOUT`(기본 600)·`HOMELAB_TASK_POLL_INTERVAL`(기본 2) 재사용(정수 검증 동일). guard 의 post-hoc `HO-TASK` 파싱이 PVE 와 동일하게 `task_upid`/`task_exitstatus` 캡처(transport 무관).

### 자격 게이트 / `--plan` 확장 (`bin/guard`)

비-safe op:

- transport `host-ssh`: `cred_target = owner_host(target)`. 그 엔트리 `access.ssh.auth` 가 `password` 면 `HL_SSH_PASS` ref, 아니면 `HL_SSH_KEY` ref. 부재 시 exit 3 + `bw-exec` 라인.
- transport `pdm`: `kind: pdm` 엔트리 `access.api.token_ref` → `PDM_TOKEN`. 부재 시 exit 3.

`--plan` 은 read-only(인벤토리만), 시크릿 미접근 — 기존 계약 유지.

### 패리티 테스트 확장 (`tests/test_action_table.sh`)

- 신규 4 verb 가 비-safe + backend arm 존재(direction 1).
- `_backend`/`bin/pdm` 가 디스패치하는 verb 가 ACTIONS 에 존재(direction 2).
- 신규 transport 토큰(`host-ssh`/`pdm`)이 `op_transport` 해석과 backend 라우팅에 일관.
- 별칭 무결성(기존) 유지.
- vacuous-pass 가드·통일 `finish` 보고(하드닝에서 확립) 계승.

## 2. 인터럽트-UPID 캡처 (코드 전용)

**문제:** mutating op 가 task 폴링 중 INT/TERM → `_finish_trap` 이 exit 130/143 로 감사 1건 정확 기록(로그 갭 없음). 그러나 post-hoc `HO-TASK` 파싱은 폴링 완료 후라 인터럽트 경로 미실행 → 감사 `task_upid` = `null`(발행 UPID 는 run-log raw `{"data":"UPID:..."}` 에만 잔존).

**설계:** `_finish_trap` 이 감사 쓰기 전에 `$rl` 스크레이프로 `task_upid` best-effort 채움:

- 우선순위 1: `$rl` 에 `HO-TASK upid=… exitstatus=…` 라인 존재 → 그 값 사용(정상 종료 직전 인터럽트).
- 우선순위 2: 없으면 run-log 의 backend 응답에서 raw `UPID:[^"]*` 마지막 매치 → `task_upid`. 이 경우 `task_exitstatus` 는 `null` 유지("수락됐으나 결과 미상" 을 정직히 표현).
- best-effort·`|| true`: 스크레이프 실패해도 감사 1건 정상 기록(Rule 5 불변). 현 동작 대비 안전성 동일, `task_upid` 정확성만 향상.
- 정상 종료 경로의 기존 post-hoc 파싱(`bin/guard` 후미)은 그대로(이중 안전). `_DONE` 가드로 단일-기록 보장 유지 — 스크레이프 한 단계만 트랩 진입부에 선행.

**범위 밖:** 고아 백엔드 reaping(인터럽트 시 자식이 ~600s 계속 폴링하는 노출창)은 caveat 주석+TODO 에 이미 명문화. 본 항목은 *기록 정확성* 만 개선.

## 3. disk-attach / disk-detach

transport `host-ssh` → `ssh-run "$(owner_host "$target")" -- ...`(owner Proxmox 노드 root SSH, `qm` 실행). 등급 둘 다 **destructive**.

### 인터페이스

- `guard disk-attach <guest> -- --by-id <id> [--bus scsi] [--index N]`
- `guard disk-detach <guest> -- --index N` (또는 `--bus scsiN`)

`<guest>` 인벤토리에서 `vmid` 해석, owner_host 는 `owner_host(<guest>)`. by-id/serial 해석은 owner 노드 기준.

### 안전 계약 (엄격, backend 강제)

1. **by-id 강제**: `--by-id` 가 `/dev/disk/by-id/...` 형식이 아니면(`/dev/sdX`·`/dev/nvme…` 등 비안정 경로 포함) 즉시 거부. 노드 재부팅 시 `sdX` 재배치 오인 패스스루 차단.
2. **serial 대조**: 인벤토리 게스트 엔트리에 선언된 디스크 `serial` 과, 노드에서 by-id 장치의 실제 serial(`lsblk -ndo SERIAL` 또는 `udevadm info`)을 대조. 불일치 거부. **serial 미선언이면 거부**(명시적 opt-in 강제 — "아무 디스크나" 차단).
3. **dry-run**: 해석된 by-id → 실제 `/dev/sdX` 매핑, serial 대조 결과, 적용될 정확한 `qm set` 명령 echo. 미적용·exit 0.
4. **attach 적용**: `qm set <vmid> -<bus><index> <by-id-path>,backup=0,iothread=1`. `--index` 미지정 시 빈 슬롯 자동 탐색(dry-run 에 결정된 인덱스 표기).
5. **detach 적용**: `qm set <vmid> -delete <bus><index>`. config 에서만 제거(물리 데이터 비파괴)이나 보수적으로 destructive 유지(오인 detach 도 게스트 가용성 타격).

### 테스트 (stub)

`ssh`/`qm` 스텁이 by-id↔sdX↔serial 픽스처 모사. 케이스: by-id 비안정경로 거부, serial 불일치 거부, serial 미선언 거부, dry-run 미적용+명령 echo, attach/detach 명령 형성, `host-ssh` 게이트/`--plan`(owner_host ref), 패리티.

## 4. disk-grow

transport `host-ssh` → `ssh-run "$(owner_host "$target")" -- qm guest exec <vmid> -- <cmd>`(owner 노드 root SSH 경유, QEMU guest-agent 필수, 직접-SSH fallback 없음). 등급 **destructive**.

### 인터페이스

`guard disk-grow <guest> -- [--lv <vg/lv>]` — 단일 LVM 루트 레이아웃이면 자동탐지; 다중 PV/LV 등 모호 시 `--lv` 명시 요구.

### 시퀀스 (탐지 → 적용)

1. **탐지(read-only, dry-run·실행 공통 선행)**: `qm guest exec` 로 `lsblk -Jbo NAME,TYPE,SIZE,MOUNTPOINT,FSTYPE` + `pvs/vgs/lvs --reportformat json` + `findmnt -J` 수집·파싱 → 늘릴 디스크/파티션, PV, LV, FS 타입(ext4/xfs), 마운트포인트 결정.
2. **dry-run**: 탐지 레이아웃 + 실행될 정확한 명령 시퀀스 echo, 미적용·exit 0:
   `growpart /dev/sdX N` → `pvresize /dev/sdXN` → `lvextend -l +100%FREE <vg/lv>` → FS 분기: ext4 `resize2fs <lv>` / xfs `xfs_growfs <mnt>`. 그 외 FS 거부(미지원 명시). dry-run 헤더에 **"PVE 레벨 가상디스크 확장은 본 verb 범위 밖 — 게스트 내부 전용, PVE 디스크는 사전 확장 전제"** 명시.
3. **적용(--approve 후)**: 동일 시퀀스를 `qm guest exec` 순차 실행. 각 단계 비-0 시 중단+감사. online 확장(언마운트 없음).

### 안전장치

- 탐지 실패(guest-agent 미동작/미설치, 비표준 레이아웃, 다중 후보 + `--lv` 미지정, 미지원 FS) → 적용 전 거부, dry-run 에 사유. 추측 실행 없음.
- `growpart`/`pvresize` 는 "이미 최대" 시 무해 종료(멱등). `qm guest exec` 출력(JSON `out-data`/`exitcode`) 파싱해 단계별 판정, 감사·run-log 에 시퀀스 결과 기록.

### 테스트 (stub)

`ssh`/`qm guest exec` 스텁이 lsblk/pvs/lvs/findmnt JSON 픽스처 반환. 케이스: 단일 레이아웃 자동탐지, 다중후보→`--lv` 요구 거부, ext4/xfs 분기, 미지원 FS 거부, guest-agent 실패 거부, dry-run 미적용+시퀀스 echo, `host-ssh` 게이트/`--plan`, 패리티.

## 5. remote-migrate

transport `pdm`, 등급 **destructive**.

### 인터페이스

`guard remote-migrate <guest> -- --to <target-node> [--target-storage <src:dst,...>] [--online]`. `<guest>` 로 source node·vmid 인벤토리 해석.

### 동작

- backend: `bin/pdm` 고수준 `remote-migrate` sub → PDM 원격 마이그레이션 API(`POST` 계열; params: source/target node, vmid, storage map, online). PDM 비동기 task id 반환 → `pdm_wait_task` 폴링, `HO-TASK` emit → guard 감사 `task_upid`/`task_exitstatus`.
- **명시적 known-unknown**: PDM API 의 정확한 엔드포인트 경로·페이로드 스키마·task 상태 경로는 PDM 버전에 따라 달라 본 설계에서 단정하지 않는다. 구현 계획 단계에서 운영자 PDM 버전의 API 문서로 확정한다. `bin/pdm` 의 범용 `api <METHOD> <path> [data]` sub 가 어댑터 역할을 하므로 고수준 sub 만 버전별로 좁히면 되고, stub 테스트는 확정 전에도 응답 계약(task id 반환 → `pdm_wait_task` → `HO-TASK`)으로 검증 가능. 확정 실패 시(문서 부재 등) remote-migrate 만 분리해 보류하고 나머지 3 항목으로 PR 진행하는 것을 fallback 으로 둔다.
- dry-run: source/target node, vmid, storage-map, online echo. 미적용·exit 0. PDM API 에 preflight/dry 엔드포인트가 있으면 read-only 호출해 결과 포함; 없으면 인벤토리 기반 계획만(미적용 보장 우선).
- 자격 게이트/`--plan`: `pdm` → `kind: pdm` 엔트리 `access.api.token_ref` → `PDM_TOKEN` 부재 시 exit 3.

### SKILL.md 경계 재문구

- "Not for: … Proxmox cluster/HA/migration" → **"PDM 경유 노드 간 `remote-migrate` 는 지원(독립 노드 대상). intra-cluster HA·live-migration·로컬 클러스터 migration 은 여전히 비대상."**
- "When to use" 에 `remote-migrate` 불릿; frontmatter description 에 포함; Inventory 절에 `kind: pdm` 엔트리·신규 transport·디스크 `serial` 필드 문서화.

### 테스트 (stub)

`pdm` 스텁(원격 마이그레이션 응답·task 상태). 케이스: 등급 destructive, dry-run 미적용+계획 echo, `PDM_TOKEN` 게이트 exit 3, `--plan` PDM ref, `pdm_wait_task` OK/실패/타임아웃75, 패리티(`pdm` transport↔backend), `kind: pdm` 엔트리 0/다중 시 die.

## 테스트 전략 (공통)

전부 offline stub-driven, `HOMELAB_INVENTORY_DIR=tests/fixtures`. 신규 fixture: `kind: pdm` 엔트리, 게스트 디스크 `serial` 필드, owner_host root ssh ref. 신규 stub: `pdm`, `qm`, `qm guest exec`. 기존 17 테스트 전부 회귀 녹색 유지(추가 전용 + 신규 transport 는 기존 토큰 동작 불변). 인터럽트-UPID 는 INT 경로 raw-UPID 스크레이프를 stub 백엔드+신호로 검증.

## Hard Rule 준수 (설계 차원)

1. guard 우회 금지: 4 verb 전부 `bin/guard` 경유, backend/`bin/pdm`/`ssh-run` 은 transport-only.
2. 자격 fail-closed: `host-ssh`→owner_host ssh ref / `pdm`→`PDM_TOKEN` 부재 시 exit 3.
3. deny-by-default: 신규 verb 는 의도적으로 ACTIONS 등록(임의 추가 금지), 패리티 테스트가 강제.
4. destructive 가시화: 4 verb 전부 destructive → dry-run + `--approve` 게이트(기존 경로 불변, prod 승급 동일).
5. 로그 갭 없음: 인터럽트-UPID 는 `_finish_trap` 단일-기록 보장을 훼손 않고 정확성만 향상; PDM task 도 `HO-TASK`/감사 동일.
6. 시크릿 미노출: `PDM_TOKEN`/SSH 자격은 bw-exec env 주입, 마스킹 파이프라인 통과; `bin/pdm` 도 토큰 헤더-only·디스크 미기록. dry-run·에러 메시지에 raw 응답 무경계 노출 금지(하드닝 phase1 교훈 계승 — 경계화).
7. provisioning Phase 1 불변: 본 작업은 guard verb 확장으로 provision 인터페이스 무관.

## 후속 (TODO.md 기록, 본 PR 비구현)

- PDM-disk-attach: PDM 노드 연결 자격이 root@pam 이면 임의 fs 경로 패스스루가 풀릴 가능성 — 실측 후 transport 양자택일 검토.
- 고아 백엔드 reaping(인터럽트 시 자식 폴링 노출창) — 별도 검토(하드닝 TODO 잔존 유지).
- 런타임 자격 등록(노드 root SSH / `kind: pdm` 엔트리 / guest-agent)은 운영자 데이터 작업.
