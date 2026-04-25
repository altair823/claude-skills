# claude-skills

Personal Claude Code skill collection. Each subdirectory is a self-contained skill
with `SKILL.md` and any helper scripts.

## Skills

- [gitea-ops](gitea-ops/SKILL.md) — drive Gitea (releases / PRs / issues) via
  REST API from the CLI.

## Layout

```
~/claude-skills/               ← git repo
├── README.md
├── .gitignore
└── <skill-name>/
    ├── SKILL.md
    └── bin/ | assets/ | ...
```

Symlinked into `~/.claude/skills/<name>` so Claude Code picks them up.

## Add a new skill

```sh
mkdir -p ~/claude-skills/<name>/bin
# write SKILL.md + scripts
ln -sfn ~/claude-skills/<name> ~/.claude/skills/<name>
```
