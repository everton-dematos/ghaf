# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import argparse
import contextlib
import datetime
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

FIELDS = (
    "MESSAGE,_BOOT_ID,_GHAF_SOURCE,_COMM,SYSLOG_IDENTIFIER,_SYSTEMD_USER_UNIT,"
    "_SYSTEMD_UNIT,USER_UNIT,UNIT,_TRANSPORT"
)
SERVICE_FIELDS = (
    "UNIT",
    "USER_UNIT",
    "_SYSTEMD_UNIT",
    "_SYSTEMD_USER_UNIT",
    "SYSLOG_IDENTIFIER",
    "_COMM",
)


def field(entry, name):
    value = entry.get(name, "")
    if isinstance(value, list) and all(isinstance(v, int) for v in value):
        return bytes(value).decode("utf-8", errors="replace")
    return value if isinstance(value, str) else ""


def journal(directory, *matches):
    command = [
        "journalctl",
        "--boot=all",
        "--no-pager",
        "--output=json",
        "--all",
        f"--output-fields={FIELDS}",
    ]
    if directory:
        command.append(f"--directory={directory}")
    with subprocess.Popen(command + list(matches), stdout=subprocess.PIPE) as process:
        try:
            while line := process.stdout.readline(8 * 1024 * 1024 + 1):
                if not line.endswith(b"\n"):
                    raise ValueError("journal record exceeds the 8 MiB input limit")
                yield json.loads(line)
            if process.wait():
                raise RuntimeError("Could not read startup journal records")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()


def startup_entry(entry, host, local):
    timestamp = int(entry["__REALTIME_TIMESTAMP"])
    original = datetime.datetime.fromtimestamp(
        timestamp // 1_000_000, datetime.timezone.utc
    ).strftime("%Y-%m-%dT%H:%M:%S")
    original += f".{timestamp % 1_000_000:06d}Z"
    return {
        "message": f"[original_timestamp={original}] {field(entry, 'MESSAGE')}",
        "host": host,
        "service_name": next(
            (field(entry, name) for name in SERVICE_FIELDS if field(entry, name)), ""
        ),
        "transport": field(entry, "_TRANSPORT"),
        "job": "loki.source.journal." + ("journal" if local else "authenticated"),
    }


@contextlib.contextmanager
def publish(path):
    temporary = path.with_suffix(".tmp")
    try:
        with temporary.open("wb") as stream:
            yield stream
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def import_startup_logs(config, directory):
    output = directory / "logs"
    output.mkdir(parents=True, exist_ok=True)
    checkpoint = directory / "completed.json"
    completed = (
        set(json.loads(checkpoint.read_text())) if checkpoint.exists() else set()
    )
    for path in output.glob("*.jsonl"):
        if path.stat().st_mtime < time.time() - config["retention_seconds"]:
            path.unlink()
    used = sum(path.stat().st_size for path in output.glob("*.jsonl"))
    sources = [None] + ([config["remote_journal"]] if config["remote_journal"] else [])
    for source in sources:
        for marker in journal(source, "_SYSTEMD_UNIT=ghaf-wait-time-sync.service"):
            if not field(marker, "MESSAGE").startswith(
                "Clock synchronised; realtime is "
            ):
                continue
            host = config["host"] if source is None else field(marker, "_GHAF_SOURCE")
            if source is not None and host not in config["sources"]:
                continue
            boot = field(marker, "_BOOT_ID")
            identity = hashlib.sha256(f"{host}:{boot}".encode()).hexdigest()
            if not boot or identity in completed:
                continue
            path = output / f"{identity}.jsonl"
            if not path.exists():
                matches = [f"_BOOT_ID={boot}"]
                if source is not None:
                    matches.append(f"_GHAF_SOURCE={host}")
                boundary = int(marker["__MONOTONIC_TIMESTAMP"])
                # Records already too old at the clock gate cannot overlap Alloy's 15m path.
                cutoff = int(marker["__REALTIME_TIMESTAMP"]) - 900_000_000

                with publish(path) as stream:
                    for entry in journal(source, *matches):
                        if (
                            int(entry["__MONOTONIC_TIMESTAMP"]) >= boundary
                            or int(entry["__REALTIME_TIMESTAMP"]) >= cutoff
                        ):
                            continue
                        line = (
                            json.dumps(startup_entry(entry, host, source is None))
                            + "\n"
                        ).encode()
                        if used + stream.tell() + len(line) > config["max_bytes"]:
                            raise BufferError(
                                "Startup log exports fill the disk budget; retrying later"
                            )
                        stream.write(line)

                used += path.stat().st_size
            completed.add(identity)
            with publish(checkpoint) as stream:
                stream.write(json.dumps(sorted(completed)).encode())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    import_startup_logs(
        json.loads(args.config.read_text()), Path(os.environ["STATE_DIRECTORY"])
    )


if __name__ == "__main__":
    main()
