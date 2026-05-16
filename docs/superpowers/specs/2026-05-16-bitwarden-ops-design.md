# bitwarden-ops 설계 문서

작성일: 2026-05-16

## 1. 목적

`bitwarden-ops` 는 Claude Code 가 어느 프로젝트에서든 Bitwarden 개인 vault(`bw` CLI)의 credential 을 **해결(읽기)** 하고, 미등록분을 **즉석 등록(쓰기)** 하기 위한 자족적 CLI 스킬이다. 다른 어떤 스킬도 알 필요 없이 단독으로 이해·설치·사용된다. 핵심 설계 긴장점은 **AI 에이전트가 쓰는 credential 도구의 안전성 ↔ 일상 사용 편의** 이며, 불변 규칙은 단 하나로 수렴한다: **secret 값은 Claude 의 컨텍스트·argv·디스크·로그 어디에도 남지 않는다.**

의존성: `bw`(Bitwarden CLI), `jq`, `bash`. 구조: `SKILL.md` + `bin/`(얇은 bash 래퍼) + `tests/`(pure-bash 하니스).

## 2. 사용 시점 / 범위

- "이 명령에 vault 의 토큰을 넣어 실행" → `bw-exec`
- "vault 의 키를 stdout 으로 받아 파이프(ssh-agent 등)" → `bw-get`
- "vault 에 뭐가 있는지(값 말고 이름) 보기" → `bw-ls`
- "아직 vault 에 없는 credential 을 지금 등록" → `bw-put` (사용자가 직접 실행)
- "vault 잠금/세션 상태 확인" → `bw-status`

범위 밖: org/collection 관리, Bitwarden Secrets Manager(`bws`), 첨부파일, 항목/필드 **삭제**, GitHub/GitLab 등 타 secret 백엔드. 다른 도구의 기존 자격증명 저장 방식을 본 스킬로 옮기는 마이그레이션도 범위가 아니다(§9).

## 3. 아키텍처

상시 데몬 없음. `bin/` 의 얇은 bash 래퍼를 Claude(또는 사용자)가 호출한다. credential 은 호출 시점에만 `bw` 로 해결되어 메모리/파이프/자식 env 로만 흐른다.

### 3.1 레포 구조

```
bitwarden-ops/
  bin/
    bw-get       # 참조 해결 → stdout (읽기, 파이프/ssh-agent용)
    bw-exec      # 참조들을 자식 env로 주입 후 cmd exec (읽기, CLI 래퍼용)
    bw-ls        # item·필드 이름 나열 (메타데이터, 값 없음)
    bw-put       # 참조 위치에 값 upsert (쓰기, 사용자가 직접 실행)
    bw-status    # vault 잠금·BW_SESSION 세션 상태 (메타데이터)
    _common.sh   # 공유: die, 참조 파서, locked-vault 게이트, 마스킹
  tests/
    run.sh
    lib.sh
    stubs/bw     # 결정적 가짜 vault
    test_*.sh
  SKILL.md
```

### 3.2 참조 문법 (읽기·쓰기 대칭)

- `bw://<item>` → 항목의 password
- `bw://<item>/<field>` → 명명 필드 또는 커스텀 필드 `<field>` 의 값
- `bw://<item>/notes` → notes 전체
- `--ssh` 플래그 → notes 에 보관된 SSH private key (stdout 전용, 호출자가 ssh-agent 로 주입하는 용도)

`<item>` 은 항목 이름 또는 ID. 동일 문법을 `bw-get`/`bw-exec`/`bw-put` 이 공유하므로 "쓴 곳에서 읽는다" 가 대칭적이다.

## 4. 세션 모델

```
사용자가 직접: export BW_SESSION="$(bw unlock --raw)"
   (마스터 비번은 사용자만 입력 — Claude 도 파일도 절대 접근하지 않음)
모든 명령: BW_SESSION 을 받아 그 시점에만 bw 호출
세션 종료: 사용자가 bw lock / BW_SESSION unset (권고)
```

- `BW_SESSION` 미설정 ⇒ 모든 명령이 시작 거부 (exit 3, "locked vault").
- `BW_SESSION` 자체가 vault 접근 권한을 부여하는 secret 이다 — 출력·로그·argv 에 노출 금지, 마스킹 대상.

> **보강(2026-05-16, 세션 영속):** `BW_SESSION` 미설정 시 `$HOME/.cache/bitwarden-ops/session`
> (0600, durable, repo 밖) 를 폴백으로 사용한다(env-wins). 사용자는 Claude 가 이미 떠 있어도
> `bw-unlock` 으로 unlock 할 수 있고, `bw-lock` 으로 종료한다. 상세: 별도 설계 문서
> `2026-05-16-bitwarden-ops-session-persistence-design.md`.

## 5. 명령

모든 명령은 `_common.sh` 를 source 하고, 첫 동작 전 locked-vault 게이트를 통과한다.

### 5.1 `bw-get`

```
bw-get <bw://ref> [--ssh]
```

참조를 해결해 값을 **stdout 으로만** 출력. 호출자가 즉시 파이프한다(`bw-get bw://x/api | consumer`). 값은 파이프로만 흐르고 Claude 는 보지 않는다. 출력은 **byte-verbatim** 이다 — password/field/notes 세 종류 모두 후행 개행을 덧붙이지 않는다(`field` 경로의 추출은 `jq -ej`, password/notes 는 `bw get` 출력을 그대로 전달). 단 `--ssh` 는 notes 의 SSH 키를 그대로 stdout(키에 포함된 개행 보존)으로. 해결 실패 시 item-없음 / field-없음 을 구분한 에러.

### 5.2 `bw-exec`

```
bw-exec <NAME=bw://ref>... -- <cmd> [args...]
```

각 `NAME=bw://ref` 를 해결해 **자식 프로세스 env 로만** 주입하고 `cmd` 를 exec. secret 은 argv·Claude 출력·디스크 어디에도 없다. 1개 이상의 매핑 + `--` 구분자 필수. 해결 실패 시 cmd 미실행, 비0 종료.

### 5.3 `bw-ls`

```
bw-ls [<search>]
```

vault 항목 이름과 (있으면) 필드 이름을 나열한다. **값은 출력하지 않는다.** `<search>` 부분 일치 필터. 무엇이 등록돼 있는지 secret 노출 없이 탐색하는 용도.

### 5.4 `bw-put` (쓰기 — 사용자가 직접 실행)

```
bw-put <bw://ref> [--type password|field|note] [--replace]
```

참조 위치에 값을 upsert. **값은 제어 터미널(`/dev/tty`)의 비에코 프롬프트에서만 읽는다 — argv 도, 일반 stdin 도 아니다.** `/dev/tty` 를 쓰는 이유가 핵심이다: Claude 의 Bash 도구에는 제어 터미널이 없어 Claude 는 구조적으로 값을 공급할 수 없고, 터미널 앞의 사람만 입력할 수 있다. Claude 는 `bw://` 타깃과 `--type` 만 구성해 실행할 명령줄을 제시하고, **사용자가 자신의 터미널에서 직접 실행**해 secret 을 붙여넣는다(마스터 비번 모델과 동일 — Claude 는 값을 보지 않는다).

- `--type` 기본: `password`(필드 미지정 시) / 필드 지정 시 `field` / `bw://x/notes` 면 `note`.
- 쓰기 전 `bw sync` — stale 로컬 캐시가 서버 상태를 clobber 하지 않도록.
- **overwrite-needs-eyes**: 참조 위치에 이미 비어있지 않은 값이 있으면 기본 거부하고 "이미 존재 — 덮어쓰려면 `--replace`" 안내. 기존 secret 을 말없이 잃는 것은 파괴적 작업이므로 명시적 확인을 요구한다. 신규 item/field 생성은 플래그 불필요. `--replace` 명시 시에만 덮어쓴다.
- 항목이 없으면 새 항목 생성, 있으면 해당 필드/비밀번호만 set.
- **테스트 seam**: tty 읽기 한 줄은 `_read_secret` 함수로 분리하고 전용 env 변수로만 오버라이드 가능하게 둔다(테스트 하니스만 설정, 프로덕션에서는 미설정). 프로덕션 경로는 항상 `/dev/tty` 이며, 테스트는 이 seam 으로 가드 로직(overwrite 거부·sync 선행·빈값 거부·ref 파싱)만 비대화식으로 검증한다 — 프로덕션 입력 경로를 약화시키지 않는다.

### 5.5 `bw-status`

```
bw-status [--json]
```

`BW_SESSION` 설정 여부와 vault 잠금 상태를 출력(secret 없음). 다른 명령 실행 전 preflight. 종료코드: `0` unlocked+세션OK / `3` locked 또는 세션 없음.

> 참고: `bw status` 는 `{status}` 만 반환하고 마지막 sync 시각을 노출하지 않으므로 "sync staleness" 는 `bw-status` 가 제공할 수 없다(구현·SKILL.md 도 주장하지 않음). stale 캐시 방어는 `bw-put` 이 쓰기 직전 `bw sync` 를 강제하는 것으로 처리한다(§5.4·§6.5).

### 5.6 `bw-unlock`

```
bw-unlock
```

사용자 실행; `bw unlock` 으로 마스터 비번을 사용자 tty 에서 받아 `$HOME/.cache/bitwarden-ops/session`(0600) 에 기록 (env-wins 폴백). Claude 가 이미 실행 중이어도 사용자가 자신의 터미널에서 호출 가능. Claude 는 이 명령을 직접 실행하지 않는다(마스터 비번은 사용자만 입력).

### 5.7 `bw-lock`

```
bw-lock
```

Claude/사용자 실행; `bw lock` + 세션 파일 제거, idempotent, secret 입력 없음. 세션 파일이 없어도 오류 없이 종료한다.

## 6. 안전 계약 (불변 — 척추)

1. **마스터 비번**: 사용자만, `bw unlock` 으로만. Claude 는 절대 프롬프트·수신·저장하지 않는다.
2. **secret 값**: 읽기든 쓰기든 Claude 출력·argv·디스크·로그에 절대 없다. 읽기 → stdout / 자식 env. 쓰기 → 사용자 터미널 비에코 입력.
3. **locked-vault 기본**: `BW_SESSION` env 가 없고 세션 파일도 없으면 exit 3, 시작 거부 (세션 파일 폴백은 §4 보강 참조; env-wins).
4. **overwrite-needs-eyes**: `bw-put` 이 기존 비어있지 않은 값을 덮어쓰려면 `--replace` 명시 필수.
5. **쓰기 전 sync**: `bw-put` 은 `bw sync` 후 진행 — stale 캐시 clobber 방지.
6. **마스킹**: `BW_SESSION`·해결된 값이 우발적으로 스트림에 섞이면 마지막 방어선으로 마스킹(`_common.sh`).

## 7. 에러 처리

- `BW_SESSION` 없고 세션 파일(`$HOME/.cache/bitwarden-ops/session`)도 없음 → exit 3, "locked vault: 세션 없음 — 사용자가 본인 터미널에서 'bw-unlock' 실행". 세션 파일이 존재하나 읽기 불가(권한/소유)면 source-time 가드가 exit 3 으로 명확히 die 한다(이 경우 `bw-lock` 도 같은 가드로 exit 3 — 알려진 한계; 권한 정상화 후 재시도).
- `bw` 가 locked/만료 보고 → exit 3, 재잠금 안내.
- 참조 문법 오류(`bw://` 아님) → 사용법 에러, exit 1.
- item 없음 vs field 없음 → 구분된 메시지(어느 쪽이 없는지 분명히).
- `bw-put` 에서 사용자 입력이 빈 값 → 거부(빈 secret 등록 방지), 재시도 안내.
- `bw sync` 실패 → 경고 + 사용자 결정 위임(네트워크 단절 시 stale 쓰기 위험 고지).

## 8. 테스트

의존성 없는 pure-bash 하니스 + `tests/stubs/bw`(PATH 로 실제 `bw` 를 가리는 결정적 가짜 vault). 커버:

- 참조 파서: `bw://i`, `bw://i/f`, `bw://i/notes`, 잘못된 형식.
- `bw-get`: 값이 stdout 으로만, item/field 없음 구분, field 경로 후행 개행 없음(바이트 정확 단언).
- `bw-exec`: 값이 자식 env 에만 — argv·stdout·stderr 에 secret 부재 단언.
- `bw-ls`: 값이 출력에 부재 단언(이름만).
- `bw-put`: 신규 생성 경로 / 기존 값에 `--replace` 없이 거부 / `--replace` 로 덮어씀 / 빈 입력 거부 / sync 선행. (값 입력은 §5.4 의 `_read_secret` 테스트 seam 으로 주입 — 프로덕션 `/dev/tty` 경로는 불변.)
- locked-vault: 모든 명령 `BW_SESSION` 없을 때 exit 3.
- `--ssh`: notes 키가 개행 보존되어 stdout 으로.

## 9. 비목표 (YAGNI)

- **항목/필드/첨부 삭제** — 에이전트 컨텍스트에서 과도하게 위험. 파괴적 vault 편집은 사용자가 Bitwarden UI 에서.
- org/collection 관리, Bitwarden Secrets Manager(`bws`), 첨부파일.
- 상시 데몬/서비스, 커스텀 MCP 서버.
- 다른 스킬/도구를 본 스킬로 마이그레이션하거나 통합하는 작업. 본 스킬은 자족적 독립 스킬이며, 어떤 스킬의 내부에도 의존하지 않고 어떤 스킬도 본 스킬에 결합시키지 않는다. 타 도구가 `bw-get`/`bw-exec` 를 호출해 credential 을 위임받는 것은 가능하나, 그 통합 자체는 본 설계의 범위가 아니다(필요 시 별도 프로젝트).
- 세션 영속의 자가 max-age/TTL, tmpfs/`$XDG_RUNTIME_DIR`, 암호화/키링/TPM, 데몬(`bw serve`), 백엔드 교체(`rbw`). 같은-UID 공격자 방어는 범위 밖(OS 계정 보안). 위협 B(영속·백업 잔존)는 사용자가 의도적으로 수용. (근거: `2026-05-16-bitwarden-ops-session-persistence-design.md` §5·§7)
