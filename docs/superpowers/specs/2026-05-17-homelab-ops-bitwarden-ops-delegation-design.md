# homelab-ops → bitwarden-ops 위임 설계

날짜: 2026-05-17
상태: 승인됨 (구현 계획 작성 전)

## 배경

homelab-ops는 자체적으로 Bitwarden CLI 로직을 가지고 있다 — [`bin/bw-resolve`](../../../homelab-ops/bin/bw-resolve)가
`bw://item[/field]` 참조를 `bw get password|notes|item` + `jq`로 직접 해결한다.
이는 사실상 bitwarden-ops의 [`bin/bw-get`](../../../bitwarden-ops/bin/bw-get)과
인터페이스·구현이 동일한 **복제 코드**다. 게다가 homelab-ops 쪽은 구버전이라
bitwarden-ops가 최근 수정한 버그(필드 경로 후행 개행, 동명 필드 중복 연결)를 그대로 안고 있다.

목표(사용자 확정): **homelab-ops는 Bitwarden 동작을 일절 정의하지 않는다.**
credential이 필요하면 bitwarden-ops가 해결한다. "스킬이 스킬을 호출"이 1급 요구사항이며,
스킬 설치 경로는 사람·환경마다 다를 수 있으므로 homelab-ops 내부에 bitwarden-ops 경로를
하드코딩해서는 안 된다.

## 핵심 제약

homelab-ops의 상태 변경은 `guard → pve | ssh-run` 단일 셸 파이프라인으로 흐른다.
secret은 메모리에서 곧장 소비자로 스트리밍된다 (ssh 키 → `ssh-add` stdin, pve 토큰 → `curl` 헤더).
두 스킬의 핵심 보안 불변식: **secret 값은 Claude 컨텍스트·argv·디스크·로그에 절대 들어가지 않는다.**

따라서 "credential 필요 → Claude가 bitwarden-ops 스킬 호출 → 값을 받아 homelab-ops에 전달"
방식은 불가하다 (secret이 Claude 컨텍스트를 통과 → 불변식 위반, 또한 비대화형 파이프라인을
중간에 멈춰 스킬 호출을 끼워 넣을 수 없음).

이 코드베이스에서 "스킬 간 위임"의 올바른 형태:
- **지시 층**: 한 스킬의 SKILL.md가 Claude에게 다른 스킬을 invoke 하도록 지시 (Claude는 스킬
  레지스트리로 위치를 찾으므로 경로 독립적).
- **명령줄 합성 층**: bitwarden-ops가 SKILL.md에서 공개하는 실행 표면(`bw-exec`)을 통해
  credential을 명령에 주입해 실행. 이것이 `bw-exec`의 설계 의도다.

## 아키텍처

homelab-ops가 Bitwarden을 손 떼는 두 위임 층:

### A. 언락/세션 — 지시 층 (skill→skill)

[`SKILL.md`](../../../homelab-ops/SKILL.md)에서 `export BW_SESSION="$(bw unlock --raw)"`
같은 Bitwarden 동작 문서를 제거한다. 대신 "credential이 필요하면 **bitwarden-ops 스킬을
호출**한다 (bw-unlock / 세션 영속)"로 교체한다. Claude가 homelab-ops SKILL.md를 읽으면
bitwarden-ops 스킬로 위임하라는 지시를 보고 invoke 한다. 스킬 레지스트리로 찾으므로
설치 위치와 무관하다.

### B. 시크릿 해결 — 명령줄 합성 (경로 결합 0)

[`bin/bw-resolve`](../../../homelab-ops/bin/bw-resolve), 그 테스트
([`tests/test_bw_resolve.sh`](../../../homelab-ops/tests/test_bw_resolve.sh)),
homelab-ops의 `bw` 스텁([`tests/stubs/bw`](../../../homelab-ops/tests/stubs/bw))을 **삭제**한다.
credential이 필요한 op는 bitwarden-ops `bw-exec`로 감싸 실행한다:

```
bw-exec PVE_TOKEN=bw://... HL_SSH_KEY=bw://... -- <homelab>/bin/guard <op>
```

`bw-exec`가 ref를 env로 주입한 뒤 `exec guard` 한다. homelab-ops는 `bw-exec`를 직접
부르지 않는다 — Claude가 bitwarden-ops 스킬을 invoke 한 뒤 명령줄에서 합성한다.
homelab-ops 내부에 bitwarden-ops 경로 하드코딩이 전혀 없다. secret은 Claude
컨텍스트에 들어오지 않는다 (Claude는 inventory의 `bw://`ref와 명령만 다루고 값은 안 봄).

## 부트스트랩 문제와 해법

`token_ref`/`key_ref`는 op가 건드리는 host/target에 따라 inventory에서 달라지며,
현재 그 조회는 `pve`/`ssh-run` **내부**에 있다. 그런데 `bw-exec` 프리픽스는 guard 실행
*전에* ref를 알아야 한다.

**해법: guard에 read-only 계획 모드 `guard --plan <op>` 추가.**
inventory만 읽어(safe 등급, 시크릿 0) 그 op가 필요로 하는 `NAME=bw://ref` 매핑을
stdout에 한 줄로 출력한다. 고정 계약:

| env 변수      | inventory 소스                         | 소비자   |
|--------------|----------------------------------------|---------|
| `PVE_TOKEN`  | 대상 pve host의 `access.api.token_ref` | `pve`   |
| `HL_SSH_KEY` | 대상 ssh target의 `access.ssh.key_ref` | `ssh-run` |

`guard --plan`은 그 op가 실제로 필요로 하는 항목만 산출한다 (pve 액션은 `PVE_TOKEN`만,
ssh op는 `HL_SSH_KEY`만, 둘 다 필요한 op는 둘 다).

워크플로 (Claude가 SKILL.md 지시대로 수행):
1. `guard --plan <op>` → 필요한 `NAME=bw://ref` 목록 확보
2. bitwarden-ops 스킬 invoke (세션 보장: bw-unlock / 세션 영속)
3. `bw-exec <NAME=ref...> -- guard <op>` 실행

## 파일별 변경

- **삭제**
  - `homelab-ops/bin/bw-resolve`
  - `homelab-ops/tests/test_bw_resolve.sh`
  - `homelab-ops/tests/stubs/bw`

- **`homelab-ops/bin/pve`** (현재 11–14행)
  - `token_ref` inventory 조회 + `bw-resolve` 호출 제거
  - `PVE_TOKEN` env에서 토큰을 읽는다. 미설정/빈 값이면 exit 3 + 명확한 안내
    ("이 op는 bitwarden-ops `bw-exec`로 감싸 실행해야 함; `guard --plan` 참고")

- **`homelab-ops/bin/ssh-run`** (현재 13, 19–20, 26행)
  - `BW_SESSION` 게이트(13행), `key_ref` inventory 조회(19–20행),
    `bw-resolve --ssh` 호출(26행) 제거
  - `HL_SSH_KEY` env에서 키를 읽어 `printf '%s' "$HL_SSH_KEY" | ssh-add -`
    (heredoc/herestring 후행 개행 회피). 미설정/빈 값이면 exit 3 + 동일 안내.
  - ssh-agent 생성/`trap cleanup` 로직은 유지

- **`homelab-ops/bin/guard`** (현재 87–90행)
  - `BW_SESSION` 게이트를 "필요 credential env 존재" 게이트로 교체.
    비-safe op인데 해당 env(`PVE_TOKEN`/`HL_SSH_KEY`)가 없으면 exit 3 +
    "bitwarden-ops bw-exec로 감싸 실행" 안내
  - `--plan <op>` 모드 신설: inventory만 읽어 필요한 `NAME=bw://ref` 산출,
    safe 등급으로 취급(시크릿 미접근, 상태 변경 없음)

- **`homelab-ops/bin/_lib.sh`** (현재 22–28행)
  - 포렌식 마스킹에 `PVE_TOKEN=`/`HL_SSH_KEY=` env 할당 규칙 추가
  - 기존 `BW_SESSION=` env 규칙, PEM 블록·base64 블롭 규칙은 유지
    (BW_SESSION 규칙은 호환을 위해 남겨두되 주 경로에서는 더 이상 사용 안 됨)

- **`homelab-ops/SKILL.md`**
  - credential 절 재작성: `bw unlock`/`BW_SESSION` 문서 제거
  - bitwarden-ops 위임 명시, `guard --plan` → bitwarden-ops 스킬 invoke →
    `bw-exec ... -- guard <op>` 워크플로 문서화

- **`homelab-ops/inventory/`** — 변경 없음
  - `bw://`ref는 그대로 (bw-exec의 입력으로 계속 사용)

- **테스트**
  - pve/ssh-run/guard 테스트를 env 주입 모델로 갱신
    (`PVE_TOKEN`/`HL_SSH_KEY`를 env로 주입해 호출)
  - `guard --plan` 동작 테스트 신설 (inventory ref → NAME=ref 매핑 검증,
    시크릿 미접근 확인)
  - bitwarden-ops `bw` 스텁에 의존하던 homelab-ops 테스트 경로 정리

## 트레이드오프 (확정됨)

ssh 개인키 전달: 현재는 `bw-resolve --ssh | ssh-add -`로 디스크·env를 거치지 않고
stdin 직행이다. 새 모델에서는 `bw-exec`가 키를 `HL_SSH_KEY` env에 잠시 적재한 뒤
ssh-run이 거기서 `ssh-add`로 넘긴다. 둘 다 인메모리지만 env는
`/proc/<pid>/environ`·자식 프로세스로 노출면이 stdin 파이프보다 약간 넓다.
**사용자 결정: 통일성을 위해 전부 bw-exec env 주입으로 간다** (pve 토큰은 오늘도
셸 변수에 잡히므로 동급; 단일 위임 경로가 단순성·일관성 우위).

## 보안 불변식 확인

- secret 값은 Claude 컨텍스트·argv·디스크·로그에 들어가지 않는다:
  - Claude는 `bw://`ref(inventory에 이미 평문)와 명령만 다룬다
  - `bw-exec`가 값을 env로만 주입하고 곧장 `exec`
  - 포렌식 로거가 `PVE_TOKEN=`/`HL_SSH_KEY=` env 및 PEM/base64 블롭 마스킹
- 잠긴 볼트 fail-closed: credential env 부재 시 비-safe op는 exit 3
- read-only `guard --plan`은 inventory만 읽고 시크릿에 접근하지 않는다 (safe)

## 비목표

- guard/ssh-run의 BW_SESSION 게이트를 세션 파일 폴백까지 인지하도록 확장하는 것
  (사용자가 DRY 단일화를 주 목표로 선택; 세션 영속은 bitwarden-ops 책임으로 분리)
- inventory 스키마 변경
- 무관한 리팩터링
