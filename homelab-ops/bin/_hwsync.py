#!/usr/bin/env python3
"""
_hwsync.py — render a paste-ready YAML `hardware:` fragment from a JSON
envelope produced by the _hwsync bash dispatcher. Read from stdin.

Envelope shape varies per kind:
  proxmox-host: {kind, target, status, storage, network, pci}
  vm | lxc    : {kind, target, vmid, owner_host, config}
  appliance   : {kind, target, cpuinfo, meminfo}   (raw /proc text)

Output: a single multi-line YAML block to stdout, prefixed by a comment
header. `resource_type:` is always set (physical | virtual).
"""
import json
import re
import sys
from datetime import datetime, timezone

try:
    import yaml
except ImportError:
    sys.stderr.write("_hwsync.py: PyYAML required (pip install pyyaml)\n")
    sys.exit(1)


def bytes_to_gib(b):
    if not b:
        return 0
    return round(b / 1073741824, 1)


def mb_to_gib(m):
    if not m:
        return 0
    return round(m / 1024, 1)


def parse_disk_spec(spec):
    """PVE disk string: 'storage:vol-100-disk-0,size=32G,backup=0,...'.
    Return (storage, size_gib). size token may end with G, T, M, K."""
    storage = None
    size_gib = None
    if not isinstance(spec, str):
        return storage, size_gib
    head, *rest = spec.split(",")
    if ":" in head:
        storage = head.split(":", 1)[0]
    for kv in rest:
        if kv.startswith("size="):
            v = kv[5:].strip()
            m = re.match(r"^(\d+(?:\.\d+)?)([KMGT])?$", v, re.IGNORECASE)
            if m:
                n = float(m.group(1))
                u = (m.group(2) or "G").upper()
                if u == "K":
                    size_gib = round(n / (1024 * 1024), 3)
                elif u == "M":
                    size_gib = round(n / 1024, 3)
                elif u == "G":
                    size_gib = round(n, 3)
                elif u == "T":
                    size_gib = round(n * 1024, 1)
    return storage, size_gib


def parse_net_spec(spec):
    """PVE net string: 'virtio=AA:BB:..,bridge=vmbr0,firewall=1,...'."""
    model = None
    bridge = None
    if not isinstance(spec, str):
        return model, bridge
    for kv in spec.split(","):
        if "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        if k in ("virtio", "e1000", "rtl8139", "vmxnet3"):
            model = k
        elif k == "bridge":
            bridge = v
    return model, bridge


def hwblock_proxmox_host(env):
    data = (env.get("status") or {}).get("data") or {}
    cpuinfo = data.get("cpuinfo") or {}
    memory = data.get("memory") or {}
    storage_list = ((env.get("storage") or {}).get("data") or [])
    network_list = ((env.get("network") or {}).get("data") or [])

    storages = []
    for s in storage_list:
        total = s.get("total") or 0
        item = {"name": s.get("storage"), "type": s.get("type")}
        if total >= 1099511627776:  # >= 1 TiB → use size_tib
            item["size_tib"] = round(total / 1099511627776, 2)
        elif total > 0:
            item["size_gib"] = bytes_to_gib(total)
        storages.append(item)

    nics = [{"name": n.get("iface")} for n in network_list if n.get("iface")]

    # passthrough[]: intentionally NOT auto-populated. /hardware/pci returns
    # every PCI device on the node (chipset, USB controllers, NICs, GPUs, ...)
    # — that's a hardware inventory, not a passthrough list. Operators add
    # entries here for devices actually passed through to a VM (with bound_to:
    # <guest-id>), and `verify-specs` confirms each id exists in /hardware/pci.
    return {
        "resource_type": "physical",
        "cpu": {
            "model": cpuinfo.get("model"),
            "sockets": cpuinfo.get("sockets"),
            "cores": cpuinfo.get("cores"),
            "threads": cpuinfo.get("cpus"),
        },
        "memory": {
            "total_gib": bytes_to_gib(memory.get("total")),
            # reserved_gib is operator policy — not API-derivable.
            "reserved_gib": 0,
        },
        "storages": storages,
        "nics": nics,
    }


def hwblock_vm(env):
    cfg = (env.get("config") or {}).get("data") or {}
    sockets = int(cfg.get("sockets") or 1)
    cores = int(cfg.get("cores") or 1)
    vcpus = cfg.get("vcpus")
    memory_mb = int(cfg.get("memory") or 512)

    disks = []
    nets = []
    passthrough = []
    for k, v in cfg.items():
        if re.match(r"^(scsi|virtio|ide|sata)\d+$", k):
            storage, size = parse_disk_spec(v)
            d = {"slot": k}
            if storage:
                d["storage"] = storage
            if size is not None:
                d["size_gib"] = size
            disks.append(d)
        elif re.match(r"^net\d+$", k):
            model, bridge = parse_net_spec(v)
            n = {"slot": k}
            if model:
                n["model"] = model
            if bridge:
                n["bridge"] = bridge
            nets.append(n)
        elif re.match(r"^hostpci\d+$", k):
            passthrough.append({"slot": k, "spec": str(v).split(",")[0]})

    block = {
        "resource_type": "virtual",
        "owner_host": env.get("owner_host"),
        "vmid": env.get("vmid"),
        "cpu": {
            "sockets": sockets,
            "cores": cores,
            "threads": int(vcpus) if vcpus else sockets * cores,
        },
        "memory": {
            "total_gib": mb_to_gib(memory_mb),
        },
    }
    if disks:
        block["disks"] = disks
    if nets:
        block["net_interfaces"] = nets
    if passthrough:
        block["passthrough"] = passthrough
    if cfg.get("ostype"):
        block["ostype"] = cfg["ostype"]
    return block


def hwblock_lxc(env):
    cfg = (env.get("config") or {}).get("data") or {}
    cores = int(cfg.get("cores") or 0) or None
    memory_mb = int(cfg.get("memory") or 512)
    swap_mb = int(cfg.get("swap") or 0)

    mounts = []
    if cfg.get("rootfs"):
        storage, size = parse_disk_spec(cfg["rootfs"])
        m = {"slot": "rootfs"}
        if storage:
            m["storage"] = storage
        if size is not None:
            m["size_gib"] = size
        mounts.append(m)
    nets = []
    for k, v in cfg.items():
        if re.match(r"^mp\d+$", k):
            storage, size = parse_disk_spec(v)
            mp = None
            for kv in str(v).split(","):
                if kv.startswith("mp="):
                    mp = kv[3:]
            m = {"slot": k}
            if storage:
                m["storage"] = storage
            if mp:
                m["mountpoint"] = mp
            if size is not None:
                m["size_gib"] = size
            mounts.append(m)
        elif re.match(r"^net\d+$", k):
            model, bridge = parse_net_spec(v)
            n = {"slot": k}
            if model:
                n["model"] = model
            if bridge:
                n["bridge"] = bridge
            nets.append(n)

    block = {
        "resource_type": "virtual",
        "owner_host": env.get("owner_host"),
        "vmid": env.get("vmid"),
        "cpu": {"cores": cores} if cores else {},
        "memory": {
            "total_gib": mb_to_gib(memory_mb),
            "swap_gib": mb_to_gib(swap_mb),
        },
    }
    if mounts:
        block["mounts"] = mounts
    if nets:
        block["net_interfaces"] = nets
    if cfg.get("ostype"):
        block["ostype"] = cfg["ostype"]
    if cfg.get("hostname"):
        block["hostname"] = cfg["hostname"]
    return block


def parse_proc_cpuinfo(text):
    model = None
    sockets = set()
    cores_per_socket = {}
    processors = 0
    cur_phys = None
    cur_core = None
    for line in text.splitlines():
        if not line.strip():
            cur_phys = None
            cur_core = None
            continue
        if ":" not in line:
            continue
        k, v = [x.strip() for x in line.split(":", 1)]
        if k == "model name" and model is None:
            model = v
        elif k == "processor":
            processors += 1
        elif k == "physical id":
            cur_phys = v
            sockets.add(v)
        elif k == "core id":
            cur_core = v
            if cur_phys is not None:
                cores_per_socket.setdefault(cur_phys, set()).add(cur_core)
    total_cores = sum(len(c) for c in cores_per_socket.values()) or None
    return {
        "model": model,
        "sockets": len(sockets) if sockets else None,
        "cores": total_cores,
        "threads": processors or None,
    }


def parse_proc_meminfo(text):
    for line in text.splitlines():
        if line.startswith("MemTotal:"):
            m = re.match(r"MemTotal:\s+(\d+)\s+kB", line)
            if m:
                kb = int(m.group(1))
                return round(kb / 1048576, 1)  # kB → GiB
    return None


def hwblock_appliance(env):
    cpu = parse_proc_cpuinfo(env.get("cpuinfo") or "")
    mem_gib = parse_proc_meminfo(env.get("meminfo") or "")
    return {
        "resource_type": "physical",
        "cpu": cpu,
        "memory": {
            "total_gib": mem_gib,
            "reserved_gib": 0,
        },
        # storages/nics/passthrough left for the operator to fill in — too
        # variable across appliances (NAS, generic linux, …) to autodetect
        # without running disk/lspci probes that may not exist on busybox.
    }


def main():
    env = json.load(sys.stdin)
    kind = env.get("kind")
    if kind == "proxmox-host":
        body = hwblock_proxmox_host(env)
    elif kind == "vm":
        body = hwblock_vm(env)
    elif kind == "lxc":
        body = hwblock_lxc(env)
    elif kind == "appliance":
        body = hwblock_appliance(env)
    else:
        sys.stderr.write(f"_hwsync.py: unsupported kind={kind}\n")
        sys.exit(2)

    # Drop keys whose value is None or [] so the YAML output stays clean.
    def prune(x):
        if isinstance(x, dict):
            return {k: prune(v) for k, v in x.items() if v not in (None, [], {})}
        if isinstance(x, list):
            return [prune(i) for i in x]
        return x

    body = prune(body)
    out = {"hardware": body}

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    header_kind = "physical" if body.get("resource_type") == "physical" else "virtual"
    print(f"# hwsync {env.get('target')} ({kind} → {header_kind}) — generated {ts}")
    print(f"# Paste under this entry's existing keys (same indentation).")
    if kind in ("vm", "lxc"):
        print(f"# NOTE: PVE config IS the source of truth for {kind} allocations.")
        print(f"#       Pasting into inventory creates drift — keep this informational.")
    if kind == "proxmox-host":
        print(f"# NOTE: passthrough[] left empty by design — /hardware/pci returns")
        print(f"#       every PCI device on the node (chipset, USB, NICs, ...). Add")
        print(f"#       entries for devices actually passed through to a guest, e.g.")
        print(f"#       passthrough: [{{kind: gpu, id: \"10de:2206\", bound_to: workspace-02}}]")
    if kind == "appliance":
        print(f"# NOTE: storages/nics/passthrough left for the operator — too variable")
        print(f"#       across appliances (NAS, generic linux) to autodetect safely.")
    sys.stdout.write(yaml.dump(out, sort_keys=False, default_flow_style=None, width=120))


if __name__ == "__main__":
    main()
