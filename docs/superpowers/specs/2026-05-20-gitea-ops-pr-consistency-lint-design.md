# gitea-ops PR 일관성 lint + 작성 규칙 통합 — 설계

날짜: 2026-05-20
대상 스킬: `gitea-ops`
영향 표면: 신규 PR 흐름 전부 (gitea-ops 를 통해 만들어지는 모든 스킬 PR).

## 동기 / 배경

머지된 30개 PR 중 대표 7개를 비교 분석한 결과, "큰 그림에서는 의도대로 동작"하지만 디테일에서 일관성이 떨어지는 패턴이 반복된다.

관찰된 흔들림:

- **PR 제목 prefix**: 대체로 `feat(scope):` / `fix(scope):` 따르지만 PR #25 는 `feat:` (scope 누락) 로 들어옴. scope 가 cross-cutting 의도였는지 단순 누락이었는지 사후 판별 불가.
- **PR 본문 구조**: `## 요약` / `## 변경 요약` / `## 개요` 세 헤더가 혼용. PR #28 은 본문이 `-` 한 글자 — entry-gate 가 잡았어야 함.
- **푸터**: `🤖 Generated with [Claude Code](...)` 가 PR #25 / #30 에는 있고 #13 / #18 / #26 에는 없음. 정책 부재 신호.
- **브랜치 이름**: ad-hoc. 일부는 `feat/homelab-ops-exec-and-curated-verbs` 처럼 type/scope/topic 구조, 일부는 단순 `feat/widget` 식.
- **커밋 메시지 언어**: PR #25 는 한국어/영어 혼용 (`feat(homelab-ops): mask HL_SSH_PASS...` 와 `docs(plan): SSH-transport 자격 정렬...` 공존).

원인은 SKILL.md `## 작성 규칙` 절이 한국어 본문·Conventional Commits 정도만 권고하고, 나머지 디테일을 Claude 의 매 호출 판단에 맡긴 데 있다. 따라야 할 표준을 한 곳에 명시하고 entry-gate / PR 생성 스크립트가 자동 검증해 잡으면, 신규 PR 부터는 흔들림이 구조적으로 차단된다.

## 범위 / 비범위

### 범위 (in scope)

1. SKILL.md `## 작성 규칙` 절을 확장해 PR 제목·브랜치·본문 골격·trailer 규약을 한 곳에 명시.
2. 신규 모듈 `bin/_lint.sh` — 제목/브랜치/본문 검증 함수 3종 + 통합 진단 함수 1종.
3. `gitea-pr` 가 PR 생성 *전* 에 `_lint.sh` 호출. lint 실패면 push·생성 모두 거부.
4. `gitea-pr-status` 의 entry-gate 에 동일 검증 추가. 실패 시 `gate_passed=false` + 새 출력 키 3종.
5. `gitea-pr` 가 PR body 끝에 `Assisted-by: Claude Code` trailer 자동 부착 (idempotent).
6. 신규 testsuite `tests/test_lint.sh`, `tests/test_trailer.sh`. 기존 `tests/test_pr.sh` / `tests/test_pr_status.sh` 확장.

### 비범위 (out of scope — 의도된 누락)

- **모든 커밋 메시지 prefix lint**: 회차 반영 커밋 같은 사소한 흔들림을 허용. PR 안 모든 커밋을 검증하면 회귀 노이즈가 크다.
- **이미 머지된 30개 PR 의 retroactive cleanup**: forward-only. history 노이즈 회피.
- **review summary 회차 prefix 형식 강제**: `회차 N — ...` 권고만 SKILL.md 에 명시. lint 는 review body 까지 손대지 않는다.
- **`gitea-pr-review` 의 inline 코멘트 카테고리 라벨링**: 기존 SKILL.md 가이드라인 (issue/suggestion/nit/praise) 산문 강화만, 별도 라벨링 스키마 도입 안 함.
- **다른 forge (GitHub mirror) 의 PR 에 대한 동일 lint**: gitea-ops 스킬이 다루는 Gitea PR 한정.

## 컨벤션 명세

### PR 제목

정규식:

```
^(feat|fix|docs|refactor|chore|test)(\([a-z0-9-]+\))?: .+
```

- 허용 type: `feat` / `fix` / `docs` / `refactor` / `chore` / `test`.
- scope: lowercase + 숫자 + 하이픈. 보통 스킬 이름 (`homelab-ops`, `gitea-ops` 등).
- scope 생략은 **cross-cutting 변경에 한해** 허용. lint 는 형태만 확인하므로 사용자 책임으로 cross-cutting 임을 보증.
- 본문은 한국어, prefix 만 영문 (기존 SKILL.md "작성 규칙" 과 동일).

### 브랜치 이름

정규식:

```
^(feat|fix|docs|refactor|chore|test)/[a-z0-9]+(-[a-z0-9]+)*$
```

- type 은 PR 제목과 일치 권고. lint 는 형태만 확인 (제목/브랜치 type 일치 여부는 검증 안 함 — false positive 비용이 큼).
- scope 가 topic 에 포함되어 들어가는 형태 허용: `feat/homelab-ops-exec-and-curated-verbs`.
- scope 생략 시 `docs/cross-cutting-readme` 같이 type+topic 만.
- `refs/pull/N/head` 같은 자동 생성 ref 는 정규식 통과하지 않음 — 의도된 동작.

### PR 본문 골격

**필수 헤더** (정확히 이 문자열, 대소문자·공백 포함 일치):

- `## 요약`
- `## 검증`

`## 요약` 헤더 뒤에는 비어있지 않은 본문이 1자 이상 있어야 통과 (헤더만 있고 본문 0자 = die — PR #28 회귀 차단). "본문 1자 이상" 은 whitespace·개행을 제거하고 1자 이상 — 공백·개행만으로 채운 본문은 0자 취급.

**권장 헤더** (lint 는 안 봄, SKILL.md 에 안내):

- `설계: docs/superpowers/specs/...` / `계획: docs/superpowers/plans/...` 줄 — 요약 절 직후
- `## 시험 항목 (Test Plan)` — feature PR 이면 체크박스
- `## 비범위` 또는 `## 변경 없음` — 회귀 위험이 있는 PR 에서 권장

표준 골격 (PR #30 스타일):

```markdown
## 요약
<수준·동기·핵심 설계 1–2 문단>

설계: docs/superpowers/specs/...
계획: docs/superpowers/plans/...

## <카테고리 A>
- ...

## <카테고리 B>
- ...

## 검증
- 전체 테스트 녹색
- ...

## 시험 항목 (Test Plan)
- [ ] ...
- [ ] ...

Assisted-by: Claude Code
```

### Trailer

PR body 마지막 빈 줄 다음에:

```
Assisted-by: Claude Code
```

- RFC 822 git trailer 스타일, 이모지 없음.
- `gitea-pr` 가 자동 부착. `--no-trailer` 로 끌 수 있음 (사람이 직접 PR 만들 때).
- 이미 body 끝에 동일 trailer 가 있으면 중복 부착 안 함 (idempotent).
- `🤖 Generated with [Claude Code](https://claude.com/claude-code)` 식 옛 푸터는 신규 PR 에서 금지 — 단, lint 가 *제거*하진 않는다 (사용자가 직접 본문에 남기면 통과). 가이드라인으로만 안내.

### 커밋 메시지 (lint 없음, 가이드라인만)

기존 SKILL.md `작성 규칙` 의 Conventional Commits 권고는 유지. 회차 반영 커밋은 `chore(scope): PR #N 회차 K 리뷰 반영` 형식 권고.

## `_lint.sh` 모듈 인터페이스

### 모듈 위치

`gitea-ops/bin/_lint.sh` — `_common.sh` 와 같은 디렉터리, source 전용 라이브러리. 직접 실행 entry point 없음.

### 공개 함수

```sh
# stdout: 통과 시 무출력. 실패 시 사람-친화 메시지 한 줄.
# exit 0 통과 / 2 실패.
lint_pr_title <title-string>
lint_branch_name <branch-string>
lint_pr_body <body-string>     # `## 요약`/`## 검증` 헤더 + `## 요약` 절 본문 1자 이상

# stdout: 실패 항목별 한 줄씩 (통과면 무출력).
# exit 0 전부 통과 / 2 하나 이상 실패.
lint_pr_all <title> <branch> <body>
```

- stateless·side-effect 없음 (네트워크/파일 IO 없음). 정규식 매칭과 헤더 grep 만.
- 테스트에서 stub 없이 단독 source 가능.

### `_common.sh` 와의 경계

`_lint.sh` 는 `_common.sh` 를 source 하지 않음 — 의존성 없는 pure 모듈. `_common.sh` 의 `die()` 같은 헬퍼도 안 씀 (printf + return 으로 처리).

호출자 (`gitea-pr` / `gitea-pr-status`) 는 `_common.sh` 와 `_lint.sh` 둘 다 source.

## 호출 지점

### `gitea-pr` (PR 생성 *전*)

1. arg 파싱 + body trailer 부착 *후*, push *전* 에 `lint_pr_all "$title" "$head" "$body"` 호출.
2. exit 2 면 die — push 도 PR 생성도 안 함. 사용자에게 실패 항목 출력.
3. `--no-lint` flag 로 우회 가능 (sledgehammer — Claude 는 사용자 명시 요청 없이 사용 금지).

### `gitea-pr-status` (PR 생성 *후*, entry-gate)

1. PR 메타 fetch *후*, 기존 필수 항목 검사와 함께 `lint_pr_all` 호출.
2. 결과를 새 출력 키로 노출: `lint_title` / `lint_branch` / `lint_body` (각 `pass|fail`).
3. 기존 `gate_passed` 계산식에 lint 3 항목 추가 — 어느 하나라도 fail 이면 `gate_passed=false`.
4. **exit code 변경 없음** — 기존 `1` (필수 실패) 에 lint 실패도 포함. CI 실패(`2`) · timeout(`3`) 과 분리 유지.

### `--no-lint` / `--no-trailer` 정책

- `gitea-pr --no-lint`: 검증 3종 (title/branch/body) + trailer 자동 부착 모두 끔. emergency hatch (sledgehammer).
- `gitea-pr --no-trailer`: trailer 자동 부착만 끔. 검증 3종은 그대로 동작.

## SKILL.md 갱신 위치

### `## 작성 규칙` 절 — 확장 항목

기존 산문 bullet 사이에 다음 4 개 항목을 추가/교체:

1. **PR 제목** (기존 `commit 메시지 / PR title` bullet 강화): 정규식 명시 + `feat:` (scope 누락) 금지 예시 + cross-cutting 예외 명시.
2. **브랜치 이름** (신규): 정규식 명시 + 옛 짧은 예시는 갱신.
3. **PR 본문 골격** (신규): `## 요약` / `## 검증` 필수, 권장 헤더 4 종. `## 요약` 본문 0 자 금지.
4. **Trailer** (신규): `Assisted-by: Claude Code` 자동 부착. 옛 `🤖 Generated...` 푸터 금지.

기존 bullet (caveman 미적용, 리뷰·코멘트 영속성, 리뷰 의견 반영 default) 은 그대로 유지.

### `### Entry-gate` 갱신

기존 entry-gate 필수 항목 목록에 다음 3 줄 추가:

- PR 제목이 정규식 `^(feat|fix|docs|refactor|chore|test)(\(...\))?: .+` 통과
- 브랜치 이름이 정규식 `^(feat|fix|...)/[a-z0-9]+(-[a-z0-9]+)*$` 통과
- PR body 에 `## 요약` 및 `## 검증` 헤더 존재, `## 요약` 절 본문 1자 이상

`gitea-pr-status <PR#> --wait-ci` 한 번으로 점검된다는 기존 문장 유지.

### `### gitea-pr` script 시그니처 갱신

```
gitea-pr --title "..." --body "..." --head BRANCH [--base main]
         [--draft] [--assignee USER]... [--label LABEL]...
         [--no-lint] [--no-trailer]
         [-r owner/repo] [-u URL]
```

설명 단락 끝에 한 줄 추가: "PR 생성 전 `_lint.sh` 의 제목/브랜치/본문 lint 가 실패하면 push·생성을 모두 거부 (`--no-lint` 로 우회 — 사람이 직접 강제 작성할 때)."

### `### gitea-pr-status` 출력 키 갱신

기존 출력 키 목록에 `lint_title` / `lint_branch` / `lint_body` 추가. `gate_passed` 계산식 산문 한 줄 보강 — "+ 모든 `lint_*` 항목이 pass".

### `## 에러 처리` 절 추가 케이스

- `lint failed: title does not match ^(feat|fix|...)...` → 정규식 통과하도록 제목 수정. cross-cutting 이면 scope 생략 OK.
- `lint failed: body missing required header '## 요약'` → 골격 따르도록 본문 보강.

## 테스트 계획

### 신규: `tests/test_lint.sh`

`_lint.sh` 를 직접 source. 네트워크/tea stub 불필요.

**`lint_pr_title`** (8 케이스):
- 통과: `feat(homelab-ops): X` / `fix: X` / `docs(harbor-ops): X` 모든 허용 type
- 실패: 빈 문자열 / scope 안에 대문자 (`feat(HomeLab): X`) / 미허용 type (`build(...): X`) / `:` 누락 / 콜론 뒤 공백 누락 / 본문 0자 (`feat: `)

**`lint_branch_name`** (6 케이스):
- 통과: `feat/homelab-ops-exec-and-curated-verbs` / `fix/gitea-ops-pdm-auth-scheme` / `docs/cross-cutting-readme`
- 실패: 슬래시 누락 / 대문자 포함 / 트레일링 하이픈 / `refs/pull/N/head` / 빈 문자열

**`lint_pr_body`** (5 케이스):
- 통과: 최소 형태 / 카테고리 끼어 있어도 통과
- 실패: `## 요약` 누락 / `## 검증` 누락 / `## 요약` 본문 0자 / 빈 문자열 (PR #28 회귀)

**`lint_pr_all`** (3 케이스): 세 항목 모두 통과 / 한 항목만 실패 / 세 항목 모두 실패.

### 신규: `tests/test_trailer.sh`

trailer 부착 헬퍼 단독 테스트:
- body 끝에 trailer 부착 (idempotent — 두 번 호출해도 한 번)
- 이미 다른 줄에 trailer 가 있어도 정확히 한 번만 남음
- `--no-trailer` 시 부착 안 함
- body 끝 trailing 개행 처리 (RFC 822: trailer 앞 빈 줄 1개)

### 확장: `tests/test_pr.sh`

- 통과 케이스: 정상 제목·브랜치·body → push + PR 생성 호출 정확히 1회
- 실패 케이스: 잘못된 제목 → push·PR 생성 호출 0회
- `--no-lint` 로 잘못된 제목 강행 → push + PR 생성 호출 1회

### 확장: `tests/test_pr_status.sh`

- `lint_title` / `lint_branch` / `lint_body` 출력 키 존재 검증
- 세 항목 중 하나라도 fail → `gate_passed=false` + exit 1
- `--json` 모드도 동일 키 노출
- CI 실패와 lint 실패 동시 발생 시 exit code 우선순위 (CI 실패=2 가 lint 실패=1 보다 우선)

### 회귀 잠금

기존 7 테스트 파일 모두 그대로 통과. 기존 fixture 의 title/branch/body 가 새 정규식·골격을 통과하도록 사전 검증 후 필요 시 보강.

## 마이그레이션 / Bootstrap 순서

### 이미 머지된 30개 PR

아무것도 안 한다 (forward-only). SKILL.md 의 옛 예시 (`feat/widget` 같이 짧은 형태) 는 모두 새 컨벤션 예시로 교체.

### 본 spec 의 구현 PR 자체

의도된 첫 self-validation. 구현 PR 이 머지되는 순간 새 lint 가 활성화되므로 구현 PR 자신도 통과해야 한다.

기대 메타:
- 제목: `feat(gitea-ops): PR 일관성 lint + 작성 규칙 통합`
- 브랜치: `feat/gitea-ops-pr-consistency-lint`
- 본문: `## 요약` / `## 검증` / `## 시험 항목` + `Assisted-by: Claude Code` trailer

### Bootstrap 순서 (load-bearing)

`_lint.sh` 와 entry-gate 통합 사이 단계가 잘못 짜이면 본 PR 이 자기 자신을 검사할 때 거부될 수 있다. 안전한 순서:

1. **`_lint.sh` 모듈 + `tests/test_lint.sh`** — pure 모듈만, 어떤 호출자도 안 부름. 회귀 0.
2. **`gitea-pr` 통합** + `tests/test_pr.sh` 확장 + `tests/test_trailer.sh` 신규.
3. **SKILL.md 갱신** (작성 규칙 절 확장 + 옛 예시 교체 + `gitea-pr` 시그니처에 `--no-lint`/`--no-trailer` 추가).
4. **`gitea-pr-status` entry-gate 통합** + `tests/test_pr_status.sh` 확장 + SKILL.md Entry-gate 절 갱신.

각 단계 끝에 `bash tests/run.sh` 녹색 확인.

### Forward-only 한계 + 의식적 수용

새 entry-gate 가 켜진 시점 이후로 모든 신규 PR (gitea-ops 외 다른 스킬 PR 포함) 이 컨벤션을 따라야 한다. 옛 패턴으로 PR 을 만들면 entry-gate 가 즉시 거부 — 의도된 동작. SKILL.md `## 작성 규칙` 절이 단일 진실 출처.

### Rollback

`_lint.sh` 호출을 두 호출자 (`gitea-pr` / `gitea-pr-status`) 에서 주석 처리하면 즉시 비활성화. 모듈 자체는 남겨두고 호출만 끔 — git revert 한 줄로 가능. 별도 feature flag 안 둔다.

Assisted-by: Claude Code
