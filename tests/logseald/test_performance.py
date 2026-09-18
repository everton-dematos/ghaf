# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
import csv
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = (
    Path(__file__).resolve().parents[2]
    / "modules/common/logging/logseald-performance.py"
)
spec = importlib.util.spec_from_file_location("performance", SCRIPT)
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class PerformanceTests(unittest.TestCase):
    def test_numbers(self):
        for value in (None, "[not set]", "infinity", "18446744073709551615", "-1"):
            self.assertIsNone(performance.number(value))
        self.assertEqual(performance.number("0"), 0)

    def test_cpu_intervals_and_restarts(self):
        identity = ("invocation", 42)
        row = {"cpu_usage_usec": 1000000}
        previous = performance.cpu_delta(row, identity, 10, None)
        self.assertNotIn("cpu_percent", row)
        row = {"cpu_usage_usec": 16000000}
        performance.cpu_delta(row, identity, 20, previous)
        self.assertEqual(row["cpu_delta_usec"], 15000000)
        self.assertEqual(row["cpu_percent"], "150.000")
        for changed, usage in (
            (("new", 42), 20000000),
            (("invocation", 43), 20000000),
            (identity, 0),
        ):
            row = {"cpu_usage_usec": usage}
            performance.cpu_delta(row, changed, 20, previous)
            self.assertNotIn("cpu_percent", row)

    def test_memory_and_main_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            group = root / "cgroup/system.slice/logseald-producer.service"
            group.mkdir(parents=True)
            (group / "memory.current").write_text("10485760")
            (group / "memory.peak").write_text("12582912")
            (group / "memory.stat").write_text(
                "anon 1048576\nfile 4194304\nkernel 524288\n"
            )
            process = root / "proc/123"
            process.mkdir(parents=True)
            (process / "stat").write_text(
                "123 (name with ) spaces) " + " ".join(["S"] + ["0"] * 18 + ["77"])
            )
            (process / "status").write_text("VmRSS: 2048 kB\nRssAnon: 512 kB\n")
            (process / "smaps_rollup").write_text(
                "Pss: 1024 kB\nPss_Anon: 512 kB\nPss_Shmem: 0 kB\n"
            )
            (process / "cgroup").write_text(
                "0::/system.slice/logseald-producer.service\n"
            )
            properties = {
                "ControlGroup": "/system.slice/logseald-producer.service",
                "MainPID": "123",
                "CPUUsageNSec": "1234000",
            }
            row, _ = performance.collect(properties, root / "cgroup", root / "proc")
            self.assertEqual(row["memory_current_mib"], "10.000")
            self.assertEqual(row["cgroup_non_file_mib"], "6.000")
            self.assertEqual(row["process_vmrss_mib"], "2.000")
            self.assertEqual(row["process_pss_mib"], "1.000")
            self.assertEqual(row["process_pss_shmem_bytes"], 0)
            self.assertEqual(row["cpu_usage_usec"], 1234)
            self.assertIsNone(row["memory_swap_peak_bytes"])
            (process / "cgroup").write_text("0::/different.service\n")
            row, _ = performance.collect(properties, root / "cgroup", root / "proc")
            self.assertNotIn("process_vmrss_bytes", row)
            self.assertIn("process_changed", row["sample_status"])

    def test_exited_service_retains_accounting(self):
        row, _ = performance.collect(
            {"MainPID": "0", "MemoryPeak": "4096", "CPUUsageNSec": "9000"}
        )
        self.assertEqual(row["memory_peak_bytes"], 4096)
        self.assertEqual(row["cpu_usage_usec"], 9)
        self.assertIsNone(row["memory_current_bytes"])
        self.assertNotIn("process_vmrss_bytes", row)

    def test_csv_and_boot_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            now = [0.25]

            def sleep(seconds):
                now[0] += seconds

            with (
                patch.object(performance.tempfile, "mkdtemp", return_value=directory),
                patch.object(performance, "boot_seconds", side_effect=lambda: now[0]),
                patch.object(performance.time, "sleep", side_effect=sleep),
                patch.object(performance, "unit_properties", return_value={}),
                patch(
                    "sys.argv",
                    [
                        str(SCRIPT),
                        "--systemctl",
                        "systemctl",
                        "--node",
                        "net-vm",
                        "logseald-producer.service",
                        "systemd-journald.service",
                    ],
                ),
            ):
                performance.main()
            with (
                Path(directory) / "net-vm-logseald-producer.service.csv"
            ).open() as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual(len(rows), 60)
            self.assertEqual(rows[0]["elapsed_seconds"], "0.250")
            self.assertEqual(rows[1]["elapsed_seconds"], "10.000")
            self.assertEqual(rows[-1]["elapsed_seconds"], "590.000")
            self.assertEqual(rows[0]["cpu_percent"], "")
            self.assertEqual(rows[0]["memory_current_bytes"], "")
            self.assertIn("properties_unavailable", rows[0]["sample_status"])
            self.assertEqual(now[0], 600)
            with (
                Path(directory) / "net-vm-systemd-journald.service.csv"
            ).open() as handle:
                journal_rows = list(csv.DictReader(handle))
            self.assertEqual(len(journal_rows), 60)
            self.assertEqual(journal_rows[-1]["elapsed_seconds"], "590.000")
            self.assertTrue(
                all(row["unit"] == "systemd-journald.service" for row in journal_rows)
            )
            self.assertEqual(Path(directory).stat().st_mode & 0o777, 0o755)
            self.assertEqual(
                (Path(directory) / "net-vm-logseald-producer.service.csv")
                .stat()
                .st_mode
                & 0o777,
                0o644,
            )

    def test_unrelated_and_unsafe_units_rejected(self):
        for unit in (
            "sshd.service",
            "systemd-journald.socket",
            "systemd-journald@other.service",
            "../logseald-producer.service",
        ):
            with (
                self.subTest(unit=unit),
                patch(
                    "sys.argv",
                    [str(SCRIPT), "--systemctl", "systemctl", "--node", "net-vm", unit],
                ),
                patch("sys.stderr", new_callable=io.StringIO),
                patch.object(performance.tempfile, "mkdtemp") as directory,
            ):
                with self.assertRaises(SystemExit) as error:
                    performance.main()
                self.assertEqual(error.exception.code, 2)
                directory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
