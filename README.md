# claude-skills

개인용 Claude Code 스킬 모음. 각 하위 디렉토리는 `SKILL.md`와 보조 스크립트로 구성된 독립 스킬이야.

## Skills

- [gitea-ops](gitea-ops/SKILL.md) — Gitea (릴리스 / PR / 이슈)를 REST API로 CLI에서 조작.
- [harbor-ops](harbor-ops/SKILL.md) — 사설 Harbor 컨테이너 레지스트리(프로젝트 / repo / tag / 스캔 요약)를 REST API로 read-only 브라우즈.
- [homelab-ops](homelab-ops/SKILL.md) — 홈서버 fleet(독립 Proxmox 호스트·VM/LXC·어플라이언스)를 guard 단일 chokepoint로 안전하게 운영·프로비저닝·포렌식.
- [paperboy-ops](paperboy-ops/SKILL.md) — paperboy(영수증 프린터 HTTP 서비스)와 상호작용. 라이브 OpenAPI로 엔드포인트 탐색 후 generic 클라이언트로 호출.

## Layout

```
~/claude-skills/               ← git repo (이 저장소)
├── README.md
├── .gitignore
└── <skill-name>/
    ├── SKILL.md
    └── bin/ | assets/ | ...
```

Claude Code는 `~/.claude/skills/<name>/SKILL.md`를 읽어서 스킬을 등록해. 따라서 이 repo의 각 스킬을 그 경로에 **연결(심볼릭 링크 / junction)** 만 해두면, repo에서 수정한 내용이 즉시 반영돼.

---

## 설치 방법

먼저 한 번만 스킬 디렉토리를 만들어둬:

```sh
mkdir -p ~/.claude/skills
```

### Windows (PowerShell 또는 Git Bash)

관리자 권한 / Developer Mode 없이 동작하는 **디렉토리 junction**을 사용:

```sh
# Git Bash
cmd //c "mklink /J C:\Users\<user>\.claude\skills\<name> C:\Users\<user>\claude-skills\<name>"
```

```powershell
# PowerShell
New-Item -ItemType Junction `
  -Path  "$env:USERPROFILE\.claude\skills\<name>" `
  -Target "$env:USERPROFILE\claude-skills\<name>"
```

### macOS / Linux

```sh
ln -sfn ~/claude-skills/<name> ~/.claude/skills/<name>
```

### 설치 확인

```sh
ls ~/.claude/skills/
```

`<name>` 디렉토리가 보이고 그 안에 `SKILL.md`가 있으면 끝. Claude Code 재시작 후 바로 사용 가능.

---

## 새 스킬 추가하기

1. **이 repo에 디렉토리 생성**

   ```sh
   mkdir -p ~/claude-skills/<name>/bin
   ```

2. **`SKILL.md` 작성** — 스킬 이름, 언제 발동할지(description), 사용법을 frontmatter와 함께 기술.

3. **글로벌 설치** — 위 OS별 명령어로 `~/.claude/skills/<name>`에 연결.

4. **커밋 & 푸시**

   ```sh
   git add <name>
   git commit -m "feat(<name>): initial skill"
   git push
   ```

repo에 새 스킬이 추가될 때마다 위 3번 (연결) 단계만 한 번 더 실행하면 돼.

---

## 다른 머신에서 통째로 설치

repo 전체를 클론한 뒤 모든 스킬을 한 번에 연결:

```sh
git clone <this-repo-url> ~/claude-skills
mkdir -p ~/.claude/skills

# macOS / Linux
for d in ~/claude-skills/*/; do
  name=$(basename "$d")
  [ "$name" = ".git" ] && continue
  ln -sfn "$d" ~/.claude/skills/"$name"
done
```

```powershell
# Windows PowerShell
$repo = "$env:USERPROFILE\claude-skills"
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills" | Out-Null
Get-ChildItem -Directory $repo | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
  New-Item -ItemType Junction `
    -Path  "$env:USERPROFILE\.claude\skills\$($_.Name)" `
    -Target $_.FullName -Force | Out-Null
}
```
