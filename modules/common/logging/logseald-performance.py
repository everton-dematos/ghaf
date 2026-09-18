# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
import argparse
import csv
import math
import re
import subprocess
import tempfile
import time
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path

PROPERTIES = (
    "Id,ActiveState,SubState,MainPID,ControlGroup,InvocationID,NRestarts,"
    "CPUUsageNSec,MemoryCurrent,MemoryPeak,MemorySwapCurrent,MemorySwapPeak"
)
MEMORY_STAT = (
    "anon",
    "file",
    "file_mapped",
    "active_file",
    "inactive_file",
    "kernel",
    "slab",
    "slab_reclaimable",
    "slab_unreclaimable",
)
PROCESS_STAT = {
    "vmrss": "VmRSS",
    "rss_anon": "RssAnon",
    "rss_file": "RssFile",
    "rss_shmem": "RssShmem",
    "pss": "Pss",
    "pss_anon": "Pss_Anon",
    "pss_file": "Pss_File",
    "pss_shmem": "Pss_Shmem",
}
MEMORY_FIELDS = (
    [
        "memory_current",
        "memory_peak",
        "memory_swap_current",
        "memory_swap_peak",
        "cgroup_non_file",
    ]
    + [f"cgroup_{key}" for key in MEMORY_STAT]
    + [f"process_{key}" for key in PROCESS_STAT]
)
FIELDS = (
    [
        "timestamp",
        "elapsed_seconds",
        "node",
        "boot_id",
        "unit",
        "active_state",
        "sub_state",
        "main_pid",
        "cgroup_path",
        "invocation_id",
        "restarts",
        "sample_status",
    ]
    + [f"{key}_{suffix}" for key in MEMORY_FIELDS for suffix in ("bytes", "mib")]
    + ["cpu_usage_usec", "cpu_delta_usec", "cpu_interval_seconds", "cpu_percent"]
)


def boot_seconds():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def read_text(path):
    try:
        return path.read_text()
    except OSError:
        return ""


def number(value):
    try:
        result = int(value)
        return result if 0 <= result < (1 << 64) - 1 else None
    except (ValueError, TypeError):
        return None


def key_values(text):
    result = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            value = number(parts[1])
            if value is not None:
                result[parts[0].rstrip(":")] = value
    return result


def unit_properties(systemctl, units):
    try:
        result = subprocess.run(
            [systemctl, "show", "--no-pager", f"--property={PROPERTIES}", *units],
            capture_output=True,
            text=True,
            timeout=3,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    entries = {}
    for section in result.stdout.strip().split("\n\n"):
        properties = dict(
            line.split("=", 1) for line in section.splitlines() if "=" in line
        )
        if "Id" in properties:
            entries[properties["Id"]] = properties
    return entries


def process_start(path):
    fields = read_text(path / "stat").rpartition(")")[2].split()
    return fields[19] if len(fields) > 19 else None


def collect(properties, cgroup_root=Path("/sys/fs/cgroup"), proc_root=Path("/proc")):
    row = {
        "active_state": properties.get("ActiveState", ""),
        "sub_state": properties.get("SubState", ""),
        "main_pid": properties.get("MainPID", ""),
        "cgroup_path": properties.get("ControlGroup", ""),
        "invocation_id": properties.get("InvocationID", ""),
        "restarts": properties.get("NRestarts", ""),
    }
    issues = [] if properties else ["properties_unavailable"]
    for name, prop in (
        ("memory_current", "MemoryCurrent"),
        ("memory_peak", "MemoryPeak"),
        ("memory_swap_current", "MemorySwapCurrent"),
        ("memory_swap_peak", "MemorySwapPeak"),
    ):
        row[f"{name}_bytes"] = number(properties.get(prop))
    cpu = number(properties.get("CPUUsageNSec"))
    row["cpu_usage_usec"] = cpu // 1000 if cpu is not None else None
    identity = None
    group = row["cgroup_path"]
    if group and group != "/" and ".." not in Path(group).parts:
        path = cgroup_root / group.lstrip("/")
        try:
            identity = path.stat().st_ino
        except OSError:
            pass
        if identity is not None:
            for name in ("current", "peak", "swap.current", "swap.peak"):
                value = number(read_text(path / f"memory.{name}").strip())
                if value is not None:
                    row[f"memory_{name.replace('.', '_')}_bytes"] = value
            stats = key_values(read_text(path / "memory.stat"))
            for key in MEMORY_STAT:
                row[f"cgroup_{key}_bytes"] = stats.get(key)
            if row["memory_current_bytes"] is not None and "file" in stats:
                row["cgroup_non_file_bytes"] = max(
                    0, row["memory_current_bytes"] - stats["file"]
                )
        else:
            issues.append("cgroup_unavailable")
    else:
        issues.append("no_live_cgroup")
    pid = number(row["main_pid"])
    if pid:
        path = proc_root / str(pid)
        start = process_start(path)
        status = key_values(read_text(path / "status"))
        smaps = key_values(read_text(path / "smaps_rollup"))
        membership = read_text(path / "cgroup").splitlines()
        if start and start == process_start(path) and f"0::{group}" in membership:
            for name, key in PROCESS_STAT.items():
                value = (smaps if name.startswith("pss") else status).get(key)
                row[f"process_{name}_bytes"] = (
                    value * 1024 if value is not None else None
                )
            if not smaps:
                issues.append("pss_unavailable")
        else:
            issues.append("process_changed_or_unavailable")
    for key in MEMORY_FIELDS:
        value = row.get(f"{key}_bytes")
        row[f"{key}_mib"] = f"{value / 1048576:.3f}" if value is not None else None
    row["sample_status"] = ";".join(issues) or "ok"
    return row, (row["invocation_id"], identity)


def cpu_delta(row, identity, now, previous):
    usage = row.get("cpu_usage_usec")
    if previous is not None and usage is not None:
        old_identity, old_time, old_usage = previous
        if (
            identity == old_identity
            and old_usage is not None
            and usage >= old_usage
            and now > old_time
        ):
            delta = usage - old_usage
            row["cpu_delta_usec"] = delta
            row["cpu_interval_seconds"] = f"{now - old_time:.6f}"
            row["cpu_percent"] = f"{delta / ((now - old_time) * 10000):.3f}"
    return identity, now, usage


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--systemctl", required=True)
    parser.add_argument("--node", required=True)
    parser.add_argument("units", nargs="+")
    args = parser.parse_args()
    node = re.sub(r"[^a-zA-Z0-9_.-]", "_", args.node)
    if any(
        unit != "systemd-journald.service"
        and not re.fullmatch(r"logseald-[a-z-]+\.service", unit)
        for unit in args.units
    ):
        parser.error("only logseald services and systemd-journald.service are accepted")
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    directory = Path(
        tempfile.mkdtemp(prefix=f"logseald-performance-{node}-{boot}-", dir="/tmp")
    )
    directory.chmod(0o755)
    print(f"Resource samples: {directory}", flush=True)
    with ExitStack() as stack:
        writers = {}
        files = {}
        for unit in args.units:
            handle = stack.enter_context(
                (directory / f"{node}-{unit}.csv").open("x", newline="")
            )
            (directory / f"{node}-{unit}.csv").chmod(0o644)
            files[unit] = handle
            writers[unit] = csv.DictWriter(handle, fieldnames=FIELDS)
            writers[unit].writeheader()
            handle.flush()
        previous = {}
        while boot_seconds() < 600:
            properties = unit_properties(args.systemctl, args.units)
            for unit in args.units:
                row, identity = collect(properties.get(unit, {}))
                now = boot_seconds()
                row.update(
                    timestamp=datetime.now(timezone.utc).isoformat(),
                    elapsed_seconds=f"{now:.3f}",
                    node=args.node,
                    boot_id=boot,
                    unit=unit,
                )
                previous[unit] = cpu_delta(row, identity, now, previous.get(unit))
                writers[unit].writerow(row)
                files[unit].flush()
            now = boot_seconds()
            target = min(600, (math.floor(now / 10) + 1) * 10)
            time.sleep(max(0, target - now))


if __name__ == "__main__":
    main()
