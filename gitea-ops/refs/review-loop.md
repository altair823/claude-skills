# 리뷰 반복 절차

명령은 SKILL.md 명령 표에 적힌 경로(이 스킬의 `bin/` 디렉토리)로 실행한다. PATH에는 없다.

## 진행 방식 정하기

`gitea-pr`로 PR을 만들기 직전에 사용자에게 진행 방식을 묻고 답을 받는다. 임의로 정하지 않는다.

1. **단발(기본)**: PR을 만들고 끝낸다. 리뷰는 필요할 때 따로 요청받는다.
2. **리뷰 반복**: PR을 만든 직후 셀프 리뷰를 한다. 반영할 지적이나 권장 사항이 있으면 후속 커밋으로 반영하고 다시 리뷰한다. 반영할 코멘트가 모두 해소되고 `event=APPROVE`만 남을 때까지 반복한다.

## 필요 조건: 리뷰어 로그인

리뷰는 리뷰어 계정으로 등록한다. tea 로그인 `gitea-ops-reviewer`가 있거나, 토큰이 `GITEA_REVIEWER_TOKEN` 환경변수 또는 `~/.config/gitea-ops/reviewer-token` 파일에 있어야 한다. Gitea는 PR 작성자가 자기 PR에 리뷰를 등록하는 것을 거부한다(422 self-review).

리뷰어 로그인이 없으면 `gitea-pr-review`가 "tea login 'gitea-ops-reviewer' 미등록 + token 없음"으로 실패한다. 이때 `tea api`나 curl로 author 계정의 코멘트를 직접 등록해 우회하지 않는다. 리뷰어 토큰이 없어 리뷰 반복을 진행할 수 없다고 사용자에게 알리고 결정을 기다린다.

## PR 사전 점검

1회차의 `gitea-pr-diff`를 부르기 전에 이 점검을 통과해야 한다. 통과하지 못하면 리뷰를 시작하지 않고 빠진 항목을 보고한다. 점검은 `gitea-pr-status <PR#> --wait-ci`로 한다.

필수 항목(항상 확인한다):

- `title`과 `body`가 비어 있지 않다. `changed_files > 0`이고 `draft == false`이며, `base`와 `head` 브랜치가 있다.
- PR 제목이 정규식 `^(feat|fix|docs|refactor|chore|test)(\([a-z0-9-]+\))?: .+`에 맞는다.
- 브랜치 이름이 정규식 `^(feat|fix|docs|refactor|chore|test)/[a-z0-9]+(-[a-z0-9]+)*$`에 맞는다.
- PR 본문에 `## 요약`과 `## 검증` 헤더가 있다. `## 요약` 절의 본문은 공백을 빼고 1자 이상이다.

CI 항목(CI가 있을 때만 확인한다): PR head SHA의 combined status를 조회한다.

- `total_count==0`이면 CI가 없는 것이므로 건너뛴다.
- `success`면 통과하고, `failure`나 `error`면 거부한다.
- `pending`이면 30초 간격으로 최대 20분 기다린다. 시간이 다 돼도 자동으로 실패 처리하지 않고 사용자에게 결정을 맡긴다(`gitea-pr-status` 종료 코드 3).

### `gitea-pr-status` 출력과 종료 코드

옵션은 `--json`(기본 출력은 `key=value`), `--wait-ci`(pending이면 기다린다), `--ci-timeout`(기본 1200초), `--ci-poll-interval`(기본 30초)이다.

출력 키는 `title_ok`, `body_ok`, `changed_files`, `draft`, `base`, `head`, `head_sha`, `ci_state`(`none|pending|success|failure|error`), `ci_count`, `lint_title`, `lint_branch`, `lint_body`, `gate_passed`다. `gate_passed=true`는 필수 항목을 모두 통과했고, `lint_*`가 모두 `pass`이며, CI가 없거나 `ci_state=success`라는 뜻이다.

lint 실패 이유는 stderr로만 출력하고 stdout에는 키만 출력한다. 자동화에서 호출할 때는 stdout만 파이프로 받는다.

| 종료 코드 | 의미 |
|---|---|
| 0 | 통과 |
| 1 | 필수 항목 실패, 또는 `--wait-ci` 없이 CI가 pending |
| 2 | CI failure 또는 error |
| 3 | `--wait-ci` 시간 초과. 자동 실패가 아니며 사용자에게 결정을 넘기라는 신호다 |
| 그 밖 | API 오류 |

## 회차 진행

매 회차 아래 1~4를 모두 수행한다. 2의 `gitea-pr-review`를 빼면 회차가 아니라 단순한 후속 작업이다.

1. `gitea-pr-diff <PR#>`로 현재 diff를 출력한다.
2. 리뷰어 입장에서 분석한 뒤 `gitea-pr-review`를 반드시 호출한다. 회차마다 새 리뷰를 한 건 등록한다.
   - 반영할 지적이 하나라도 있으면 `--event REQUEST_CHANGES`와 inline 코멘트로 등록한다. 결함, 불명확한 점, 누락뿐 아니라 오타, 이름, 가독성 같은 사소한 지적(nit)도 포함한다. 사소한 지적이라도 APPROVE 안에 넣어 넘기지 않는다.
   - 지적이 0건이고 칭찬이나 동의만 있으면 `--event APPROVE`로 등록한다.
   - summary 첫 줄은 `회차 N`으로 시작한다. 예: `회차 2: 회차 1 지적 모두 반영. 추가 권장 1건.`
3. 종료 조건: 방금 등록한 리뷰가 `event=APPROVE`이고, inline 코멘트 중 문제 지적(issue)과 제안(suggestion)이 0개다.
4. 종료 조건을 채우지 못했으면 inline 코멘트와 summary를 반영해 새 커밋을 만들고 push한 뒤 다음 회차의 1로 돌아간다.

Gitea는 push가 들어와도 이전 리뷰를 자동으로 dismiss하지 않고 "Outdated" 배지만 붙인다. 리뷰 반복을 했는데 PR에 APPROVE 리뷰 하나만 보인다면 회차를 빠뜨렸다는 뜻이다.

## 안전 장치

- 최대 5회차까지만 한다. 그 뒤에도 반영할 코멘트가 남으면 반복을 멈추고 사용자에게 보고한다.
- 지적의 근거에 동의할 수 없으면 반영하지 않고 이유를 보고한 뒤 결정을 사용자에게 맡긴다. 리뷰 내용을 검토 없이 그대로 따르지 않는다.
- 같은 inline 코멘트가 두 회차 연속으로 같은 위치에 다시 나오면 수렴하지 않는 것으로 보고 반복을 멈춘 뒤 사용자에게 보고한다.

## 끝난 뒤 안내

APPROVE로 끝나면 사용자에게 알릴 때 PR URL(예: `https://gitea.example/owner/repo/pulls/N`)을 반드시 넣는다. URL이 없으면 사용자가 PR 번호를 다시 찾아야 한다.

PR URL은 다음 순서로 얻는다.

1. `gitea-pr`가 PR을 만든 직후 출력한 URL을 보관했다가 다시 쓴다. 가장 확실한 방법이다.
2. 그게 어려우면 `gitea-pr-review` 출력(`https://host/owner/repo/pulls/N#issuecomment-XXX`)에서 `#` 앞까지 잘라 쓴다.

리뷰 반복이 APPROVE로 끝났다고 해서 머지하지 않는다. 머지는 사용자가 명시적으로 요청했을 때만 `gitea-pr-merge`로 한다.
