---
name: leaf-ops
description: Use when you have produced something a human should look at in a browser — an HTML report, a chart, a dashboard, a rendered document, a generated static site — and you need a shareable link instead of a file path. Uploads to leaf (https://leaf.altair823.xyz), a private static page host, and prints the URL. `leaf-put` publishes a file or a whole directory, `leaf-ls` lists what is up, `leaf-rm` deletes a site. Credentials stay in a config file and never enter the transcript or the process list. Depends only on curl (jq optional for pretty listing).
---

# leaf-ops

leaf는 만든 결과물을 브라우저로 볼 수 있는 링크로 바꿔 주는 서비스다. 파일 경로 대신
URL을 건네야 할 때 쓴다.

기본은 **비공개**이고 **마지막 업로드로부터 30일 뒤 자동 삭제**된다. 일회성 리포트는
그냥 올리면 되고, 오래 둘 것만 `--keep`을 붙인다.

## 언제 쓰나

- 리포트·분석 결과를 HTML로 만들었고 사람이 봐야 할 때 → `leaf-put`
- 차트·다이어그램·스크린샷을 링크로 건네야 할 때 → `leaf-put`
- 여러 파일로 된 정적 사이트를 통째로 올릴 때 → `leaf-put <디렉토리>`
- 내가 뭘 올려 뒀는지 확인할 때 → `leaf-ls`
- 잘못 올린 것을 치울 때 → `leaf-rm`

터미널에만 남기면 되는 중간 산출물이나, 사용자가 로컬 파일로 원한 결과물에는 쓰지 않는다.

## 도구

경로는 이 SKILL.md 옆 `bin/`이다. PATH에 없으므로 한 번 잡아 두고 부른다.

```sh
LEAF="<이 SKILL.md가 있는 디렉토리>"
"$LEAF/bin/leaf-put" report.html 2026-08-report
```

### `leaf-put`

```
leaf-put <파일|디렉토리> <사이트>[/경로] [--public] [--keep]
```

성공하면 사람에게 그대로 건넬 URL 한 줄을 stdout에 찍는다. 그 줄만 쓰면 된다.

```sh
# 파일 하나 — 경로를 생략하면 index.html로 올라간다
leaf-put report.html 2026-08-report
# → https://leaf.altair823.xyz/2026-08-report/

# 같은 사이트에 파일 더 얹기
leaf-put chart.svg 2026-08-report/chart.svg

# 디렉토리 통째로 (상대 경로 유지)
leaf-put ./site handbook --keep --public
```

| 옵션 | 뜻 |
|---|---|
| `--public` | 인증 없이 읽을 수 있게 한다. 사내·외부에 링크를 넘길 때 |
| `--keep` | 30일 만료를 끈다. 계속 유지할 문서 사이트에만 |

**옵션을 생략하면 그 사이트의 기존 설정이 유지된다.** 빼도 공개나 영구가 풀리지 않으므로,
이미 올려 둔 사이트를 갱신할 때는 옵션 없이 그냥 올리면 된다.

### `leaf-ls`

```
leaf-ls [--json]
```

사이트 목록과 각각을 올린 주체·공개 여부·삭제 예정일을 보여준다. `--json`은 그대로 파싱해서 쓴다.

### `leaf-rm`

```
leaf-rm <사이트> [--yes]
```

사이트를 통째로 지운다. 파일 하나만 지우는 기능은 없다 — 덮어쓰면 된다.
대화형 터미널이면 확인을 묻고, 자동화에서는 `--yes`를 붙인다.

## 규칙

지키지 않으면 서버가 400으로 거절한다. 스크립트가 먼저 걸러 주지만, 알고 쓰는 편이 낫다.

- **사이트 이름**: 소문자·숫자·`-`·`_`만, 64자까지. `_token`은 예약어라 못 쓴다.
- **파일 경로**: `A-Za-z0-9._-`와 `/`만. 공백과 한글은 못 쓴다.
- **크기**: 파일 하나당 32MB까지.

### 사이트 안에서는 상대 경로를 쓸 것

사이트를 경로로 나누기 때문에, HTML이 `/style.css`처럼 절대 경로로 리소스를 참조하면
**다른 사이트를 가리켜 깨진다.** `style.css`나 `assets/style.css`처럼 상대 경로로 쓴다.
한 파일짜리 HTML이면 신경 쓸 일이 없다.

## 사이트 이름 고르기

이름이 곧 URL이고 사람이 읽는다. 날짜와 내용을 담아 나중에 목록에서 알아볼 수 있게 한다.

- 좋음: `2026-08-jira-audit`, `k8s-cost-report`, `handbook`
- 나쁨: `output`, `tmp`, `report1`

같은 이름에 다시 올리면 덮어쓰면서 만료 시계가 되감긴다. 갱신되는 리포트는 같은 이름을
계속 쓰는 편이 낫다.

## 설정

`~/.config/leaf-ops/config` (mode 0600):

```
LEAF_URL=https://leaf.altair823.xyz
LEAF_AUTH=<이름>:<비밀값>
```

환경변수 `LEAF_AUTH`가 설정 파일보다 우선한다. 에이전트마다 다른 토큰을 주면 대시보드의
"올린 주체"가 실제로 누구인지 가려진다.

**비밀값을 읽거나 출력하지 말 것.** 스크립트가 내부에서만 읽어 `--netrc-file`로 curl에
넘기므로 `ps`에도 안 보인다. `cat ~/.config/leaf-ops/config`를 하면 그 보호가 무의미해진다.

토큰이 없거나 만료됐으면 사용자에게 대시보드(`https://leaf.altair823.xyz/`)에서 발급해
달라고 요청한다. **에이전트 토큰으로는 발급이 안 된다** — 관리자 계정만 가능하고, 시도하면
403이 온다.

## 오류

| 증상 | 원인과 대처 |
|---|---|
| `인증 실패` | 토큰이 폐기됐거나 틀렸다. 사용자에게 재발급을 요청한다 |
| `403` (토큰 발급 시도) | 정상이다. 발급은 관리자만 한다 |
| 브라우저에서 로그인 팝업 | 그 사이트가 비공개다. 링크를 넘기려면 `--public`으로 다시 올린다 |
| 하위 디렉토리 링크가 이상한 곳으로 | 끝에 `/`를 붙인다. `/site/sub/`가 정확한 형태다 |
| `32MB 상한` | 이미지를 줄이거나 파일을 나눈다 |
