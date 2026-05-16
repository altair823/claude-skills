---
name: bitwarden-ops
description: Use when the user wants to read or register Bitwarden personal-vault credentials from any project — resolve a secret into a command (`bw-exec`), pipe it to a consumer like ssh-agent (`bw-get`), list what is stored without exposing values (`bw-ls`), register a not-yet-stored credential (`bw-put`, user-run), or check vault/session status (`bw-status`). Secret values never enter Claude's context, argv, disk, or logs. Self-contained; depends only on the `bw` CLI + `jq`.
---

# bitwarden-ops

Self-contained Bitwarden personal-vault (`bw`) credential toolkit. Reads resolve a
`bw://` reference to stdout or into a child process env; writes read the secret from
the controlling terminal and are therefore run by the user, not Claude. Deps: `bash`,
`bw` (Bitwarden CLI), `jq`.

## Resolve this skill's tools first
Tools are in `bin/` beside this SKILL.md. Set `BW` to this skill's base directory once,
then call every tool as `"$BW/bin/<tool>"` (works from any cwd; nothing on PATH):
```sh
BW="<absolute path of the directory containing this SKILL.md>"
"$BW/bin/bw-status"
```

## Session setup (the user does this once per session)
```sh
export BW_SESSION="$(bw unlock --raw)"   # the user types the master password — never Claude
```
No `BW_SESSION` ⇒ every command refuses to start (exit 3, "locked vault").

## Reference grammar
- `bw://<item>` → the item's password
- `bw://<item>/<field>` → custom field `<field>`
- `bw://<item>/notes` → the item's notes
- `--ssh` (bw-get) → SSH private key stored in notes (stdout only, for ssh-agent)

## When to use
- "Run X with a vault token" → `"$BW/bin/bw-exec" TOKEN=bw://item/api -- <cmd>`
- "Pipe a vault key (ssh-agent etc.)" → `"$BW/bin/bw-get" --ssh bw://ssh-host | ssh-add -`
- "What's stored (no values)?" → `"$BW/bin/bw-ls" [search]`
- "Register a credential I haven't stored" → tell the user to run
  `"$BW/bin/bw-put" bw://item/field` themselves; they paste the secret at the prompt
- "Vault/session status" → `"$BW/bin/bw-status"`

## Hard rules (non-negotiable)
1. **Master password: user only.** Only the user runs `bw unlock`. Claude never
   prompts for, receives, stores, or echoes it.
2. **Secret values never leak.** Reads → stdout / child env only. Writes → the
   user's terminal only. Never in Claude's output, argv, disk, or logs.
3. **Locked-vault default.** No `BW_SESSION` ⇒ refuse (exit 3). Ask the user to
   `bw unlock`; never handle the master password.
4. **bw-put is user-run.** It reads the secret from `/dev/tty`. Claude constructs
   the `bw://` target + `--type` and gives the user the exact command line to run
   themselves — Claude does not invoke `bw-put`.
5. **Overwrite needs eyes.** `bw-put` refuses to overwrite an existing non-empty
   value unless `--replace` is given. No deletion is supported at all.
