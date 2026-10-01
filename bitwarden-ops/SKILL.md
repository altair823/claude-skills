---
name: bitwarden-ops
description: Use when a command or script needs a secret, password, username, API token, or SSH key from the user's Bitwarden vault, when checking which credentials are stored, when a credential still has to be registered, or when the vault is locked or a just-added item cannot be found.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/bin/bw-status)
---

# bitwarden-ops

현재 상태: !`${CLAUDE_SKILL_DIR}/bin/bw-status || true`

`session=set` and `vault=unlocked` mean the tools below work now. Anything else means
the vault is locked: ask the user to run `${CLAUDE_SKILL_DIR}/bin/bw-unlock` in their own
terminal, then continue.

Reads resolve a `bw://` reference to stdout or into a child process env. Writes read
the secret from the user's terminal, so the user runs them. Deps: `bash`, `bw`, `jq`.

## Reference grammar

| Reference | Value |
|---|---|
| `bw://<item>` | login password (same as `/password`) |
| `bw://<item>/password` | login password |
| `bw://<item>/username` | login username |
| `bw://<item>/notes` | notes. Secure note items only have this. |
| `bw://<item>/<field>` | custom field `<field>` |

- `username`, `password`, `notes` are reserved. A custom field with one of these names
  cannot be read.
- `bw-ls` shows each item's kind and the references it supports. Check it instead of
  guessing field names.
- SSH private keys live in an item's notes (`bw://ssh-<id>/notes`).

## Commands

```sh
# Run a command with secrets in its env (never in argv)
${CLAUDE_SKILL_DIR}/bin/bw-exec LOGIN=bw://item/username TOKEN=bw://item -- <cmd> [args...]

# Pipe one value to a consumer (stdout, no trailing newline)
${CLAUDE_SKILL_DIR}/bin/bw-get bw://item/api | <consumer>
${CLAUDE_SKILL_DIR}/bin/bw-get --ssh bw://ssh-host | ssh-add -

# What is stored: one line per item, "<name>\t<kind>\t<refs>" (names only, no values)
${CLAUDE_SKILL_DIR}/bin/bw-ls [search]
#   harbor.altair823.xyz	login	username,password
#   GITEA_ADMIN_TOKEN	note	notes

# Pull the latest items from the server (the user just added one and it is not found)
${CLAUDE_SKILL_DIR}/bin/bw-sync

${CLAUDE_SKILL_DIR}/bin/bw-status          # session/vault state; exit 3 when locked
${CLAUDE_SKILL_DIR}/bin/bw-lock            # end the session (Claude may run this)
```

Kinds are `login`, `note`, `card`, `identity`, `ssh`. A `-` in the refs column means the
item has no readable value.

Never capture a value just to look at it. To check that a reference works, measure it:
`${CLAUDE_SKILL_DIR}/bin/bw-get bw://item/username | wc -c`.

## Errors

Error messages never contain values. Read them before retrying.

- Exit 3 (`locked vault`): no session, or the session expired. Ask the user to run
  `bw-unlock`. Do not retry.
- `항목이 없습니다`: no item with that name. If the user just registered it, run
  `bw-sync` and try again. Otherwise check names with `bw-ls`.
- `보안 메모 항목입니다`: the item is a secure note. Use `bw://<item>/notes`.
- `... 값이 없습니다. 쓸 수 있는 참조: ...`: the item has no such value. The message
  lists the references it does have.
- `검색 결과가 여러 항목입니다`: the name matches several items. Use the exact name
  from `bw-ls`.

## Session setup (the user does this)

Either is fine. The env variable wins when both are present (`BW_SESSION` 우선).

```sh
# A) export in the shell before launching Claude Code
export BW_SESSION="$(bw unlock --raw)"   # the user types the master password

# B) any time, even while Claude Code is running, in the user's own terminal
${CLAUDE_SKILL_DIR}/bin/bw-unlock        # bw prompts for the master password
```

(B) writes the session to `$HOME/.cache/bitwarden-ops/session` (0600). Every `bw-*`
command reads it when `BW_SESSION` is unset. `bw-lock` runs `bw lock` and removes it.

## Registering a credential (the user does this)

Build the command and give it to the user. Claude never runs `bw-put`.

```sh
${CLAUDE_SKILL_DIR}/bin/bw-put bw://item                 # login password, typed at a hidden prompt
${CLAUDE_SKILL_DIR}/bin/bw-put bw://item/api             # custom field
${CLAUDE_SKILL_DIR}/bin/bw-put bw://ssh-<id>/notes --type note --from-file ~/.ssh/<key>
```

`--type password|field|note` overrides the type implied by the reference. `--from-file`
reads the secret bytes from a file instead of the terminal (multi-line kept verbatim).
`--replace` is required to overwrite an existing value. `bw-put` does not set usernames;
the user enters those in the Bitwarden app.

## Hard rules (non-negotiable)

1. **Master password: user only.** Only the user runs `bw unlock` or `bw-unlock`. Claude
   never prompts for, receives, stores, or echoes it.
2. **Secret values never leak.** Reads go to stdout or a child env only. Writes come from
   the user's terminal only. Never in Claude's context, persistent argv, disk, or logs.
   (Sole accepted exception: `bw-put` hands the value to `jq` for one sub-ms call, so it
   is briefly in jq's argv for the same user. See the NOTE in `bin/bw-put`.)
3. **Use these tools, not raw `bw`.** Do not run `bw get`, `bw list`, or `bw sync`
   yourself, and do not read the session file. `bw-get bw://item/username` replaces
   `bw get username item`; `bw-sync` replaces `bw sync`.
4. **Locked vault means stop.** No `BW_SESSION` and no session file makes every command
   exit 3. Ask the user to run `bw-unlock`. The session file is the one accepted at-rest
   secret (the live session key, 0600, outside any repo); `bw-lock` ends it.
5. **bw-put is user-run.** It reads the secret from `/dev/tty`. Claude gives the user the
   exact command line.
6. **Overwrite needs eyes.** `bw-put` refuses to overwrite an existing non-empty value
   unless `--replace` is given. Deletion is not supported.
