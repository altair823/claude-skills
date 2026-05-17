---
name: homelab-ops
description: Use when the user wants to inspect or operate their homelab fleet (independent Proxmox hosts, their VMs/LXC, and standalone appliances like Victoria Metrics / NAS) — list/status/metrics, start/stop/restart/snapshot, destroy/storage/network changes, or Phase-1 provisioning (clone). Read inventory with this skill's `bin/inv`; perform ANY state change ONLY through `bin/guard`, which grades the action (safe/caution/destructive), gates on the presence of the injected transport credential, dry-runs + requires explicit approval for destructive/prod ops, and forensically logs every operation. Credentials are `bw://` references; resolution is delegated to the bitwarden-ops skill via `bw-exec`, never reimplemented here and never on disk.
---

# homelab-ops

Fleet ops toolkit for a heterogeneous homelab. Core design tension: **strong guard on destructive actions ↔ enough authority for day-2 automation**, with every operation forensically reconstructable. Deps: `bash`, `jq`, `python3`+PyYAML, `curl`, `ssh`/`ssh-agent`. Credential resolution is delegated to the **bitwarden-ops** skill (`bw-exec`); homelab-ops itself never calls `bw`.

## Resolve this skill's tools first
The toolkit is in `bin/` beside this SKILL.md. Claude is given this skill's base
directory when the skill loads — set `HL` to it once, then call every tool as
`"$HL/bin/<tool>"` (works from any cwd; nothing is installed on PATH):
```sh
HL="<absolute path of the directory containing this SKILL.md>"   # this skill's base dir
"$HL/bin/inv" list
```
Read: `"$HL/bin/inv"`, `"$HL/bin/forensics"`. Mutations: `"$HL/bin/guard"` ONLY.

## Inventory & TLS
- Inventory lives in `inventory/{fleet.yaml,groups.yaml}` (the operator's REAL
  fleet). `HOMELAB_INVENTORY_DIR` overrides that directory — the test suite
  points it at `tests/fixtures/` so tests never couple to the live inventory.
  A `proxmox-host` entry's `id` MUST equal the real PVE node name (API paths are
  `/nodes/<id>/...`).
- **Per-host CA.** A homelab Proxmox uses a self-signed cluster CA, so system
  trust alone fails verification. Set `access.api.ca_path` (path; absolute, `~`,
  or repo-root-relative) to that node's `/etc/pve/pve-root-ca.pem`; `bin/pve`
  passes it as curl `--cacert` so TLS verification stays **ON** (never `-k`).
  Independent nodes each have a DISTINCT CA — one `ca_path` per host. A declared
  but unreadable `ca_path` fails closed.

## Credentials — delegated to bitwarden-ops (homelab-ops never touches `bw`)
homelab-ops holds only `bw://` references (in inventory). Resolution is delegated
to the **bitwarden-ops** skill:

1. Ensure the vault is unlocked: invoke the bitwarden-ops skill and run its
   `bw-unlock` (the session then persists for subsequent calls). The user types
   the master password — never Claude.
2. For any mutating op, ask guard which refs it needs, then wrap the real run
   with bitwarden-ops `bw-exec` so the secret is injected into the env and never
   enters Claude's context, argv, disk, or logs:

```sh
export HOMELAB_SESSION_ID="sess-$(date -u +%Y%m%dT%H%M%SZ)"
plan="$("$HL/bin/guard" --plan <action> <target>)"   # e.g. PVE_TOKEN=bw://...
bw-exec "$plan" -- "$HL/bin/guard" <action> <target> [--approve]
```

`guard --plan` is read-only (inventory only, no secret access); empty output ⇒
a safe op that needs no credential. A non-safe op whose transport credential is
absent refuses to start (exit 3) and prints the exact `bw-exec` line to use.

> Notes:
> - `--plan` emits a single `NAME=bw://ref` line under the current transport
>   model, so the quoted `bw-exec "$plan"` form above is correct — keep it quoted.
> - Empty `--plan` for a non-safe op that still exits 3 ⇒ the target is an orphan
>   guest with no owning Proxmox host / `token_ref` in inventory. Place it under a
>   host (an inventory data fix, not a tool issue).

## When to use
- "What's on the fleet / status / metrics?" → `"$HL/bin/inv" list|get|resolve <id>`, `"$HL/bin/guard" status <id>`
- "Start/stop/restart/snapshot X" → `"$HL/bin/guard" <verb> <id>` (prod ⇒ needs `--approve`)
- "Destroy/delete/storage/network change" → `"$HL/bin/guard" <verb> <id>` → show the DRY-RUN/impact → re-run with `--approve`
- "Provision a VM" → `"$HL/bin/guard" provision <pve-host-id> -- --from-template <vmid> --new-vmid <vmid>`
- "What happened / why did X fail?" → `"$HL/bin/forensics" {session|target|timeline} <id>`, `"$HL/bin/forensics" runlog <session>/<op>.log`

Not for: non-Proxmox virt, Proxmox cluster/HA/migration (targets are independent hosts), or IaC (Phase 2, not yet).

## Hard rules (non-negotiable — destructive mistakes must be hard, every action reconstructable)
1. **No guard bypass.** Every state change runs as `"$HL/bin/guard" <action> <target> [--approve]`. `bin/pve` and `bin/ssh-run` are read/transport layers — never invoke them to mutate state.
2. **Credential injected via bitwarden-ops for any change.** A non-safe op whose transport credential (`PVE_TOKEN`/`HL_SSH_KEY`) is absent refuses (exit 3). Resolve refs with `guard --plan` and wrap the run in bitwarden-ops `bw-exec`; never see, store, or handle the master password, and never reimplement `bw` here.
3. **deny-by-default.** Any action not in guard's grade table is treated as destructive. Don't add ad-hoc actions to dodge this — extend the grade table deliberately if genuinely needed.
4. **Destructive needs eyes.** destructive (and prod-caution) ops print a DRY-RUN + impact and exit 10. Show that to the user, get explicit approval, THEN re-run with `--approve`. A `critical`-tagged target escalates one grade — **but read-only safe ops (`status`/`metrics`/`get`/`list`/`inventory`) are NEVER escalated**: observability of critical hosts must not require `--approve` (the rule makes destructive mistakes hard, not looking impossible).
5. **No log gaps.** `logs/audit.jsonl` is append-only; full per-op output is in `logs/runs/<session>/<op>.log` (secrets masked). Never edit, truncate, or skip them. Operational state is local to the operator and gitignored — back it up out-of-band if you need tamper-evidence.
6. **Credentials are references, resolved by bitwarden-ops.** Inventory holds `bw://` refs only. Resolution is delegated to the bitwarden-ops skill via `bw-exec` (env injection, in-memory); homelab-ops defines no `bw` behavior. Never write a secret to disk or echo it unmasked.
7. **Provisioning is Phase 1.** Use `"$HL/bin/guard" provision` only. No Terraform/Ansible until Phase 2; the `guard provision` interface stays stable when the backend is swapped.

## Forensics
After any incident: `"$HL/bin/forensics" timeline <session-id>` reconstructs the ordered op sequence (surfacing `exit=` codes); `"$HL/bin/forensics" session|target <id>` filters records; `"$HL/bin/forensics" runlog <session>/<op>.log` shows the masked full output incl. the pre-op state snapshot. Each audit record carries the resolved inventory snapshot, grade, approver, dry-run hash, and exit code.
