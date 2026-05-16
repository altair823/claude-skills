# homelab-ops 설계 문서

작성일: 2026-05-16

## 1. 목적

`~/projects/homelab-ops` 는 Claude Code가 사용자의 홈서버 fleet을 안전하게 운영·프로비저닝·모니터링하기 위한 git 레포다. 핵심 설계 긴장점은 **파괴적 작업에 대한 강한 가드 ↔ 운영 자동화에 충분한 권한**의 균형이며, 모든 작업은 사후 원인 분석이 가능하도록 철저히 기록된다.

## 2. 관리 대상 (fleet)

이종 fleet 전체를 하나로 관리한다:

- 독립 Proxmox 호스트 다수 (클러스터 아님, 각각 별도 관리)
- 그 위의 VM / LXC
- 같은 네트워크의 독립 어플라이언스 (Victoria Metrics, NAS 등)

## 3. 범위

프로비저닝 + day-2 운영 + 모니터링 + 설정 드리프트 점검의 풀스택. 단 프로비저닝은 단계화한다(§9).

## 4. 아키텍처: CLI 스킬 툴킷 + 선언형 인벤토리 (하이브리드)

상시 데몬 없음. git 레포 안의 얇은 래퍼 스크립트를 Claude가 호출하고, 모든 상태 변경은 단일 가드 래퍼를 통과한다. credential은 호출 시점에만 Bitwarden CLI로 해결한다. 기존 환경 패턴(k8s 매니페스트 + 셸 스크립트 + harbor-ops/gitea-ops류 스킬)과 일치한다.

### 4.1 레포 구조

```
homelab-ops/
  inventory/
    fleet.yaml            # fleet 전체 선언 (호스트·VM·LXC·어플라이언스)
    groups.yaml           # 논리 그룹 (pve-hosts, observability, storage 등)
  bin/
    guard                 # 단일 가드 래퍼 — 모든 변경 작업의 chokepoint
    pve                   # Proxmox REST API 클라이언트 래퍼
    ssh-run               # SSH 실행 래퍼 (known_hosts 강제)
    bw-resolve            # bw CLI에서 credential 해결
    forensics             # 감사 로그/스냅샷 기반 타임라인 재구성 조회
  provisioning/           # Phase 2: Ansible/Terraform 백엔드 (guard가 호출)
  logs/
    audit.jsonl           # 추가-전용 감사 로그 (운영자 로컬·git 미추적)
    runs/<세션ID>/<작업ID>.log
  .gitignore              # secret·세션·.env·tfstate 류 전부 제외
  CLAUDE.md               # Claude 작업 철칙
  README.md
```

### 4.2 인벤토리 모델

`fleet.yaml` 엔트리 예시:

```yaml
- id: pve-01
  kind: proxmox-host          # proxmox-host | vm | lxc | appliance
  address: 10.0.0.11
  env: prod                   # prod | lab  (가드 등급 입력)
  access:
    api: { token_ref: "bw://Proxmox pve-01/api-token" }
    ssh: { user: root, key_ref: "bw://ssh/pve-01" }
  children: [vm-100, lxc-201] # 호스트→게스트 관계
  tags: [critical]
```

- credential은 인벤토리에 **참조(`bw://...`)만** 저장, 실제 값은 어떤 파일에도 없음
- `kind`로 작업 종류 결정, `env`/`tags`로 가드 등급 가중

## 5. 보안 코어

### 5.1 Credential 흐름 (Bitwarden 개인 Vault + `bw` CLI)

```
작업 세션 시작
  └─ 사용자가 직접 `bw unlock` 실행 → BW_SESSION 환경변수 획득
       (마스터 비번은 Claude도 파일도 절대 접근하지 않음. 사용자만 입력)
  └─ bin/bw-resolve 가 token_ref/key_ref 를 받아 그 시점에만 bw get 으로 값 해결
       └─ 값은 프로세스 환경/메모리에만, 디스크 기록 금지, 사용 후 unset
  └─ 세션 종료 시 BW_SESSION 폐기 (bw lock 권고)
```

- BW_SESSION이 없으면 모든 변경 작업은 시작조차 하지 않는다 — "잠긴 금고" 기본값
- SSH 키를 bw에 두는 경우 `bw-resolve`는 임시 파일 대신 `ssh-agent` 주입 또는 fd 전달을 사용 (디스크에 키를 떨구지 않음)

### 5.2 접근 계층

- `bin/pve` — Proxmox REST API. 호스트별 **API 토큰** 사용. Proxmox 쪽에서 역할로 권한 최소화(읽기 역할 / 운영 역할 분리 권장). TLS 검증 켬
- `bin/ssh-run` — `StrictHostKeyChecking=yes`로 `known_hosts` 강제. VM/LXC/NAS 내부 작업용. 기존 `~/.ssh/known_hosts` 활용

### 5.3 등급 가드 (`bin/guard` — 단일 chokepoint)

모든 상태 변경은 반드시 `guard <action> <target>` 형태로만 실행한다. Claude는 `pve`/`ssh-run`을 변경 목적으로 직접 호출하지 않는다(CLAUDE.md에 명문화).

| 등급 | 예시 | 동작 |
|---|---|---|
| safe | 목록·상태·메트릭 조회 | 즉시 실행, 감사 로그만 |
| caution | start/stop, 스냅샷 생성, 패키지 설치 | 1줄 요약 표시 후 진행 (env=prod면 승인) |
| destructive | VM/LXC 삭제, 볼륨/스토리지 제거, 강제종료, 네트워크 변경 | dry-run 먼저 → 영향 출력 → 명시 승인 → 실행 |

- 등급은 `action` 종류 × 대상 `env`/`tags`로 산정 (같은 stop이라도 `tags:[critical]`이면 한 단계 격상)
- **deny-by-default**: 등급 매핑에 없는 action은 destructive로 취급
- 모든 실행은 감사 로그에 기록(§6)

## 6. 철저한 기록 / 포렌식

사후 원인 분석을 1급 요구사항으로 둔다.

- 모든 작업(safe 포함)에 **세션 상관 ID + 작업 ID** 부여
- `logs/audit.jsonl` 한 줄당 기록: `시각, 세션ID, 작업ID, actor(claude/사용자), action, target, 등급, 해석된 인벤토리 스냅샷, dry-run 출력 해시, 승인 주체·시각, 종료코드, 소요시간`
- 전체 stdout/stderr 원문은 `logs/runs/<세션ID>/<작업ID>.log`에 보존 (credential은 마스킹 후 기록)
- 작업 직전 대상 상태 스냅샷(VM config, 실행상태 등) 캡처 → 사고 시 전/후 비교로 원인 분석
- `guard` 비정상 종료·중단도 반드시 기록 (실패가 로그 공백이 되지 않게)
- `audit.jsonl`은 **추가-전용**으로만 기록 — 모든 작업(safe·실패·중단 포함)이 누락 없이 한 줄씩 남는 것이 목표. 운영자 로컬 보관 + gitignore. 사후 *변조 탐지*(누가 로그를 고쳤는지 증명)는 **비목표**(§10): 로컬 git은 운영자가 rebase로 과거를 고칠 수 있어 변조 탐지가 성립하지 않으므로 약속하지 않는다. 변조 불가성이 필요하면 외부 WORM/오프호스트 백업을 별도로 둔다
- `bin/forensics`로 세션ID·대상별 타임라인 재구성 조회 제공

## 7. Claude 인터페이스

- `homelab-ops` **글로벌(개인) 스킬 1개** — `~/.claude/skills/homelab-ops/SKILL.md`. harbor-ops/gitea-ops와 정확히 동일한 패턴(글로벌 스킬 + `~/.config/homelab-ops/config` 레포 포인터). 어느 프로젝트에서 작업 중이든 fleet 상태/메트릭 조회 및 `guard` 호출 가능 (cross-project 운영 요구 충족)
- 스킬은 얇은 포인터일 뿐, single source of truth는 git 레포의 *도구*(`bin/`·`inventory/`). `logs/audit.jsonl`은 git 미추적 런타임 산출물이라 SSOT가 아니다(§6). 스킬은 `~/.config/homelab-ops/config`의 `HOMELAB_REPO`(기본 `~/projects/homelab-ops`)로 레포를 찾아 `$HOMELAB_REPO/bin/*` 호출. 안전 모델은 스크립트가 강제하므로 스킬 위치와 무관
- 스킬/설정은 레포에 git-tracked 원본(`skill/SKILL.md`)을 두고 `bin/install-skill`로 1회 설치(idempotent). 상시 미러/심볼링크 없음
- 인벤토리 조회 → 변경은 무조건 `guard` 경유
- `CLAUDE.md` 철칙: guard 우회 금지, 변경 시 BW_SESSION 필수, deny-by-default, 기록 누락 금지

## 8. 테스트

- `guard` 등급 산정 · deny-by-default · 승인 게이트 단위 테스트 (bats 또는 셸 테스트)
- `lab` env 더미 대상으로 safe/caution/destructive 경로 통합 스모크
- 포렌식 검증: 의도적 실패를 주입해 audit.jsonl + run 로그 + 전후 스냅샷이 원인 추적에 충분한지 확인

## 9. 프로비저닝 단계화

사용자 환경에 Terraform/Ansible가 설치되어 있지 않고 사용 경험도 없다. 따라서 IaC는 전제 조건이 아니라 나중 단계로 둔다. `guard provision ...` 인터페이스는 고정하고 그 뒤의 실행 백엔드만 교체 가능하게 설계한다.

- **Phase 1 (지금)**: 프로비저닝을 IaC 없이 — Proxmox API의 clone/create, 필요 시 SSH로 `qm`/`pct`. dry-run은 "무엇을 만들/지울지" 사전 출력으로 구현. 설치할 도구 없음. destructive 등급으로 가드 적용
- **Phase 2 (나중, 선택)**: 같은 `guard provision` 뒤에 Terraform(Proxmox provider)/Ansible 백엔드 추가. 사용 방식·가드·로그는 그대로. Terraform `plan`이 곧 destructive dry-run 산출물. tfstate는 민감정보 포함 → `.gitignore` + 로컬 보관, credential은 `bw-resolve`가 `TF_VAR_*` 환경변수로만 주입

## 10. 비목표 (YAGNI)

- 상시 데몬/서비스, 커스텀 MCP 서버 (공격면·운영부담, bw 세션 모델과 충돌)
- Proxmox 클러스터·HA·마이그레이션 관리 (대상이 독립 호스트 다수)
- Phase 1에서의 IaC 도입
- 감사 로그 변조 탐지(서명 커밋·해시 체인·WORM). 요구는 "누락 없는 기록"까지이며, 변조 불가성은 보장하지 않는다 (필요 시 외부 백업으로 운영자가 별도 확보)
