import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "collect_uat_evidence.py"
SPEC = importlib.util.spec_from_file_location("collect_uat_evidence", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
uat = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(uat)


class FakeRunner:
    def __init__(self, responses: dict[tuple[str, ...], str]) -> None:
        self.responses = responses
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, command: list[str]) -> str:
        key = tuple(command)
        self.calls.append(key)
        if key not in self.responses:
            raise AssertionError(f"unexpected command: {command}")
        return self.responses[key]


class CollectUatEvidenceTest(unittest.TestCase):
    def test_android_snapshot_records_device_runtime_and_power_truth(self) -> None:
        serial = "device-1"
        prefix = ("adb", "-s", serial, "shell")
        runner = FakeRunner(
            {
                prefix + ("getprop", "ro.product.model"): "Pixel Test\n",
                prefix + ("getprop", "ro.build.version.release"): "17\n",
                prefix + ("getprop", "ro.build.version.sdk"): "37\n",
                prefix + ("getprop", "ro.product.cpu.abi"): "arm64-v8a\n",
                prefix + ("getconf", "PAGESIZE"): "4096\n",
                prefix + ("dumpsys", "package", uat.ANDROID_PACKAGE): (
                    "versionCode=4013 minSdk=23 targetSdk=35\n"
                    "versionName=4.0.13\n"
                ),
                prefix + ("dumpsys", "battery"): (
                    "  AC powered: false\n  USB powered: true\n"
                    "  Wireless powered: false\n  status: 2\n  level: 90\n"
                    "  temperature: 350\n"
                ),
                prefix + ("pidof", uat.ANDROID_PACKAGE): "1234\n",
                prefix + ("dumpsys", "meminfo", uat.ANDROID_PACKAGE): (
                    "TOTAL PSS: 123456 TOTAL RSS: 234567\n"
                ),
            }
        )

        snapshot = uat.collect_android_snapshot(
            serial=serial,
            runner=runner,
            captured_at="2026-08-20T12:00:00+08:00",
        )

        self.assertEqual(snapshot["device"]["page_size_bytes"], 4096)
        self.assertEqual(snapshot["app"]["version_name"], "4.0.13")
        self.assertEqual(snapshot["app"]["version_code"], 4013)
        self.assertTrue(snapshot["battery"]["powered"])
        self.assertTrue(snapshot["battery"]["usb_powered"])
        self.assertEqual(snapshot["battery"]["temperature_c"], 35.0)
        self.assertEqual(snapshot["process"]["pid"], 1234)
        self.assertEqual(snapshot["captured_at"], "2026-08-20T12:00:00+08:00")

    def test_android_acceptance_refuses_false_16k_or_battery_claims(self) -> None:
        snapshot = {
            "device": {"page_size_bytes": 4096},
            "battery": {"powered": True, "status": 2},
        }

        verdict = uat.android_acceptance_verdict(snapshot)

        self.assertFalse(verdict["android_16k_hardware"])
        self.assertFalse(verdict["battery_baseline_ready"])
        self.assertIn("16384", verdict["android_16k_reason"])
        self.assertIn("external power", verdict["battery_reason"])

    def test_charging_status_blocks_battery_baseline_even_if_power_flags_lag(self) -> None:
        snapshot = {
            "device": {"page_size_bytes": 16384},
            "battery": {"powered": False, "status": 2},
        }

        verdict = uat.android_acceptance_verdict(snapshot)

        self.assertFalse(verdict["battery_baseline_ready"])
        self.assertIn("charging", verdict["battery_reason"])

    def test_timing_summary_uses_observed_median_and_nearest_rank_p95(self) -> None:
        summary = uat.summarize_timings([1.0, 2.0, 3.0, 4.0, 10.0])

        self.assertEqual(summary["count"], 5)
        self.assertEqual(summary["median_seconds"], 3.0)
        self.assertEqual(summary["p95_seconds"], 10.0)
        self.assertEqual(summary["max_seconds"], 10.0)

    def test_macos_process_queries_do_not_capture_unrelated_command_lines(self) -> None:
        process_match, process_status = uat.macos_process_queries(
            Path("/Applications/SSRVPN.app"), "SSRVPN"
        )

        self.assertEqual(
            process_match,
            [
                "pgrep",
                "-f",
                r"^/Applications/SSRVPN\.app/Contents/MacOS/SSRVPN($| )",
            ],
        )
        self.assertEqual(process_status(1234), ["ps", "-o", "pid=,rss=,etime=", "-p", "1234"])

    def test_json_output_is_atomic_and_round_trips(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "snapshot.json"
            payload = {"platform": "android", "ok": True}

            uat.write_json_atomic(path, payload)

            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), payload)
            self.assertFalse(path.with_suffix(".json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
