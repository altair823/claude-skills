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
Either is fine — **env wins** when both are present:

```sh
# A) classic: export in the shell BEFORE launching Claude Code
export BW_SESSION="$(bw unlock --raw)"   # the user types the master password — never Claude

# B) any time (even after Claude is already running): run in YOUR terminal
"$BW/bin/bw-unlock"                       # bw prompts the master password on your tty
```
(B) writes the raw session to `$HOME/.cache/bitwarden-ops/session` (0600, durable,
outside any repo). Every `bw-*` command reads it when `BW_SESSION` is unset, so the
user can unlock at any point and Claude picks it up. `bw-lock` ends the session
(`bw lock` + removes the file). No `BW_SESSION` and no session file ⇒ every command
refuses to start (exit 3, "locked vault").

## Reference grammar
- `bw://<item>` → the item's password
- `bw://<item>/<field>` → custom field `<field>`
- `bw://<item>/notes` → the item's notes
- `--ssh` (bw-get) → SSH private key stored in notes (stdout only, for ssh-agent)
- SSH private keys live in an item's notes (`bw://ssh-<id>/notes`); register
  with `bw-put ... --type note --from-file <keyfile>`, consume via `bw-get
  --ssh` or a `/notes` ref.

## When to use
- "Run X with a vault token" → `"$BW/bin/bw-exec" TOKEN=bw://item/api -- <cmd>`
- "Pipe a vault key (ssh-agent etc.)" → `"$BW/bin/bw-get" --ssh bw://ssh-host | ssh-add -`
- "What's stored (no values)?" → `"$BW/bin/bw-ls" [search]`
- "Register a credential I haven't stored" → tell the user to run
  `"$BW/bin/bw-put" bw://item/field` themselves; they paste the secret at the prompt
- "Register a multi-line secret (SSH private key) from a file" → tell the user
  to run `"$BW/bin/bw-put" bw://ssh-<id>/notes --type note --from-file ~/.ssh/<key>`
  themselves. `--from-file PATH` reads the secret bytes from PATH instead of the
  tty (still user-run; Claude never runs bw-put). Multi-line preserved verbatim.
- "Vault/session status" → `"$BW/bin/bw-status"`
- "Unlock so Claude can use the vault" → tell the user to run `"$BW/bin/bw-unlock"`
  in their own terminal (bw prompts their master password; Claude never sees it)
- "Lock / end the session" → `"$BW/bin/bw-lock"` (Claude may run this)

## Hard rules (non-negotiable)
1. **Master password: user only.** Only the user runs `bw unlock`. Claude never
   prompts for, receives, stores, or echoes it.
2. **Secret values never leak.** Reads → stdout / child env only. Writes → the
   user's terminal only. Never in Claude's context, persistent argv, disk, or
   logs. (Sole accepted exception: `bw-put` hands the value to `jq` for one
   sub-ms call, so it is transiently in jq's argv to the same user/root —
   local single-user threat model only; see the NOTE in `bin/bw-put`.)
3. **Locked-vault default.** No `BW_SESSION` env AND no `$HOME/.cache/bitwarden-ops/session`
   ⇒ refuse (exit 3). Tell the user to run `bw-unlock` themselves; never handle the
   master password. The session file is a durable 0600 file (the live vault session
   key, not a stored credential); it is the one accepted at-rest secret, kept outside
   any repo. `bw-lock` ends it.
4. **bw-put is user-run.** It reads the secret from `/dev/tty`. Claude constructs
   the `bw://` target + `--type` and gives the user the exact command line to run
   themselves — Claude does not invoke `bw-put`.
5. **Overwrite needs eyes.** `bw-put` refuses to overwrite an existing non-empty
   value unless `--replace` is given. No deletion is supported at all.
