from contextlib import redirect_stderr
import io
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import check_coverage_thresholds as coverage  # noqa: E402


class CheckCoverageThresholdsTests(unittest.TestCase):
    def _write_lcov(self, text: str) -> Path:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        path = Path(temporary_directory.name) / "lcov.info"
        path.write_text(text, encoding="utf-8")
        return path

    def test_reads_total_and_per_file_lcov_summaries(self) -> None:
        path = self._write_lcov(
            "TN:\n"
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:1,1\n"
            "DA:2,1\n"
            "DA:3,0\n"
            "DA:4,0\n"
            "LF:4\n"
            "LH:2\n"
            "end_of_record\n"
            "SF:C:\\repo\\SSRVPN_MacOS\\lib\\services\\system_proxy_service.dart\n"
            "DA:1,1\n"
            "DA:2,1\n"
            "DA:3,1\n"
            "DA:4,0\n"
            "DA:5,0\n"
            "DA:6,0\n"
            "LF:6\n"
            "LH:3\n"
            "end_of_record\n"
        )

        summary = coverage.read_lcov(path)

        self.assertEqual((summary.found, summary.hit), (10, 5))
        self.assertEqual(
            summary.file_counts["lib/services/clash_service_lifecycle.dart"],
            (4, 2),
        )
        self.assertEqual(
            summary.file_counts[
                "C:/repo/SSRVPN_MacOS/lib/services/system_proxy_service.dart"
            ],
            (6, 3),
        )

    def test_rejects_a_critical_file_below_its_floor(self) -> None:
        path = self._write_lcov(
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:1,1\n"
            "DA:2,0\n"
            "DA:3,0\n"
            "DA:4,0\n"
            "LF:4\n"
            "LH:1\n"
            "end_of_record\n"
            "SF:lib/other.dart\n"
            "DA:1,1\n"
            "DA:2,1\n"
            "DA:3,1\n"
            "DA:4,1\n"
            "LF:4\n"
            "LH:4\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=30.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 50.0,
            },
        )

        self.assertTrue(report.total_passed)
        self.assertEqual(len(report.critical_files), 1)
        self.assertFalse(report.critical_files[0].passed)

    def test_rejects_a_missing_critical_file_record(self) -> None:
        path = self._write_lcov(
            "SF:lib/other.dart\n"
            "DA:1,1\n"
            "LF:1\n"
            "LH:1\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_MacOS",
            path,
            total_threshold=30.0,
            critical_thresholds={
                "lib/services/system_proxy_service.dart": 4.73,
            },
        )

        self.assertTrue(report.total_passed)
        self.assertEqual(report.critical_files[0].found, 0)
        self.assertFalse(report.critical_files[0].passed)

    def test_alias_record_cannot_hide_zero_percent_canonical_coverage(self) -> None:
        path = self._write_lcov(
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:1,0\n"
            "DA:2,0\n"
            "LF:2\n"
            "LH:0\n"
            "end_of_record\n"
            "SF:/tmp/alias/lib/services/clash_service_lifecycle.dart\n"
            "DA:1,1\n"
            "DA:2,1\n"
            "LF:2\n"
            "LH:2\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=30.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 4.19,
            },
        )

        self.assertTrue(report.total_passed)
        self.assertFalse(report.critical_files[0].passed)
        self.assertIn("alias", report.critical_files[0].error or "")

    def test_duplicate_canonical_records_fail_closed(self) -> None:
        path = self._write_lcov(
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:1,0\n"
            "DA:2,0\n"
            "LF:2\n"
            "LH:0\n"
            "end_of_record\n"
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:1,1\n"
            "DA:2,1\n"
            "LF:2\n"
            "LH:2\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=30.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 4.19,
            },
        )

        self.assertTrue(report.total_passed)
        self.assertFalse(report.critical_files[0].passed)
        self.assertIn("multiple", report.critical_files[0].error or "")

    def test_da_lines_override_untrusted_lf_lh_summaries(self) -> None:
        path = self._write_lcov(
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:10,1\n"
            "DA:20,0\n"
            "LF:999\n"
            "LH:999\n"
            "end_of_record\n"
        )

        summary = coverage.read_lcov(path)

        self.assertEqual((summary.found, summary.hit), (2, 1))
        self.assertEqual(
            summary.file_counts["lib/services/clash_service_lifecycle.dart"],
            (2, 1),
        )

    def test_critical_file_without_da_fails_closed(self) -> None:
        path = self._write_lcov(
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "LF:100\n"
            "LH:100\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=30.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 4.19,
            },
        )

        self.assertFalse(report.total_passed)
        self.assertFalse(report.critical_files[0].passed)
        self.assertIn("DA", report.critical_files[0].error or "")

    def test_critical_file_with_invalid_da_fails_closed(self) -> None:
        path = self._write_lcov(
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:not-a-line,not-a-count\n"
            "LF:100\n"
            "LH:100\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=30.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 4.19,
            },
        )

        self.assertFalse(report.total_passed)
        self.assertFalse(report.critical_files[0].passed)
        self.assertIn("invalid DA", report.critical_files[0].error or "")

    def test_unknown_target_fails_instead_of_being_skipped(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)

        error_output = io.StringIO()
        with redirect_stderr(error_output):
            exit_code = coverage.run(
                Path(temporary_directory.name),
                ["SSRVPN_Unknown"],
            )

        self.assertEqual(exit_code, 1)
        self.assertIn("fail unknown target", error_output.getvalue())

    def test_duplicate_da_records_use_line_union_for_aggregate_coverage(self) -> None:
        first_record = [
            "SF:lib/other.dart",
            "DA:1,1",
            *(f"DA:{line},0" for line in range(2, 101)),
            "LF:100",
            "LH:1",
            "end_of_record",
        ]
        second_record = [
            "SF:lib/other.dart",
            "DA:1,1",
            "LF:1",
            "LH:1",
            "end_of_record",
        ]
        path = self._write_lcov(
            "\n".join([*first_record, *second_record, ""])
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=1.5,
            critical_thresholds={},
        )

        self.assertEqual((report.found, report.hit), (100, 1))
        self.assertFalse(report.total_passed)

    def test_duplicate_summary_only_records_fail_aggregate_closed(self) -> None:
        path = self._write_lcov(
            "SF:lib/other.dart\n"
            "LF:100\n"
            "LH:100\n"
            "end_of_record\n"
            "SF:lib/other.dart\n"
            "LF:100\n"
            "LH:100\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=30.0,
            critical_thresholds={},
        )

        self.assertFalse(report.total_passed)
        self.assertIn("duplicate summary-only", " ".join(report.total_errors))

    def test_single_summary_only_record_cannot_inflate_aggregate(self) -> None:
        critical_record = [
            "SF:lib/services/clash_service_lifecycle.dart",
            *(f"DA:{line},{1 if line <= 5 else 0}" for line in range(1, 101)),
            "LF:100",
            "LH:5",
            "end_of_record",
        ]
        fake_record = [
            "SF:lib/fake.dart",
            "LF:1000",
            "LH:1000",
            "end_of_record",
        ]
        path = self._write_lcov(
            "\n".join([*critical_record, *fake_record, ""])
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=30.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 4.19,
            },
        )

        self.assertTrue(report.critical_files[0].passed)
        self.assertFalse(report.total_passed)
        self.assertIn("summary-only", " ".join(report.total_errors))

    def test_single_invalid_da_record_cannot_inflate_aggregate(self) -> None:
        critical_record = [
            "SF:lib/services/clash_service_lifecycle.dart",
            *(f"DA:{line},{1 if line <= 5 else 0}" for line in range(1, 101)),
            "LF:100",
            "LH:5",
            "end_of_record",
        ]
        fake_record = [
            "SF:lib/fake.dart",
            "DA:not-a-line,not-a-count",
            "LF:1000",
            "LH:1000",
            "end_of_record",
        ]
        path = self._write_lcov(
            "\n".join([*critical_record, *fake_record, ""])
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=30.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 4.19,
            },
        )

        self.assertTrue(report.critical_files[0].passed)
        self.assertFalse(report.total_passed)
        self.assertIn("invalid DA", " ".join(report.total_errors))

    def test_configured_floors_do_not_regress_below_reviewed_baselines(self) -> None:
        self.assertGreaterEqual(
            coverage.CRITICAL_FILE_THRESHOLDS["SSRVPN_Windows"]
            ["lib/services/clash_service_lifecycle.dart"],
            4.19,
        )
        self.assertGreaterEqual(
            coverage.CRITICAL_FILE_THRESHOLDS["SSRVPN_MacOS"]
            ["lib/services/clash_service_lifecycle.dart"],
            8.67,
        )
        self.assertGreaterEqual(
            coverage.CRITICAL_FILE_THRESHOLDS["SSRVPN_MacOS"]
            ["lib/services/system_proxy_service.dart"],
            17.75,
        )


if __name__ == "__main__":
    unittest.main()
