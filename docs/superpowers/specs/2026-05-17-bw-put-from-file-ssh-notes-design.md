# homelab-ops SSH-transport 자격 정렬: bw-put `--from-file`(키/notes) + 패스워드-SSH

날짜: 2026-05-17
관련 스킬: bitwarden-ops, homelab-ops

## 1. 문제

homelab-ops 의 SSH-transport 옵(`pkg-install`, appliance `stop` 등)이 실제
fleet 에서 동작하지 못한다. 두 갈래:

**(A) 키 인증 갭**
- `ssh-run` 은 `HL_SSH_KEY` 에 완전한 multi-line PEM 키를 기대
  (`printf '%s\n' "$HL_SSH_KEY" | ssh-add -`).
- `bw-put` 의 유일한 비밀 입력은 `IFS= read -rs < /dev/tty` 한 줄 읽기 →
  multi-line 키 저장 불가. 파일 입력은 테스트 전용 env 뿐.
- bitwarden-ops 는 키를 item **notes** 에 두는 설계인데, homelab-ops
  `guard --plan` 은 `HL_SSH_KEY=bw://ssh-<id>`(슬래시 없음)를 내보내 `bw-get`
  이 **password 필드**로 해석 → notes 와 어긋난 잠재 버그.

**(B) 패스워드 인증 미지원**
- fleet 의 일부 VM/LXC 및 NAS 는 SSH **패스워드** 인증만 가능.
- `ssh-run` 은 `-o BatchMode=yes` + ssh-add(키 전용). BatchMode=yes 는
  패스워드 인증을 구조적으로 차단 → 이 호스트들은 homelab-ops 로 조작 불가.

## 2. 목표 / 비목표

**목표**
- 로컬 multi-line SSH 키 파일을 사용자가 vault item notes 에 등록하는
  정식 경로 (Part A).
- homelab-ops 가 notes 키를 변형 없이 사용하도록 정렬 (Part A).
- 패스워드 인증 SSH 호스트를 guard 경유로 비대화식 조작 (Part B).
- bitwarden-ops hard rule(특히 #4 bw-put user-run) 보존. 키 경로 회귀 없음.

**비목표 (명시)**
- PDM(Proxmox Datacenter Manager) 마이그레이션 — 별도 brainstorming→spec
  사이클, approval-gated 로 예정.
- 대화식 SSH(사용자 프롬프트) — 모든 경로 비대화식.
- 키↔패스워드 자동 폴백 — 인증 방식은 인벤토리에 명시(아래 3.4).

## 3. 설계

### 3.1 컴포넌트 ① — bitwarden-ops `bw-put --from-file PATH`

`bw-put` 에 `--from-file PATH` 플래그 추가.

- 인터페이스:
  `bw-put bw://<item>[/<field>] [--type note|password|field] --from-file PATH [--replace]`
- 비밀을 `/dev/tty` 대신 **`PATH` 파일 바이트 그대로** 읽음(multi-line 보존).
  파일은 사용자 머신 로컬(동일 단일사용자 신뢰모델).
- **user-run 유지**: Claude 는 명령줄만 구성·제시, 실행 안 함(hard rule #4).
  `_read_secret` 의 한 분기로 추가하되 테스트 전용
  `BITWARDEN_OPS_TEST_SECRET_FILE` 와는 별개의 명시적 사용자 인자 경로.
- fail-closed: 파일 미존재/미가독 die, 빈 파일 die("빈 값 미등록" 재사용),
  기존 non-empty 값 + `--replace` 없음 die.
- 값 흐름·캐비엇은 기존(`jq --arg`)과 동일, 새 노출 면 없음. type 미지정 시
  ref 모양 추론(`/notes`→note) 그대로.

### 3.2 컴포넌트 ② — 규약: SSH 키는 item notes

- SSH private key 는 vault item **notes** 에 저장, 참조 `bw://<item>/notes`
  (REF_KIND=notes → `bw get notes` multi-line 보존).
- 등록(사용자 실행):
  `bw-put bw://ssh-<id>/notes --type note --from-file <키파일>`

### 3.3 컴포넌트 ③ — homelab-ops 키 경로 정렬 (로직 변경 0)

- 인벤토리 `access.ssh.key_ref` 를 `bw://ssh-<id>/notes` 규약으로.
- `guard --plan` ssh arm 은 key_ref 를 verbatim 으로
  `HL_SSH_KEY=<key_ref>` 출력 → bw-exec→bw-get(notes) → ssh-run 이 완전한
  PEM 수신. **guard/ssh-run 키 경로 로직 수정 불필요.**
- 변경: `homelab-ops/SKILL.md`, `fleet.example.yaml`, bitwarden-ops
  `SKILL.md`(--from-file 사용법) 문서·예시.

### 3.4 컴포넌트 ④ — homelab-ops 패스워드-SSH (Part B, 로직 변경 있음)

**인벤토리 스키마 (명시 auth 필드)**
```yaml
access:
  ssh: { user: u, key_ref: "bw://ssh-x/notes" }                 # auth 기본 key
  ssh: { user: u, auth: password, pass_ref: "bw://ssh-y-pass" } # 패스워드
```
- `auth` 미지정 = `key`(하위호환). `auth: password` 면 `pass_ref` 필수
  (없으면 인벤토리 데이터 오류로 처리).

**`bin/ssh-run`**
- `auth` 조회. `key`(기본): 기존 경로 불변(ephemeral ssh-agent + ssh-add +
  `BatchMode=yes`).
- `password`: `HL_SSH_PASS` 필요(없으면 fail-closed exit 3). `sshpass`
  부재 시 fail-closed(명확한 메시지). 실행:
  `SSHPASS="$HL_SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=yes
   -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -o BatchMode=no
   -o PubkeyAuthentication=no -o PreferredAuthentications=password
   "${user}@${addr}" -- "$@"`
  - 비번은 SSHPASS env 로만 전달(argv 노출 X). StrictHostKeyChecking=yes 유지
    (호스트키 검증 불변). PubkeyAuthentication=no 로 키 시도 잡음 제거,
    BatchMode=no 로 패스워드 인증 허용(대화 프롬프트는 sshpass 가 비대화 처리).

**`bin/guard` `--plan` ssh arm**
- target 의 `access.ssh.auth` 가 `password` 면 `HL_SSH_PASS=<pass_ref>`,
  아니면 `HL_SSH_KEY=<key_ref>` 출력. (transport 결정은 기존 op_transport
  ssh 그대로 — 단일 출처 불변, 자격 변수만 분기.)

**`bin/guard` credential gate**
- ssh transport + non-safe 일 때: auth=password → `HL_SSH_PASS` 부재 시
  exit 3; auth=key → 기존대로 `HL_SSH_KEY` 부재 시 exit 3.

**`bin/_lib.sh` `mask()` + `bin/guard` inline sed**
- `HL_SSH_PASS=`, `SSHPASS=` 값 마스킹 규칙 추가. 두 곳의 규칙 목록은
  byte-identical 유지(`test_mask_parity` 계약).

**의존성**
- `sshpass` 를 조건부 의존성으로 추가(패스워드 호스트 조작 시에만 필요).
  `SKILL.md` deps 줄에 명시. key-only 운용자는 불필요.

## 4. 데이터 흐름

키(Part A):
```
~/.ssh/<key> ─(사용자)bw-put bw://ssh-<id>/notes --type note --from-file→ vault.notes
guard --plan stop <t> → HL_SSH_KEY=bw://ssh-<id>/notes
bw-exec → bw-get(notes) → HL_SSH_KEY=<PEM> → ssh-run: ssh-add → ssh
```
패스워드(Part B):
```
<비번> ─(사용자)bw-put bw://ssh-<id>-pass→ vault.password (single-line, tty 경로)
guard --plan stop <t>  (inv auth=password) → HL_SSH_PASS=bw://ssh-<id>-pass
bw-exec → bw-get(password) → HL_SSH_PASS=<pw>
  → ssh-run: SSHPASS=$HL_SSH_PASS sshpass -e ssh … → ssh
```

## 5. 테스트 (TDD, stub-구동 오프라인)

**bitwarden-ops**
- `--from-file`: 파일 내용 notes 에 byte-verbatim(개행 보존); 파일 미존재
  die; 빈 파일 die; `--replace` 동작; `--from-file` 없을 때 tty 경로 불변.

**homelab-ops** (stub `ssh`/`ssh-add`/`ssh-agent` + 신규 stub `sshpass`)
- `guard --plan stop <key호스트>` → `HL_SSH_KEY=<key_ref>` (verbatim,
  `/notes` 포함 변형 없음).
- `guard --plan stop <password호스트>` → `HL_SSH_PASS=<pass_ref>`.
- credential gate: password 호스트 + `HL_SSH_PASS` 부재 → exit 3;
  key 호스트 + `HL_SSH_KEY` 부재 → exit 3 (기존).
- `ssh-run` password 경로: `sshpass -e` 호출, 비번 argv 미노출,
  StrictHostKeyChecking=yes 유지; `HL_SSH_PASS` 부재 → exit 3;
  `sshpass` 부재 → fail-closed.
- `ssh-run` key 경로 회귀 없음(기존 테스트 그대로 통과).
- `test_mask_parity`: `HL_SSH_PASS`/`SSHPASS` 포함, mask() ↔ guard inline
  규칙 byte-identical 유지.

## 6. 리스크 / 완화

- **R1 jq argv(키)**: 기존 경로·캐비엇 동일, 새 면 없음.
- **R2 키 말미 개행**: `ssh-run` 이 `printf '%s\n'` 로 보장(기존). 파일
  바이트 보존이라 표준 키면 정상.
- **R3 패스워드 env 노출**: 비번은 `SSHPASS` env 로만(argv X). 로그/런로그는
  `mask()`+inline sed 가 `HL_SSH_PASS=`/`SSHPASS=` 마스킹. 부모 프로세스
  환경에 잠시 존재(bw-exec 주입 모델과 동일 신뢰경계).
- **R4 BatchMode=no 부작용**: 패스워드 경로만 해당. StrictHostKeyChecking=yes
  + known_hosts 유지로 호스트키 검증 불변. PubkeyAuthentication=no 로 키
  폴백 잡음 제거 → 인증 실패 시 빠르게 실패(걸림 없음). sshpass 가 프롬프트를
  비대화 처리.
- **R5 sshpass 의존성**: 조건부(패스워드 경로에서만). 부재 시 fail-closed +
  설치 안내. key-only 운용에 영향 없음.
- **R6 규약 미적용 인벤토리**: `/notes` 없는 key_ref·`auth` 누락은 기존
  의미(key/password 필드)로 해석. 마이그레이션은 문서 + 사용자 동반 갱신
  (환경 데이터, 비커밋, 일괄 자동 불가).
- **R7 환경 데이터 브랜치 손실**: 본 spec 무관. 실 인벤토리는 repo 밖
  (`~/.config/homelab-ops/inventory/`)+`HOMELAB_INVENTORY_DIR` 운용(별도
  교훈).

## 7. 범위·산출물

**커밋(범용)**
- bitwarden-ops: `bin/bw-put`(+테스트), `SKILL.md`.
- homelab-ops: `bin/ssh-run`, `bin/guard`, `bin/_lib.sh`, `SKILL.md`,
  `inventory/fleet.example.yaml`, `tests/`(신규 stub `sshpass`,
  `test_ssh_run`/`test_guard_plan`/`test_guard_exec`/`test_mask_parity`
  확장).

**비커밋(환경, 사용자 동반)**
- 실 인벤토리 key_ref `/notes` 화 + 패스워드 호스트 `auth: password`/
  `pass_ref` 부여. 실제 키(notes)·비번(password) 등록은 사용자 실행.

**구현**: TDD(RED→GREEN). Part A → Part B 순. 현 PR #24 와 독립 PR.
키 경로 회귀 0 가 합격 기준.
