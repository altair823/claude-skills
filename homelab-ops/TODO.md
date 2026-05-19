# homelab-ops — 잔여 선행과제 (코드 아님)

최초 작성 2026-05-17 / 갱신 2026-05-19.

원래 이 파일이 추적하던 **guard 확장 코드 작업은 전부 머지 완료**다:

- `backup`(vzdump)·단일 `ACTIONS` 테이블·PVE task 폴링·유령 verb 정리·
  인벤토리 발견 — **PR #26** (`docs/superpowers/specs/2026-05-18-homelab-ops-hardening-design.md`).
- `disk-attach`/`disk-detach`(host-ssh, by-id 강제·serial opt-in·적용 전
  serial 실대조)·`disk-grow`(host-ssh→`qm guest exec`, 레이아웃 자동탐지)·
  `remote-migrate`(pdm)·인터럽트-UPID 캡처(`_finish_trap` rl 파싱,
  PVE/PDM raw `{"data":"<id>"}` 폴백) — **PR #27**
  (`docs/superpowers/specs/2026-05-18-homelab-ops-guard-verbs-design.md`).

남은 것은 스킬 코드가 아니라 **운영자-측 데이터 선행과제**와 **명시적
비범위로 미룬 설계 1건**뿐이다.

## 런타임 블로커 (운영자 데이터 작업 — 코드 변경 없음)

이 자격/데이터가 준비돼야 해당 verb 가 실제 동작한다(코드는 이미 머지됨).

- **disk-attach / disk-detach / disk-grow**: 3개 Proxmox 노드 root SSH 키를
  vault(`bw://ssh-pve-*/notes`, `--type note`)에 등록 완료 + 인벤토리
  `key_ref` 를 `/notes` 로 정합화 완료(2026-05-19). → 노드 대상 동작 가능.
  남은 per-target: disk-grow 는 대상 게스트 QEMU **guest-agent 동작** 필요
  (`qm guest exec`; 미동작 시 게스트 직접 SSH 필요한데 인벤토리에 게스트
  `address`/ssh ref 부재가 흔함), disk-attach 는 게스트 엔트리
  `disks[].serial` opt-in 선언. 어플라이언스(metrics-01/nas-01) ssh 키는
  필요 시 동일 `bw-put` 로 등록. 관련 메모리: `project_homelab_ssh_and_pdm.md`.
- **remote-migrate**: 블로커 해소(2026-05-19). `pdm-01` 을 `kind: pdm`
  (`address: 192.168.0.46:8443`, `access.api.token_ref` →
  `bw://PDM pdm-01/api-token`, `ca_path`)로 인벤토리 전환, PDM API 토큰을
  full-form(`authid=secret`)으로 vault 등록, PDM cert 를 `IP:192.168.0.46`
  SAN 포함해 재발급(백업 보존)해 IP `--cacert` TLS 검증 통과.
  **발견·수정한 코드 결함**: `bin/pdm` 이 `Authorization: PVEAPIToken=` +
  `authid=secret` 로 하드코딩돼 있었으나, PDM 은 PBS 계열 스택이라 실제
  스킴은 `PDMAPIToken=` + `authid:secret`(콜론) — TDD 로 `test_pdm.sh`
  실패 재현 후 `bin/pdm` 수정(첫 `=` 분리 → 콜론 결합), 실 PDM
  `GET /version` 200 확인. `base_path` 기본값 `/api2/json` 은 PDM 1.0 에서
  검증됨. **남은 known-unknown**: `migrate_path` 등 마이그레이션 API path 는
  인벤토리 구성형 — 실제 첫 마이그레이션 실행 때 실값 확정 필요.

## 명시적 비범위 — 별도 검토 보류

- 폴링 도입으로 guard INT/TERM 인터럽트 노출창이 ~600s
  (`HOMELAB_TASK_TIMEOUT`)로 확장됨. `pve_wait_task`/`pdm_wait_task` 가
  남긴 **고아 백엔드 task reaping 미구현**. 감사 1건 보장(Rule 5)은
  유지되나(`_finish_trap` 가 in-flight UPID 복구), 진행 중 task 자체를
  정리하진 않음. 필요해지면 별도 brainstorm 으로 다룬다.
- **PDM-disk-attach future-probe**: PDM 노드 연결 자격이 `root@pam` 이면
  임의 fs 경로 패스스루가 PDM 경유로 풀릴 가능성 — 현재는 host-ssh 가
  known-correct 기본, PDM 경로는 실측 후 검토.
