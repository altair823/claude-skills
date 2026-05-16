---
name: homelab-ops
description: Use when the user wants to inspect or operate their homelab fleet (independent Proxmox hosts, their VMs/LXC, and standalone appliances like Victoria Metrics / NAS) — list/status/metrics, start/stop/restart/snapshot, destroy/storage/network changes, or Phase-1 provisioning (clone). Read inventory with this skill's `bin/inv`; perform ANY state change ONLY through `bin/guard`, which grades the action (safe/caution/destructive), gates on the Bitwarden session, dry-runs + requires explicit approval for destructive/prod ops, and forensically logs every operation. Credentials are `bw://` references resolved in-memory at call time, never on disk.
---

# homelab-ops

Fleet ops toolkit for a heterogeneous homelab. Core design tension: **strong guard on destructive actions ↔ enough authority for day-2 automation**, with every operation forensically reconstructable. Deps: `bash`, `jq`, `python3`+PyYAML, `curl`, `ssh`/`ssh-agent`, Bitwarden `bw` CLI.

All tools live in this skill's `bin/` (next to this SKILL.md). Invoke them by absolute path under this skill's directory, e.g. `<skill-dir>/bin/guard ...`. Read paths: `bin/inv`, `bin/forensics`. Mutations: `bin/guard` ONLY.

## Session setup (the user does this once per session)
```sh
export BW_SESSION="$(bw unlock --raw)"   # the user types the master password — never Claude
export HOMELAB_SESSION_ID="sess-$(date -u +%Y%m%dT%H%M%SZ)"
```
No `BW_SESSION` ⇒ every mutating command refuses to start (exit 3, "locked vault").

## When to use
- "What's on the fleet / status / metrics?" → `bin/inv list|get|resolve <id>`, `bin/guard status <id>`
- "Start/stop/restart/snapshot X" → `bin/guard <verb> <id>` (prod ⇒ needs `--approve`)
- "Destroy/delete/storage/network change" → `bin/guard <verb> <id>` → show the DRY-RUN/impact → re-run with `--approve`
- "Provision a VM" → `bin/guard provision <pve-host-id> -- --from-template <vmid> --new-vmid <vmid>`
- "What happened / why did X fail?" → `bin/forensics {session|target|timeline} <id>`, `bin/forensics runlog <session>/<op>.log`

Not for: non-Proxmox virt, Proxmox cluster/HA/migration (targets are independent hosts), or IaC (Phase 2, not yet).

## Hard rules (non-negotiable — destructive mistakes must be hard, every action reconstructable)
1. **No guard bypass.** Every state change runs as `bin/guard <action> <target> [--approve]`. `bin/pve` and `bin/ssh-run` are read/transport layers — never invoke them to mutate state.
2. **BW_SESSION required for any change.** Unset ⇒ guard refuses (exit 3, "locked vault"). Ask the user to `bw unlock`; never see, store, or handle the master password.
3. **deny-by-default.** Any action not in guard's grade table is treated as destructive. Don't add ad-hoc actions to dodge this — extend the grade table deliberately if genuinely needed.
4. **Destructive needs eyes.** destructive (and prod-caution) ops print a DRY-RUN + impact and exit 10. Show that to the user, get explicit approval, THEN re-run with `--approve`. A `critical`-tagged target escalates one grade.
5. **No log gaps.** `logs/audit.jsonl` is append-only; full per-op output is in `logs/runs/<session>/<op>.log` (secrets masked). Never edit, truncate, or skip them. Operational state is local to the operator and gitignored — back it up out-of-band if you need tamper-evidence.
6. **Credentials are references.** Inventory holds `bw://` refs only. Resolution is in-memory via `bin/bw-resolve`; never write a secret to disk or echo it unmasked.
7. **Provisioning is Phase 1.** Use `bin/guard provision` only. No Terraform/Ansible until Phase 2; the `guard provision` interface stays stable when the backend is swapped.

## Forensics
After any incident: `bin/forensics timeline <session-id>` reconstructs the ordered op sequence (surfacing `exit=` codes); `bin/forensics session|target <id>` filters records; `bin/forensics runlog <session>/<op>.log` shows the masked full output incl. the pre-op state snapshot. Each audit record carries the resolved inventory snapshot, grade, approver, dry-run hash, and exit code.
