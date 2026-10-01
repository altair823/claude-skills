# PR, 이슈, 리뷰 본문 작성 규칙

PR, release, issue, review 본문을 쓸 때 적용한다. 대화창 출력에는 적용하지 않는다.

## 언어

- 기본은 한국어다. 사용자가 "영어로"라고 하면 영어로 쓴다.
- PR, branch, merge, commit, push, head, base, tag, release, review, token, worktree 같은 기술 용어는 한국어 문장 안에 영문 그대로 쓴다. CLI 식별자, flag, URL, 코드 블록도 영문 그대로 둔다.
- caveman 모드가 켜져 있어도 PR, issue, review 본문은 평소처럼 자연스러운 문장으로 쓴다. 이 본문은 영구 기록으로 남고, caveman 모드는 대화창에만 적용한다.

## PR 제목과 커밋 메시지

Conventional Commits를 따른다. PR 제목은 아래 정규식에 맞아야 한다. PR 사전 점검과 `gitea-pr` lint가 검사한다.

```
^(feat|fix|docs|refactor|chore|test)(\([a-z0-9-]+\))?: .+
```

- scope는 소문자, 숫자, 하이픈으로 쓰며 보통 스킬 이름이다.
- 여러 영역에 걸친 변경일 때만 scope를 생략할 수 있다. 스킬 하나만 바뀌면 scope를 반드시 쓴다.
- 영문 prefix 뒤에 한국어 본문을 써도 된다.
- 커밋 메시지는 lint하지 않는다. 리뷰를 반영한 커밋은 `chore(scope): PR #N 회차 K 리뷰 반영` 형식을 권장한다.

## 브랜치 이름

`<type>/<topic-kebab>` 형식이어야 한다. PR 사전 점검과 `gitea-pr` lint가 검사한다.

```
^(feat|fix|docs|refactor|chore|test)/[a-z0-9]+(-[a-z0-9]+)*$
```

scope는 topic 안에 kebab 형식으로 넣는다(`feat/homelab-ops-exec-and-curated-verbs`). scope가 없으면 `docs/cross-cutting-readme`처럼 type과 topic만 쓴다. PR 제목의 scope와 브랜치의 scope가 일치하는지는 lint가 검사하지 않으므로 작성자가 맞춘다.

## PR 본문 구성

필수 헤더는 `## 요약`과 `## 검증`이다(정확히 이 문자열). `## 요약` 아래 본문은 공백을 빼고 1자 이상이어야 한다.

권장 항목은 다음과 같다.

- `## 요약` 바로 아래의 `설계:` 또는 `계획:` 줄
- `## 시험 항목 (Test Plan)`
- `## 비범위` 또는 `## 변경 없음`
- 이름을 자유롭게 붙인 `## 카테고리`

기본 구성:

```markdown
## 요약
<수준, 동기, 핵심 설계를 1~2 문단으로>

설계: docs/superpowers/specs/...

## 검증
- 전체 테스트 통과

## 시험 항목 (Test Plan)
- [ ] ...
```

## Trailer

본문 마지막 빈 줄 다음에 `Assisted-by: Claude Code` 한 줄을 붙인다. `gitea-pr`가 자동으로 붙이며, 이미 있으면 다시 붙이지 않는다. `--no-trailer`로 끌 수 있다. 예전의 `🤖 Generated with [Claude Code](...)` 푸터는 쓰지 않는다.

## 리뷰 작성

- summary는 짧게 쓰고, 구체적인 지적은 inline 코멘트로 단다.
- 문제점(버그, 불명확한 점, edge case, 보안, 성능, 이름)과 함께 잘된 점도 의도적으로 적는다. 기본 3~10개를 단다. 0개면 리뷰를 하지 않은 것처럼 보인다.
- 문제가 없어도 APPROVE 리뷰를 반드시 등록한다. 머지 여부를 정할 때 명시적인 승인 신호가 필요하다.

## 등록한 리뷰와 코멘트는 고치지 않는다

review summary, inline 코멘트, issue 코멘트는 등록한 뒤 수정하거나 삭제하지 않는다. 오타도 새 리뷰나 새 코멘트로 정정한다. 이 기록은 PR timeline에 회차 기록으로 남아야 한다.

`pulls/{n}/reviews/{id}`, `pulls/{n}/comments/{id}`, `issues/comments/{id}`에 대한 `PATCH`와 `DELETE`는 금지 endpoint다(`_common.sh` 상단의 FORBIDDEN ENDPOINTS 주석). 어떤 스크립트도 이 endpoint를 부르지 않으며, `tea api`로 직접 불러서도 안 된다.

## 리뷰 의견 반영

단발 모드에서 반영할 코멘트가 나오면, 따로 지시가 없는 한 같은 PR에 후속 커밋으로 바로 반영한다. 백로그로 넘기는 것은 사용자가 그렇게 말했을 때만이다. 리뷰 반복 모드에서는 `refs/review-loop.md`의 회차 진행 4번과 같은 규칙을 따른다. 어느 경우든 지적에 동의할 수 없으면 반영하지 않고 이유를 보고하는 것이 먼저다.

## 다국어 본문 손상 확인

JSON 본문은 모두 `tea api -d @-`(stdin)로 보낸다. 예전 curl `--data` 경로에서 줄바꿈 문자가 사라지던 문제는 없어졌지만, 그렇다고 안전이 자동으로 보장되지는 않는다. tea 0.14.0이 stdin 내용을 HTTPS로 보내는 과정에서 multi-byte 문자가 비결정적으로 손상된 사례가 있다(긴 review 본문에서 한 글자가 replacement 문자로 바뀌었다). bash, jq, printf를 거쳐 tea stdin에 들어가기까지는 UTF-8이 보존되는 것을 확인했으므로 손상은 tea 내부에서 일어난다.

- 한국어, 일본어, 이모지 같은 다국어 본문을 등록한 직후에는 결과를 다시 조회해 손상 여부를 확인한다.
- 손상을 발견하면 새 review나 코멘트로 정정한다. 등록된 본문을 직접 수정하지 않는다(위 규칙).
- 영문 ASCII만 있는 본문은 영향이 없다.
- 같은 순서로 호출해도 매번 결과가 다르다. 짧은 본문에서는 나타나지 않았고 긴 본문에서 나타나는 경향이 있지만 단정할 수 없다.

`_common.sh`의 `tea_api_json`이 이 경로를 쓴다. 새 endpoint를 추가할 때도 같은 helper나 `tea api -X METHOD -d @-` 형식을 쓴다.
