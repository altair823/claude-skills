# gitea-ops 리뷰 루프 강화 설계

- **날짜**: 2026-05-01
- **대상 skill**: `gitea-ops`
- **목적**: 리뷰 루프 모드의 entry-gate 추가 및 리뷰·코멘트 영속성 보장

## 배경

`gitea-ops` skill은 PR 생성 후 단발 또는 리뷰 루프 모드를 선택할 수 있다. 현재 리뷰 루프 동작은 회차당 `gitea-pr-diff` → `gitea-pr-review` → 종료 조건 확인 → 미충족 시 후속 commit 패턴으로 이미 정의되어 있다.

다음 두 가지가 부족하다:

1. **Entry-gate 부재**: PR 자체가 리뷰 받을 수 있는 상태인지 확인하지 않고 곧장 1회차로 진입한다. title/body가 비었거나, diff가 비었거나, draft 상태이거나, CI가 fail이어도 리뷰가 시작된다.
2. **리뷰·코멘트 영속성 보장 명시 부족**: Gitea 자체 동작 (timeline 보존, "Outdated" 배지) 은 설명되어 있지만, Claude가 실수로 PATCH/DELETE 호출을 하지 않아야 한다는 규칙이 명문화되어 있지 않다. 향후 skill 확장 시 사고 가능성이 있다.

## 변경 요약

1. **Entry-gate 신설** — 루프 1회차 진입 전 PR shape + (있다면) CI 상태 검증.
2. **`gitea-pr-status` 신규 헬퍼 스크립트** — entry-gate 점검에 필요한 정보를 한 번에 출력.
3. **리뷰·코멘트 영속성 규칙 명문화** — 구현 측면(스크립트 미구현)과 문서 규칙(향후 확장 금지) 양쪽에 추가.

## Entry-gate 사양

리뷰 루프 모드를 선택한 직후, 1회차 `gitea-pr-diff` 호출 **전에** 다음 검증을 수행한다.

### 필수 항목 (항상 검사)

- `title` 비어있지 않음
- `body` 비어있지 않음
- `changed_files > 0` — 빈 diff 아님 (Gitea PR object 의 `changed_files` 필드)
- `draft == false`
- `base` / `head` branch 모두 존재 (Gitea API가 PR 메타에서 제공)

하나라도 실패 시: 루프 진입 거부. 사용자에게 누락 항목을 보고하고 PR 보완 후 재진입 안내.

### CI 항목 (조건부 검사)

`/repos/{owner}/{repo}/commits/{head_sha}/status` 의 `statuses` 배열을 조회한다.

- 배열이 비어 있음 → CI 미설정으로 간주, CI 항목 skip.
- 배열이 비어 있지 않음 → CI 있음. 다음 정책 적용:
  - **polling 주기**: 30초.
  - **최대 polling 시간**: 20분 (= 30초 × 40회).
  - 도중 `state=success` 도달 시 즉시 통과.
  - 도중 `state=failure` 또는 `state=error` 발생 시 즉시 루프 진입 거부, 사용자에게 보고.
  - 20분 경과 후에도 `state=pending` 유지 시 자동 실패 처리하지 않고 **사용자에게 위임** — Claude는 현재 상태와 마지막 polling 결과를 보고하고, 사용자의 결정 (연장 / 중단 / 강제 진입) 을 기다린다.

### 통과 기준

- 모든 필수 항목 통과 + (CI 없음 OR `ci_state=success`).

## 신규 스크립트: `gitea-pr-status`

### 책임

PR의 entry-gate 점검에 필요한 메타데이터와 CI 상태를 한 번에 dump 한다. `gitea-pr-diff` 와 분리하여 책임 단일화.

### 인터페이스

```
gitea-pr-status <PR#> [--json] [--wait-ci] [--ci-timeout SECONDS]
                      [--ci-poll-interval SECONDS]
                      [-r owner/repo] [-u URL]
```

옵션:

- `--json`: 단일 JSON 객체로 출력. 미지정 시 사람-친화 key=value 라인.
- `--wait-ci`: CI가 `pending` 이면 polling. 미지정 시 즉시 현재 상태만 출력하고 종료.
- `--ci-timeout SECONDS`: polling 최대 시간 (기본 1200 = 20분).
- `--ci-poll-interval SECONDS`: polling 간격 (기본 30). `--wait-ci` 사용 시 1 이상이어야 한다 (무한 루프 방지).

### 출력 (텍스트 기본)

```
title_ok=true
body_ok=true
changed_files=12
draft=false
base=main
head=feat/widget
head_sha=abc123...
ci_state=success
ci_count=3
gate_passed=true
```

### 출력 (JSON)

```json
{
  "title_ok": true,
  "body_ok": true,
  "changed_files": 12,
  "draft": false,
  "base": "main",
  "head": "feat/widget",
  "head_sha": "abc123...",
  "ci_state": "success",
  "ci_count": 3,
  "gate_passed": true
}
```

`ci_state` 값: `none | pending | success | failure | error`.

`gate_passed`: 모든 필수 항목 + (CI 없음 OR `ci_state=success`).

### 종료 코드

- 0: gate_passed=true.
- 1: 필수 항목 실패 또는 CI pending(--wait-ci 미사용).
- 2: CI failure / error.
- 3: CI pending이면서 timeout 도달 (`--wait-ci` 사용 시). **이 코드는 자동 실패 아님** — 호출자(Claude) 가 결과를 사용자에게 보고하고 결정 (연장 / 중단 / 강제 진입) 을 위임해야 한다는 신호.
- 그 외: API 오류 등 일반 실패.

## 리뷰·코멘트 영속성 규칙

### 구현 측 보장

- `gitea-pr-review`, `gitea-issue`, 기타 어느 스크립트도 review / review-comment / issue-comment 에 대해 `PATCH` 또는 `DELETE` API 호출을 **포함하지 않는다**. 현재 상태 유지.
- `_common.sh` 상단에 sentinel 주석을 추가하여 차단 대상 endpoint 를 명시한다:

  ```sh
  # FORBIDDEN ENDPOINTS — review/comment 영속성 보장.
  # 본 skill의 어떤 스크립트도 다음 endpoint 를 호출해선 안 된다:
  #   PATCH  /repos/{owner}/{repo}/pulls/{index}/reviews/{id}
  #   DELETE /repos/{owner}/{repo}/pulls/{index}/reviews/{id}
  #   PATCH  /repos/{owner}/{repo}/pulls/{index}/comments/{id}
  #   DELETE /repos/{owner}/{repo}/pulls/{index}/comments/{id}
  #   PATCH  /repos/{owner}/{repo}/issues/comments/{id}
  #   DELETE /repos/{owner}/{repo}/issues/comments/{id}
  ```

### 문서 규칙

`## 작성 규칙` 섹션 끝에 다음 항목을 추가한다:

> - **리뷰·코멘트 영속성**: review summary, inline review comment, issue comment 는 한 번 등록되면 **수정·삭제하지 않는다**. 오타나 잘못된 판단을 발견한 경우에도 새 review 또는 새 코멘트로 정정한다 — timeline 의 회차 기록은 영구 보존되어야 한다. 본 skill 에 새 스크립트를 추가할 때도 위 6개 endpoint (PATCH/DELETE × reviews/PR-comments/issue-comments) 호출은 금지.

## SKILL.md 변경

1. `## PR 생성 전 선택지: 리뷰 루프` 하위 구조:

   ```
   ## PR 생성 전 선택지: 리뷰 루프
   ### Entry-gate (신규)
   ### 루프 한 회차 동작 (기존)
   ### 가드 (기존)
   ### 사람 머지 단계는 변경 없음 (기존)
   ```

2. `### 루프 한 회차 동작` 첫 줄 앞에 "회차 1 진입 전 entry-gate 를 통과해야 한다" 한 줄 prefix 추가.

3. `## 스크립트` 섹션에 `### gitea-pr-status` subsection 추가 (위 인터페이스 + 출력 예시).

4. `## 작성 규칙` 끝에 위 "리뷰·코멘트 영속성" 항목 추가.

## 변경 없음 항목

- 단발 / 리뷰 루프 모드 선택 질문 유지.
- 회차 종료 조건 (APPROVE + 칭찬-only) 유지.
- 회차 가드 (최대 5회, 수렴 실패 감지) 유지.
- 사람 머지 단계 유지.
- caveman 미적용 규칙 유지.

## 테스트 전략

`tests/` 디렉토리 패턴 (Gitea API mocking) 을 따라 다음 케이스 추가:

- `test_gitea_pr_status.sh`:
  - 모든 필수 통과 + CI 없음 → `gate_passed=true`, exit 0.
  - 모든 필수 통과 + CI success → `gate_passed=true`, exit 0.
  - title 빈 문자열 → `title_ok=false`, `gate_passed=false`, exit 1.
  - draft=true → `gate_passed=false`, exit 1.
  - files_changed=0 → exit 1.
  - CI failure → exit 2.
  - `--wait-ci` 사용 시 pending → success 전환 → exit 0 (mock 으로 시간 단축).
  - `--wait-ci` 사용 시 pending 유지 + timeout → exit 3.
  - `--json` 출력 형식 검증.

기존 테스트 (`test_gitea_pr_diff.sh`, `test_gitea_pr_review.sh`) 는 영향 없음.

## 마이그레이션 / 호환성

- 기존 단발 모드 사용자: 영향 없음.
- 기존 리뷰 루프 사용자: 동작이 entry-gate 통과 시 기존과 동일. PR shape 가 부족하거나 CI fail 인 경우 거부되는 것이 새 동작.
- 기존 스크립트 시그니처 변경 없음. `gitea-pr-status` 만 신규.

## 위험 / 미해결 항목

- Gitea Actions 가 아닌 외부 CI (drone 등) 가 statuses API 에 결과를 push 하는 환경에서도 동작은 동일하지만, 일부 CI 가 statuses 를 등록하지 않고 별도 채널로 통지하는 경우엔 detection 불가. 이 경우엔 "CI 없음"으로 처리되어 entry-gate 통과 — 사용자가 책임진다.
- `pending` 20분 위임 흐름은 대화형 환경 (Claude Code) 에서만 자연스럽다. 비대화형 호출에서는 `--wait-ci` 미사용을 권장 — 호출자가 결과를 보고 결정.
