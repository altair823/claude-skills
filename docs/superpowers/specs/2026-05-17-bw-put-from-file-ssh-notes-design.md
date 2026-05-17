# bw-put `--from-file` + homelab-ops SSH 키 notes 정렬 설계

날짜: 2026-05-17
관련 스킬: bitwarden-ops (주), homelab-ops (규약/문서)

## 1. 문제

homelab-ops 의 SSH-transport 옵(`pkg-install`, appliance `stop` 등)은
`HL_SSH_KEY` 에 **완전한 multi-line PEM/OpenSSH private key** 를 기대한다
(`ssh-run`: `printf '%s\n' "$HL_SSH_KEY" | ssh-add -`). 그러나:

1. **저장 갭** — bitwarden-ops `bw-put` 의 유일한 비밀 입력 경로는
   `IFS= read -rs s < /dev/tty` 로 **한 줄만** 읽는다. multi-line 키는 첫 줄에서
   잘려 저장 불가. 파일 입력은 `BITWARDEN_OPS_TEST_SECRET_FILE` 뿐인데 이는
   명시적으로 **테스트 전용**(프로덕션 미사용).
2. **해석 불일치** — bitwarden-ops 설계상 SSH 키는 item **notes** 에 두고
   `bw-get --ssh` 로 꺼낸다. 그러나 homelab-ops `guard --plan` 의 ssh arm 은
   `HL_SSH_KEY=bw://ssh-<id>` (슬래시 없음) 를 내보내고, `bw-exec`→`bw-get` 이
   이를 **password 필드**(REF_KIND=password)로 해석한다. password 필드는
   single-line 이라 multi-line 키를 담아도 안 된다. 둘이 어긋난 잠재 버그
   (이번까지 ssh-transport 옵 미실행이라 미노출).

이 갭으로 인해 키 인증 기반 SSH 옵이 실제로는 동작 불가하다.

## 2. 목표 / 비목표

**목표**
- 로컬 SSH private key 파일을 사용자가 vault item **notes** 에 등록할 수 있는
  지원·정식 경로 제공.
- homelab-ops 가 그 notes 키를 변형 없이 `HL_SSH_KEY` 로 받게 정렬.
- bitwarden-ops 의 hard rule(특히 #4 "bw-put 은 user-run, Claude 는 명령만
  구성") 보존.

**비목표 (명시)**
- 패스워드 인증 SSH 지원 (homelab-ops `ssh-run` 은 `BatchMode=yes`+키 전용 —
  별도 spec 사안).
- homelab-ops guard/transport **로직** 변경 (불필요 — 규약/문서로 해결).
- PDM 마이그레이션 (별도 brainstorming→spec 사이클, approval-gated 로 예정).

## 3. 설계

### 3.1 컴포넌트 ① — bitwarden-ops `bw-put --from-file PATH`

`bw-put` 에 `--from-file PATH` 플래그 추가.

- 인터페이스:
  `bw-put bw://<item>[/<field>] [--type note|password|field] --from-file PATH [--replace]`
- 동작: 비밀을 `/dev/tty` 대신 **`PATH` 파일의 바이트 그대로** 읽는다.
  multi-line 보존. 파일은 사용자 머신 로컬(= 동일 단일사용자 신뢰모델).
- **user-run 유지**: Claude 는 정확한 명령줄만 구성·제시하고 실행하지 않는다
  (hard rule #4 불변). `--from-file` 은 `_read_secret` 의 한 분기로 추가하되
  `BITWARDEN_OPS_TEST_SECRET_FILE`(테스트 전용) 와는 **별개의 명시적 사용자
  인자** 경로다.
- 에러 (fail-closed):
  - `PATH` 미존재/미가독 → die.
  - 빈 파일 → die (기존 "빈 값은 등록하지 않음" 규칙 재사용).
  - 대상에 기존 non-empty 값 존재 + `--replace` 없음 → die (기존 규칙).
- 값 흐름은 기존과 동일(파일→변수→`jq --arg`→`bw`). 기존에 문서화된
  "jq argv 일시 노출" 캐비엇이 동일하게 적용되며 새로 악화시키지 않는다.
  값은 Claude 컨텍스트·영속 argv·로그·디스크에 남기지 않는다.
- `--from-file` 와 `--type`/`--replace` 조합은 기존 의미 그대로. type 미지정
  시 ref 모양에서 기본 추론(`/notes`→note)도 그대로.

### 3.2 컴포넌트 ② — 규약: SSH 키는 item notes

- SSH private key 는 vault item 의 **notes** 에 저장한다.
- 참조는 `bw://<item>/notes` (parse_ref → REF_KIND=notes → `bw-get` 이
  `bw get notes` 로 multi-line 보존 반환).
- 등록 명령(사용자 실행) 형태:
  `bw-put bw://ssh-<id>/notes --type note --from-file <키파일경로>`

### 3.3 컴포넌트 ③ — homelab-ops 정렬 (코드 로직 변경 0)

- 인벤토리 `access.ssh.key_ref` 값을 `bw://ssh-<id>/notes` 규약으로 한다.
- `guard --plan` 의 ssh arm 은 이미 `key_ref` 를 **그대로**
  `printf 'HL_SSH_KEY=%s\n'` 로 내보낸다. 따라서 key_ref 가 `/notes` 를 포함하면
  `bw-exec`→`bw-get` 이 notes 를 반환 → `ssh-run` 이 완전한 PEM 을 받는다.
  **guard/ssh-run 로직 수정 불필요.**
- 변경 대상은 문서·예시뿐:
  - `homelab-ops/SKILL.md` Credentials/Inventory 절에 "SSH 키는 notes,
    key_ref 는 `bw://ssh-<id>/notes`" 규약 명시.
  - `homelab-ops/inventory/fleet.example.yaml` 의 ssh `key_ref` 들을 `/notes`
    형태로 갱신.
  - bitwarden-ops `SKILL.md` 에 `--from-file` 사용법 + SSH 키 등록 예시 추가.
- 운영자 실 인벤토리(repo 밖, `HOMELAB_INVENTORY_DIR`)의 기존
  `bw://ssh-*` ref 는 사용자와 함께 `/notes` 로 갱신(환경 데이터 — 비커밋).

## 4. 데이터 흐름

```
~/.ssh/<key> 파일
  └─(사용자) bw-put bw://ssh-<id>/notes --type note --from-file ~/.ssh/<key>
        └─ vault item "<ssh-<id>>" .notes = 키 바이트 그대로
guard --plan stop <ssh-target>
  └─ HL_SSH_KEY=bw://ssh-<id>/notes        (key_ref verbatim)
bw-exec "HL_SSH_KEY=bw://ssh-<id>/notes" -- guard stop <ssh-target>
  └─ bw-get → bw get notes → multi-line PEM → env HL_SSH_KEY
       └─ ssh-run: printf '%s\n' "$HL_SSH_KEY" | ssh-add -  → ssh
```

## 5. 테스트 (TDD)

**bitwarden-ops** (`tests/` — 신규/확장):
- `--from-file`: multi-line 파일 내용이 notes 에 **byte-verbatim** 저장됨
  (개행·말미 개행 보존).
- `--from-file` 파일 미존재 → 비정상 종료(die).
- `--from-file` 빈 파일 → die ("빈 값 등록 안 함").
- 기존 값 존재 + `--replace` 없음 → die; `--replace` 있으면 덮어씀.
- user-run 계약 회귀 없음: `--from-file` 없을 때 기존 tty 경로 불변.

**homelab-ops** (`tests/test_guard_plan.sh` 확장):
- `guard --plan` 이 `/notes` 포함 ssh key_ref 를 **변형 없이**
  `HL_SSH_KEY=bw://<item>/notes` 로 통과시키는지 단언 1건(stub, 규약 잠금).

테스트는 두 스킬 모두 기존 stub-구동 오프라인 스위트 패턴을 따른다.
환경 specific 데이터(실 키·실 호스트) 불포함.

## 6. 리스크 / 완화

- **R1 jq argv 노출**: 기존과 동일 경로·동일 캐비엇. 새 노출 면 없음. notes
  타입도 기존 password/note 와 같은 처리.
- **R2 키 말미 개행**: `ssh-add` 는 키 말미 개행 필요. `ssh-run` 이 이미
  `printf '%s\n'` 로 1개 보장(중복 개행은 무해 처리, 기존 주석에 명시).
  `--from-file` 은 파일 바이트 보존이므로 키 파일이 표준대로 개행으로 끝나면
  정상.
- **R3 규약 미적용 인벤토리**: `/notes` 없는 기존 ref 는 여전히 password 로
  해석돼 실패. 마이그레이션은 문서화 + 사용자와 실 인벤토리 동반 갱신으로 처리
  (환경 데이터라 자동/일괄 불가, 비커밋).
- **R4 브랜치 전환 시 환경 데이터 손실**: 본 spec 무관(코드/문서만). 단 실
  인벤토리는 repo 밖(`~/.config/homelab-ops/inventory/`)+`HOMELAB_INVENTORY_DIR`
  로 운용 (별도 교훈, PR #24 의 override 의존).

## 7. 범위·산출물

- 커밋 대상(범용): bitwarden-ops `bin/bw-put`(+테스트), 양 스킬 `SKILL.md`,
  `homelab-ops/inventory/fleet.example.yaml`, `homelab-ops/tests/test_guard_plan.sh`.
- 비커밋(환경): 실 인벤토리의 ref `/notes` 갱신, 실제 키 등록(사용자 실행).
- 구현은 TDD(RED→GREEN). 별도 PR(현 PR #24 와 독립).
