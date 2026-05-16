# bitwarden-ops 세션 영속 설계 문서

작성일: 2026-05-16

본 문서는 기존 `bitwarden-ops` 스킬(설계: `2026-05-16-bitwarden-ops-design.md`)에 대한 **증분 보강**이다. 기존 스킬의 모든 불변식은 그대로 유지되며, 아래에 명시한 부분만 변경/추가된다.

## 1. 목적

기존 세션 모델은 `BW_SESSION` 환경변수에만 의존한다. Claude Code 의 Bash 도구는 호출마다 사용자 프로필에서 새 셸을 띄우므로, **다른 터미널에서 `bw unlock` 한 결과는 이미 실행 중인 Claude 세션의 Bash 호출에 상속되지 않는다.** 따라서 "Claude 를 먼저 켜고 나서 unlock" 하는 흔한 순서에서는 스킬이 동작하지 않는다.

목표: **사용자가 Claude 세션이 켜진 뒤 unlock 해도 Claude 의 `bw-*` 명령이 세션을 집어 쓸 수 있게 한다.** 단, 데몬을 두지 않고, `bw` 백엔드를 교체하지 않으며, credential 참조 모델(`bw://`)은 그대로 둔다.

## 2. 핵심 메커니즘 — `$HOME/.cache` 세션 파일 폴백

writer(사용자 터미널)와 reader(Claude 의 fresh 셸)가 **환경변수 상속 없이 동일 경로를 독립 계산**할 수 있어야 한다. `$HOME` 은 사용자 프로필 셸에서 항상 설정되므로 결정적 경로가 된다:

```
CACHE_DIR = ${BITWARDEN_OPS_CACHE_DIR:-$HOME/.cache/bitwarden-ops}
세션 파일  = $CACHE_DIR/session     (dir 0700, file 0600)
```

`BITWARDEN_OPS_CACHE_DIR` 는 테스트 seam 전용(테스트 하니스만 설정; 프로덕션 미설정 — 기존 `BITWARDEN_OPS_TEST_SECRET_FILE` seam 과 동형).

세션 해결 **우선순위(env-wins)**:

1. `BW_SESSION` 환경변수가 비어있지 않으면 → 그대로 사용(기존 "unlock 한 셸에서 Claude 실행" 워크플로 무손상).
2. 아니면 `$CACHE_DIR/session` 이 존재하고 비어있지 않으면 → 그 값을 이번 호출 한정으로 `BW_SESSION` 으로 export 해 사용.
3. 둘 다 없으면 → 기존대로 잠긴 금고 (exit 3).

파일에서 읽은 값은 기존 env 값과 동일하게 secret 으로 취급한다(마스킹 대상, 에코 금지, 자식 `bw` 호출 env 로만 전달).

## 3. 새 명령

### 3.1 `bw-unlock` (사용자가 직접 실행)

```
bw-unlock
```

`bw unlock` 을 호출 → **마스터 비밀번호는 `bw` 가 사용자 터미널에서 직접 받음**(Claude 는 보지 않음, `bw-put` 과 동일 원칙). 얻은 세션 키를 `$CACHE_DIR/session` 에 기록한다:

- `mkdir -p` 로 `$CACHE_DIR` 보장 후 dir 권한 0700.
- 파일은 **처음부터 0600** 으로 생성(같은 디렉터리에 `mktemp` → 내용 기록 → `chmod 600` → `mv` 로 원자적 교체; 0600 이전 창 없음).
- 기존 세션 파일이 있으면 덮어쓴다(재-unlock = 교체).
- `$HOME` 미설정 등으로 경로 해석 불가 시 **fail-closed**(상대경로/임의 위치에 절대 쓰지 않음).
- 성공 시 secret 없는 확인 문구만 출력.

Claude 는 `bw-unlock` 를 호출하지 않는다(마스터 비번이 사용자 tty 를 거치므로 구조적으로 불가). Claude 는 잠금 상태를 만나면 사용자에게 "본인 터미널에서 `bw-unlock` 실행" 을 안내한다.

### 3.2 `bw-lock` (사용자 또는 Claude)

```
bw-lock
```

`bw lock` 실행 + `$CACHE_DIR/session` 제거(`shred -u` 가능하면 사용, 아니면 `rm -f`). 파일 삭제와 vault 잠금뿐이고 secret 입력이 없으므로 Claude 도 호출 가능. 파일이 없어도 성공(idempotent).

## 4. 변경되는 기존 구성요소

- `bin/_common.sh`: 세션 해결 로직에 §2 의 폴백을 추가한다. 폴백이 적중하면 `_common.sh` 가 **sourcing 스크립트의 셸에 `export BW_SESSION=<파일값>`** 하므로, 그 스크립트의 후속 `bw` 호출들이 자동으로 세션을 상속한다. `require_session` 은 이 해결 후 "env 또는 세션 파일 중 하나라도 유효" 일 때 통과, 아니면 exit 3. 그 외 함수(`die`/`require_cmd`/`parse_ref`/`mask`) 불변.
- `bin/{bw-get,bw-exec,bw-ls,bw-put,bw-status}`: **코드 변경 없음** — `_common.sh` 가 export 한 `BW_SESSION` 을 기존과 동일하게 사용. (`bw-status` 가 세션 출처를 env/file 로 구분 표기하는 건 별도 nicety 로 본 설계 범위 밖.)
- `SKILL.md`: 세션 절·hard rules·명령표(`bw-unlock`/`bw-lock`) 갱신.
- 원 설계 문서 §4(세션 모델)·§5(명령)·§9(비목표)에 본 보강을 반영(별도 정정 커밋).

## 5. 보안 자세 (정직한 한정)

기존 스킬의 핵심 불변식 — *저장된 credential 은 `bw://` 참조뿐, 평문 비밀이 디스크/Claude/argv/로그에 없음* — 은 **그대로 유지**된다. 본 보강이 새로 추가하는 유일한 at-rest 항목은 **라이브 vault 세션 키 1개**가 `$HOME/.cache/bitwarden-ops/session` 에 평문 0600 으로 존재하는 것이다. 이를 다음과 같이 한정·정당화한다:

- **이것은 저장된 credential 이 아니라 세션 키다.** vault 항목들은 여전히 `bw://` 참조로만 다뤄지고 평문화되지 않는다. 세션 키는 사용자가 명시적으로 `bw-unlock` 했을 때만, 그 vault 잠금해제 기간 동안만 존재한다.
- **위협 B(영속·백업·스냅샷 잔존)는 사용자가 의도적으로 수용**했다 — 매 작업마다 재-unlock 하는 마찰이 더 크다는 판단. `bw` 세션 키는 자동 만료되지 않으므로 사용자는 `bw-lock` 으로 명시적 종료를 책임진다.
- **위협 A(같은 UID 프로세스/계정 탈취)는 본 스킬의 범위 밖**이다. 어떤 파일/키링/tmpfs 방식도 같은 UID 공격자는 못 막으며, 이는 OS 계정 보안의 영역이다.
- 어떤 repo 트리에도 두지 않는다(`~/.cache` 는 git 작업 트리 밖). 따라서 `.gitignore` 에 의존하지 않으며, repo push/mirror·`git add -f`·`git stash --all`·비-git 복사 같은 유출 경로와 무관하다. 기존 스킬들(`gitea-ops` 는 `~/.config/`, `paperboy-ops` 는 `~/.cache/`)의 XDG 관례와 정합한다.
- 세션 키는 기존 `mask()`(`BW_SESSION=` 패턴)로 스트림 마스킹 대상이며, 스킬은 이를 자식 `bw` 호출 env 외에는 어디에도 출력하지 않는다.

## 6. 에러 처리

- 세션 파일이 만료/`bw lock` 됨(stale): `require_session` 은 존재만 확인(매 명령 liveness 체크는 비용 과다). stale 이면 후속 `bw` 호출이 실패 → 기존 exit-3/locked 경로. 관련 에러 메시지에 "`bw-unlock` 재실행" 힌트를 포함한다.
- 세션 파일 존재하나 비어 있음 → 없는 것으로 간주(잠금, exit 3).
- `$HOME` 미설정/`CACHE_DIR` 생성 불가: `bw-unlock` 은 fail-closed(거부, 임의 위치에 쓰지 않음). reader 는 파일 없음으로 간주 → exit 3.
- `bw-lock`: 파일 부재여도 성공(idempotent).

## 7. 비목표 (YAGNI / 명시적 제외)

- **자가 max-age / 합성 TTL** — 사용자가 명시적으로 제외(재-unlock 마찰 회피 우선). `bw` 의 무만료 특성은 `bw-lock` 수동 종료로 관리.
- tmpfs/`$XDG_RUNTIME_DIR`, 암호화/OS 키링/TPM 봉인.
- 데몬(`bw serve`), 백엔드 교체(`rbw`).
- 같은 UID 공격자 방어(범위 밖, OS 영역).
- repo 내 저장 / `.gitignore` 기반 관리.

## 8. 테스트 (pure-bash 하니스, 기존 stub)

`BITWARDEN_OPS_CACHE_DIR` seam 으로 캐시 경로를 임시 디렉터리로 오버라이드. 커버:

- **env-wins**: `BW_SESSION` set + 세션 파일 존재 → env 값 사용, 파일 무시.
- **file-fallback**: `BW_SESSION` unset + 세션 파일 존재 → 파일 값으로 `bw-get`/`bw-exec` 등 동작(stub 라운드트립).
- **둘 다 없음**: env unset + 파일 없음 → 모든 명령 exit 3.
- **빈 파일**: 세션 파일 존재하나 빈 내용 → exit 3.
- **`bw-unlock`**: 세션 파일을 0600(디렉터리 0700)으로 생성, 기존 파일 교체. 실제 `bw unlock`(마스터 비번 tty)은 seam 으로 대체해 파일-기록 로직만 검증 — 프로덕션 tty 경로는 불변.
- **`bw-lock`**: 세션 파일 제거 + `bw lock` 호출(stub). 파일 부재 시에도 성공.
- **권한**: 생성된 세션 파일 0600, 디렉터리 0700 단언.
- **마스킹**: 파일에서 읽은 세션 값이 `mask()` 로 가려짐 단언(스트림 오염 방지 회귀).

## 9. 자기완결성

본 보강도 다른 어떤 스킬도 참조/의존하지 않는다. 의존성은 여전히 `bash`/`bw`/`jq` 뿐. 테스트는 의존성 없는 pure-bash + PATH stub.
