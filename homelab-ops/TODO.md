# homelab-ops — guard 확장 TODO

작성: 2026-05-17 (workspace-02 이전 작업 중 발견)

## 배경
workspace-02(vmid 201) 를 pve-c64m96-01 → pve-c8m128-01 로 이전 + HDD 물리
디스크 패스스루하는 작업에서, 다음 동작이 guard/`_backend`/`bin/pve` 에 **없어**
운영자(owner) 명시 승인 하에 guard 우회로 실행됨. Hard Rule 1(guard 우회 금지)
+ Rule 5(감사 무결성)를 정식으로 충족하려면 guard 에 1급 지원 추가 필요.

현재 `_backend`/`bin/pve` 가 지원하는 mutating 동작:
`start | stop | restart | destroy | snapshot | pkg-install | provision` 뿐.

## 추가가 필요한 guard 액션

### 1. `backup` (vzdump)
- 전송: pve (API `POST /nodes/{node}/vzdump`, params: vmid, storage, mode,
  compress, notes-template)
- 제안 등급: **caution** (백업 자체는 비파괴적이나 I/O·스토리지 영향). prod 면
  현행 규칙대로 caution+prod → 승인 필요.
- dry-run: 실행 안 하고 대상 vmid/스토리지/예상 산출물명만 출력.
- `bin/pve` 에 `backup <vmid> <storage> [mode] [compress]` verb 추가 +
  `_backend` 의 mutating arm + `_lib.sh op_transport` 동기 갱신.

### 2. `disk-attach` / `disk-detach` (qm set -scsiN / -delete scsiN)
- 전송: pve (API `POST /nodes/{node}/qemu/{vmid}/config`,
  body 예: `scsi1=/dev/disk/by-id/...,backup=0,iothread=1`)
- 제안 등급: **destructive** (물리 디스크 패스스루·디스크 토폴로지 변경, 오인
  시 데이터 파괴). dry-run 에 해석된 device by-id + 옵션 echo, 실제 미적용.
- detach 는 config 에서 제거(데이터 비파괴) → caution 고려 가능하나 보수적으로
  destructive 유지 권장.
- by-id 경로 강제(‐ `/dev/sdX` 거부), serial 대조 훅 권장.
- ⚠️ **실측 제약(2026-05-17)**: 임의 fs 경로 패스스루(`scsi1=/dev/disk/by-id/...`)는
  PVE API 토큰으로 거부됨 — `"Only root can pass arbitrary filesystem paths"
  (PVE/Storage.pm:651)`. 즉 이 verb 의 transport 는 **pve API 가 아니라 노드
  root SSH (`qm set`)** 여야 함. → guard `disk-attach` 백엔드는 ssh 전송으로
  설계할 것. 그러려면 노드 root SSH 자격증명이 필요한데, 현재 인벤토리
  `access.ssh.key_ref: bw://ssh-pve-c8m128-01` 가 vault 에 **부재**(실 자격은
  `192.168.0.81` 항목 추정, 패스워드성). 인벤토리 ssh ref ↔ vault 항목 정합화
  + (키 인증이면) `bw-put --type note --from-file` 로 키 등록이 선행 과제.

### 3. `remote-migrate` (독립 노드 간 / PDM)
- 전송: pve (API `POST /nodes/{node}/qemu/{vmid}/remote_migrate` 계열) 또는
  PDM API. 현재 SKILL.md 는 마이그레이션을 명시적 비대상으로 둠 — 정책 결정
  필요(스코프 확장 vs 계속 운영자-only 로 두되 read 검증만 제공).
- 제안 등급: **destructive** (running prod VM 이동, 되돌리기 어려움).
- dry-run: source/target/vmid/storage-map/online 여부만 출력.

### 4. `disk-grow` (게스트 내부 LVM/파티션/FS 확장)
- 발견: 2026-05-18, namu-crawler(vmid 301, pve-c8m128-01) 디스크 풀참 작업 중.
  PVE 레벨 가상디스크는 이미 확장됐으나 게스트 내부 partition/PV/LV/FS 가
  안 늘어남. 운영자 명시 승인 하에 guard 우회(호스트 경유 `qm guest exec`)로
  실행됨. Hard Rule 1 정식 충족하려면 guard 1급 지원 필요.
- 전송: **ssh (게스트)** 또는 **pve 호스트 SSH 경유 `qm guest exec <vmid>`**.
  현 인벤토리상 대다수 게스트는 직접 `address`/`access.ssh` 가 없어 호스트
  경유가 현실적. → 백엔드는 owner_host SSH → `qm guest exec` 설계 권장
  (QEMU guest agent 필요; 없으면 게스트 직접 SSH fallback).
- 시퀀스(전형적 Ubuntu cloud LVM 레이아웃):
  `growpart /dev/sdX N` → `pvresize /dev/sdXN` →
  `lvextend -l +100%FREE <lv>` → `resize2fs <lv>`(ext4) 또는
  `xfs_growfs <mnt>`(xfs). 레이아웃 자동 탐지(lsblk/pvs/lvs/findmnt) 선행.
- 제안 등급: **destructive** (파티션 테이블·FS 변경, 오인 시 데이터 파괴).
  online 확장은 비교적 안전하나 보수적으로 destructive 유지 + dry-run 에
  탐지된 레이아웃·실행될 명령 시퀀스 echo, 실제 미적용.
- ⚠️ 제약: guest agent 미설치/미동작 시 `qm guest exec` 불가 → 게스트 직접
  SSH 필요한데 인벤토리에 address/ssh ref 부재가 흔함. 인벤토리에 게스트
  접속정보 보강 또는 guest-agent 의존 명문화 필요.

## 공통 요구
- 각 verb 추가 시: `bin/pve` case arm + `_backend` mutating arm +
  `_lib.sh op_transport` 동명 arm **3곳 동기 갱신**(주석에 명시된 단일 출처 계약).
- `GRADE[]` 테이블(`bin/guard`)에 등급 등록(deny-by-default 회피용 임의 추가 금지
  — 의도적 확장).
- dry-run 안전 계약 준수(SAFETY CONTRACT: 미실행·exit 0).
- audit/runlog 자동 적용됨(guard 경유 시) — 별도 작업 불필요.
- 테스트: `tests/fixtures` 기반으로 dry-run/grade/credential-gate 케이스 추가.

## 진행 상태 (2026-05-18 하드닝 spec)
- guard task 폴링·단일 테이블·유령 verb 정리·인벤토리 발견·`backup` verb 는
  `docs/superpowers/specs/2026-05-18-homelab-ops-hardening-design.md` 로 처리.
- `disk-attach`/`disk-detach`: 코드 경로(#25 SSH 전송)는 구비. **선행 블로커**:
  vault 에 노드 root SSH 키 `bw-put --type note --from-file` 등록 (데이터 작업).
- `remote-migrate`: SKILL.md "Not for: …migration" 정책 변경 결정이 선행.
