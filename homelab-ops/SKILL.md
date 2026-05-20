---
name: homelab-ops
description: Use when the user wants to inspect or operate their homelab fleet (independent Proxmox hosts, their VMs/LXC, standalone appliances like Victoria Metrics / NAS, and k8s clusters running on the VMs) — list/status/metrics, start/stop/restart/snapshot, destroy, backup, disk-attach/detach, disk-grow, PDM remote-migrate, kubectl against k8s-cluster targets, or Phase-1 provisioning (clone). Read inventory with this skill's `bin/inv`; perform ANY state change ONLY through `bin/guard`, which grades the action (safe/caution/destructive), gates on the presence of the injected transport credential, dry-runs + requires explicit approval for destructive/prod ops, and forensically logs every operation. Credentials are `bw://` references; resolution is delegated to the bitwarden-ops skill via `bw-exec`, never reimplemented here and never on disk.
---

# homelab-ops

Fleet ops toolkit for a heterogeneous homelab. Core design tension: **strong guard on destructive actions ↔ enough authority for day-2 automation**, with every operation forensically reconstructable. Deps: `bash`, `jq`, `python3`+PyYAML, `curl`, `ssh`/`ssh-agent`, `sshpass` (password 인증 호스트에서만). Credential resolution is delegated to the **bitwarden-ops** skill (`bw-exec`); homelab-ops itself never calls `bw`.

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
- **Inventory 발견 순서**(첫 매치 승, 매치=그 디렉터리에 `fleet.yaml`):
  1. `$HOMELAB_INVENTORY_DIR` (명시 override; 테스트가 `tests/fixtures/` 지정)
  2. `${XDG_CONFIG_HOME:-~/.config}/homelab-ops/` ← **운영자-로컬 정식 위치**
  3. `$REPO_ROOT/inventory/` (레거시·예시·테스트 호환)
  **First-time setup:** `inventory/{fleet,groups}.example.yaml` 를
  `~/.config/homelab-ops/{fleet,groups}.yaml` 로 복사해 편집(레포 밖이라
  백업 용이; repo `inventory/` 도 여전히 동작). 셋 다 없으면 `bin/inv` 가
  세 후보 경로를 출력하고 종료한다. A `proxmox-host` entry's `id` MUST
  equal the real PVE node name (API paths are `/nodes/<id>/...`).
- **PDM 엔트리.** `remote-migrate` 는 인벤토리에 `kind: pdm` 엔트리(정확히 1개:
  `address`[:port], `access.api.token_ref`→`PDM_TOKEN`, `ca_path`, 선택
  `base_path`/`task_status_path`/`migrate_path`)가 필요하다. `bin/pdm` 가 단일
  출처로 해석.
- **host-ssh transport.** `disk-attach`/`disk-detach`/`disk-grow` 는 게스트가
  target 이지만 **owner Proxmox 노드에 root SSH** 로 실행(`qm set`/`qm guest
  exec`). 자격은 owner_host 엔트리의 `access.ssh`. disk-attach 는 게스트
  엔트리 `disks[].serial` opt-in 선언 필요.
- **guest-ssh transport.** `service`/`logs`/`pkg-update`/`reboot`/`exec --via guest`
  는 **게스트 엔트리의 `access.ssh`** (`key_ref` 또는 `pass_ref`) 자격으로 직접
  접속. `pkg-install` 과 동일 패턴.
- **k8s-cluster + kube transport.** `kind: k8s-cluster` 엔트리는 VM 위에 올린
  논리 클러스터(`endpoint`, `access.kubeconfig.ref: bw://kubeconfig-<id>/notes`,
  `members.control_plane[]`, `members.workers[]`). `kubectl` verb 는 이 엔트리만
  타깃으로 받고 `bin/kube` 가 자격을 0600 ephemeral tmpfile 로 변환해 `kubectl`
  을 호출(`KUBECONFIG` override; 종료 시 tmpfile 제거; `--kubeconfig` 인자 거부).
  자격은 `HL_KUBECONFIG` env (kubeconfig YAML 내용). 분류는 `bin/_classify kube`
  가 첫 토큰(get/apply/...)으로 동적 결정.
- **Per-host CA.** A homelab Proxmox serves a self-signed cert from its built-in
  CA (Proxmox names it "PVE Cluster Manager CA" even on a standalone, non-
  clustered node), so system trust alone fails verification. Set
  `access.api.ca_path` (path; absolute, `~`, or repo-root-relative) to that
  node's `/etc/pve/pve-root-ca.pem`; `bin/pve` passes it as curl `--cacert` so
  TLS verification stays **ON** (never `-k`). Independent nodes each have a
  DISTINCT CA — one `ca_path` per host. A declared but unreadable `ca_path`
  fails closed.

## Credentials — delegated to bitwarden-ops (homelab-ops never touches `bw`)
homelab-ops holds only `bw://` references (in inventory: `token_ref` for PVE/PDM
API tokens, `key_ref`/`pass_ref` for SSH, `kubeconfig.ref` for k8s clusters).
Resolution is delegated to the **bitwarden-ops** skill:

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
> - SSH **키** 호스트의 `access.ssh.key_ref` 는 `bw://ssh-<id>/notes` 규약
>   (키는 vault item notes 에 저장; `bw-put ... --type note --from-file` 로
>   등록). `guard --plan` 은 key_ref 를 verbatim 으로 `HL_SSH_KEY` 에 싣는다.
> - SSH **패스워드** 호스트는 `access.ssh.auth: password` + `pass_ref:
>   "bw://ssh-<id>-pass"` (single-line; `bw-put` tty 또는 `--from-file` 로 등록).
>   `guard --plan` 은 `HL_SSH_PASS` 를, `ssh-run` 은 `sshpass -e` 를 쓴다.
>   (StrictHostKeyChecking=yes 유지 — 패스워드 호스트도 첫 접속 전 host key 가
>   known_hosts 에 미리 등록돼 있어야 한다.)

## When to use
- "What's on the fleet / status / metrics?" → `"$HL/bin/inv" list|get|resolve <id>`, `"$HL/bin/guard" status <id>`
- "Start/stop/restart/snapshot X" → `"$HL/bin/guard" <verb> <id>` (prod ⇒ needs `--approve`)
- "Back up X (vzdump)" → `"$HL/bin/guard" backup <id> -- <storage> [mode] [compress]` (caution; prod ⇒ `--approve`)
- "Destroy/delete X" → `"$HL/bin/guard" destroy <id>` (`delete` = `destroy` 별칭) → show the DRY-RUN/impact → re-run with `--approve`
- storage/network 변경은 **미지원**(Phase 2 후보). 임의 verb 를 던지면 deny-by-default 가 destructive 로 거부한다.
  - 예외 1: `disk-grow --to` 의 `qm resize` (단일 디스크 증가만).
  - 예외 2: `exec` (모든 `--via`; 분류기 가드 하 범용 — 아래 항목 참조).
- "물리 디스크 attach/detach (by-id)" → `"$HL/bin/guard" disk-attach <guest> -- --by-id /dev/disk/by-id/<id> [--index N]` (destructive; by-id 강제·serial opt-in)
- "게스트 디스크 확장(내부 LVM/FS 만)" → `"$HL/bin/guard" disk-grow <guest> [-- --lv <vg/lv>]` (destructive; qm guest exec — PVE 가상디스크 사전 확장 전제)
- "PVE 가상디스크 + 게스트 내부 확장(한 번에)" → `"$HL/bin/guard" disk-grow <guest> -- --to <NG|NT> [--disk scsiN]` (destructive; owner 노드에서 `qm resize` 선행 후 게스트 내부 시퀀스; 증가만, 목표 ≤ 현재 거부)
- "게스트 서비스 제어" → `"$HL/bin/guard" service <id> -- <start|stop|restart|status> <unit>` (caution; guest ssh; 서브커맨드 4종 + unit charset 가드)
- "게스트 로그 조회" → `"$HL/bin/guard" logs <id> -- --unit <unit> [-n N]` 또는 `-- --file <abs-path> [-n N]` (caution; 읽기 전용; unit/path charset 가드)
- "게스트 패키지 업데이트" → `"$HL/bin/guard" pkg-update <id>` (caution; guest ssh; apt/dnf 자동탐지)
- "게스트 OS 재부팅" → `"$HL/bin/guard" reboot <id>` (caution; guest ssh; `systemctl reboot` — `restart`(VM 재시작)와 구분)
- "k8s 클러스터 조회/조작 (kubectl)" → `"$HL/bin/guard" kubectl <cluster-id> -- <kubectl-args...>` (target 은 `kind:k8s-cluster` 만; 자격은 `HL_KUBECONFIG`; 등급은 동적 분류기 `bin/_classify kube` 가 결정). 분류 규칙 요약:
  - 읽기 전용 (`get describe logs top cluster-info version explain api-resources api-versions config wait diff auth events`) → **caution**
  - 변이/대화형 (`apply create delete replace patch edit scale rollout cordon drain uncordon taint annotate label set expose autoscale run exec cp port-forward proxy attach debug`) → **destructive** (`--approve` 필요)
  - 미지 서브커맨드 → destructive `fallback-deny`
  - `--kubeconfig` 인자 주입은 `bin/kube` 가 거부 (자격은 bw 단일 출처)
- "임의 명령 (동적 등급)" → `"$HL/bin/guard" exec <id> -- --via <guest|node|pve> <cmd...>` (pve: `--via pve --method GET|POST|PUT|DELETE --path /...`). 등급은 분류기 `bin/_classify` 가 동적 결정 (`--grade-override destructive` 는 상향만; destructive 시 `--approve` 필요). 분류 규칙 요약:
  - 읽기 전용 allowlist (`cat ls journalctl systemctl status qm config` 등) → **caution**
  - `ip ss dmesg journalctl` 은 **읽기 전용 형태만** caution — 변이 플래그/서브커맨드 (`ip link set`, `dmesg --clear`, `journalctl --vacuum-*`, `ss -K` 등) → destructive
  - 래퍼 바이너리 (`env sudo su xargs nice timeout nohup stdbuf setsid`) → destructive (`wrapper` rule; allowlist 우회 차단)
  - 셸 메타문자 / `sh|bash -c` → destructive (`metachar` rule)
  - pve transport: `GET` → caution, 그 외 method → destructive
  - 그 외(미지 바이너리, 매치 없음) → destructive (`fallback-deny`)
- "노드 간 이전 (PDM)" → `"$HL/bin/guard" remote-migrate <guest> -- --to <node> [--target-storage <map>] [--online]` (destructive; PDM 경유)
- "Provision a VM" → `"$HL/bin/guard" provision <pve-host-id> -- --from-template <vmid> --new-vmid <vmid>`
- "What happened / why did X fail?" → `"$HL/bin/forensics" {session|target|timeline} <id>`, `"$HL/bin/forensics" runlog <session>/<op>.log`
- PVE 변경(start/stop/restart/snapshot/destroy/backup/provision)은 task UPID
  완료까지 폴링되어 감사 `exit`/`task_exitstatus` 가 **실제 결과**를 반영한다
  (타임아웃 시 exit 75 + `task_upid` 보존). 기본 한도 `HOMELAB_TASK_TIMEOUT`
  600s. `remote-migrate`(PDM)도 `pdm_wait_task` 로 PDM task 를 동일하게
  폴링·감사하며, 인터럽트 시 `_finish_trap` 이 PVE/PDM task id 를 복구한다.
  `disk-attach`/`disk-detach`/`disk-grow`(host-ssh)는 노드에서 동기 실행
  (`qm set`/`qm guest exec`)이라 task 폴링이 아니라 명령 exit 를 감사한다.

Not for: non-Proxmox virt, intra-cluster HA·live-migration·로컬 클러스터 migration, or IaC (Phase 2, not yet). (PDM 경유 노드 간 `remote-migrate` 는 지원 — 독립 노드 대상.) k8s 는 클러스터 단위 `kubectl` 만 지원 — 클러스터 자체의 lifecycle(생성/삭제/노드 추가)은 범위 밖.

## Hard rules (non-negotiable — destructive mistakes must be hard, every action reconstructable)
1. **No guard bypass.** Every state change runs as `"$HL/bin/guard" <action> <target> [--approve]`. `bin/pve` and `bin/ssh-run` are read/transport layers — never invoke them to mutate state.
2. **Credential injected via bitwarden-ops for any change.** A non-safe op whose transport credential (`PVE_TOKEN`/`PDM_TOKEN`/`HL_SSH_KEY`/`HL_SSH_PASS`/`HL_KUBECONFIG`) is absent refuses (exit 3). Resolve refs with `guard --plan` and wrap the run in bitwarden-ops `bw-exec`; never see, store, or handle the master password, and never reimplement `bw` here.
3. **deny-by-default.** Any action not in guard's grade table is treated as destructive. Don't add ad-hoc actions to dodge this — extend the grade table deliberately if genuinely needed.
4. **Destructive needs eyes.** destructive (and prod-caution) ops print a DRY-RUN + impact and exit 10. Show that to the user, get explicit approval, THEN re-run with `--approve`. A `critical`-tagged target escalates one grade — **but read-only safe ops (`status`/`metrics`/`get`/`list`/`inventory`) are NEVER escalated**: observability of critical hosts must not require `--approve` (the rule makes destructive mistakes hard, not looking impossible).
5. **No log gaps.** `logs/audit.jsonl` is append-only; full per-op output is in `logs/runs/<session>/<op>.log` (secrets masked). Never edit, truncate, or skip them. Operational state is local to the operator and gitignored — back it up out-of-band if you need tamper-evidence.
6. **Credentials are references, resolved by bitwarden-ops.** Inventory holds `bw://` refs only. Resolution is delegated to the bitwarden-ops skill via `bw-exec` (env injection, in-memory); homelab-ops defines no `bw` behavior. Never write a secret to disk or echo it unmasked.
7. **Provisioning is Phase 1.** Use `"$HL/bin/guard" provision` only. No Terraform/Ansible until Phase 2; the `guard provision` interface stays stable when the backend is swapped.

## Forensics
After any incident: `"$HL/bin/forensics" timeline <session-id>` reconstructs the ordered op sequence (surfacing `exit=` codes); `"$HL/bin/forensics" session|target <id>` filters records; `"$HL/bin/forensics" runlog <session>/<op>.log` shows the masked full output incl. the pre-op state snapshot. Each audit record carries the resolved inventory snapshot, grade, approver, dry-run hash, and exit code.
