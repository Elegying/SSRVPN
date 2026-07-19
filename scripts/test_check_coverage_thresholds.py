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

    def test_lf_lh_must_match_deduplicated_da_counts(self) -> None:
        cases = {
            "LF": (
                "LF:999\n"
                "LH:1\n",
                "LF/DA mismatch",
            ),
            "LH": (
                "LF:2\n"
                "LH:2\n",
                "LH/DA mismatch",
            ),
        }

        for name, (summary_lines, expected_error) in cases.items():
            with self.subTest(name=name):
                path = self._write_lcov(
                    "SF:lib/services/clash_service_lifecycle.dart\n"
                    "DA:10,1\n"
                    "DA:20,0\n"
                    f"{summary_lines}"
                    "end_of_record\n"
                )

                summary = coverage.read_lcov(path)

                self.assertEqual(
                    summary.file_counts[
                        "lib/services/clash_service_lifecycle.dart"
                    ],
                    (0, 0),
                )
                self.assertIn(expected_error, " ".join(summary.errors))

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
                self.assertIn(
                    expected_error,
                    report.critical_files[0].error or "",
                )

    def test_each_record_requires_both_lf_and_lh(self) -> None:
        cases = {
            "LF": ("LH:1\n", "missing LF"),
            "LH": ("LF:1\n", "missing LH"),
        }

        for name, (summary_lines, expected_error) in cases.items():
            with self.subTest(name=name):
                path = self._write_lcov(
                    "SF:lib/other.dart\n"
                    "DA:1,1\n"
                    f"{summary_lines}"
                    "end_of_record\n"
                )

                summary = coverage.read_lcov(path)

                self.assertEqual(summary.file_counts["lib/other.dart"], (0, 0))
                self.assertIn(expected_error, " ".join(summary.errors))

    def test_each_record_rejects_duplicate_lf_or_lh(self) -> None:
        cases = {
            "LF": (
                "LF:1\n"
                "LF:1\n"
                "LH:1\n",
                "duplicate LF",
            ),
            "LH": (
                "LF:1\n"
                "LH:1\n"
                "LH:1\n",
                "duplicate LH",
            ),
        }

        for name, (summary_lines, expected_error) in cases.items():
            with self.subTest(name=name):
                path = self._write_lcov(
                    "SF:lib/other.dart\n"
                    "DA:1,1\n"
                    f"{summary_lines}"
                    "end_of_record\n"
                )

                summary = coverage.read_lcov(path)

                self.assertEqual(summary.file_counts["lib/other.dart"], (0, 0))
                self.assertIn(expected_error, " ".join(summary.errors))

    def test_each_record_rejects_invalid_lf_or_lh(self) -> None:
        cases = {
            "LF": (
                "LF:-1\n"
                "LH:1\n",
                "invalid LF",
            ),
            "LH": (
                "LF:1\n"
                "LH:not-a-number\n",
                "invalid LH",
            ),
        }

        for name, (summary_lines, expected_error) in cases.items():
            with self.subTest(name=name):
                path = self._write_lcov(
                    "SF:lib/other.dart\n"
                    "DA:1,1\n"
                    f"{summary_lines}"
                    "end_of_record\n"
                )

                summary = coverage.read_lcov(path)

                self.assertEqual(summary.file_counts["lib/other.dart"], (0, 0))
                self.assertIn(expected_error, " ".join(summary.errors))

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

    def test_da_with_extra_fields_fails_aggregate_and_critical_closed(self) -> None:
        path = self._write_lcov(
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:1,1,1B2M2Y8AsgTpgAmY7PhCfg,extra\n"
            "LF:1\n"
            "LH:1\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=0.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 0.0,
            },
        )

        self.assertFalse(report.total_passed)
        self.assertIn("invalid DA", " ".join(report.total_errors))
        self.assertFalse(report.critical_files[0].passed)
        self.assertIn("invalid DA", report.critical_files[0].error or "")

    def test_da_accepts_an_optional_lcov_checksum(self) -> None:
        path = self._write_lcov(
            "SF:lib/services/clash_service_lifecycle.dart\n"
            "DA:1,1,1B2M2Y8AsgTpgAmY7PhCfg\n"
            "LF:1\n"
            "LH:1\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=100.0,
            critical_thresholds={
                "lib/services/clash_service_lifecycle.dart": 100.0,
            },
        )

        self.assertTrue(report.total_passed)
        self.assertTrue(report.critical_files[0].passed)

    def test_da_rejects_an_empty_or_whitespace_checksum(self) -> None:
        for checksum in ("", "not a checksum"):
            with self.subTest(checksum=checksum):
                path = self._write_lcov(
                    "SF:lib/other.dart\n"
                    f"DA:1,1,{checksum}\n"
                    "LF:1\n"
                    "LH:1\n"
                    "end_of_record\n"
                )

                summary = coverage.read_lcov(path)

                self.assertEqual(summary.file_counts["lib/other.dart"], (0, 0))
                self.assertIn("invalid DA", " ".join(summary.errors))

    def test_da_line_and_count_require_nonempty_ascii_decimal_digits(self) -> None:
        invalid_fields = (
            ("", "1"),
            ("+1", "1"),
            ("1_0", "1"),
            ("\u0661", "1"),
            ("１", "1"),
            (" 1", "1"),
            ("1 ", "1"),
            ("1", ""),
            ("1", "+1"),
            ("1", "1_0"),
            ("1", "\u0661"),
            ("1", "１"),
            ("1", " 1"),
            ("1", "1 "),
        )

        for line, count in invalid_fields:
            with self.subTest(line=line, count=count):
                path = self._write_lcov(
                    "SF:lib/other.dart\n"
                    f"DA:{line},{count}\n"
                    "LF:1\n"
                    "LH:1\n"
                    "end_of_record\n"
                )

                summary = coverage.read_lcov(path)

                self.assertEqual(summary.file_counts["lib/other.dart"], (0, 0))
                self.assertIn("invalid DA", " ".join(summary.errors))

    def test_invalid_utf8_lcov_fails_closed_instead_of_dropping_bytes(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        path = Path(temporary_directory.name) / "lcov.info"
        path.write_bytes(
            b"SF:lib/other.dart\n"
            b"DA:1,\xff1\n"
            b"LF:1\n"
            b"LH:1\n"
            b"end_of_record\n"
        )

        summary = coverage.read_lcov(path)

        self.assertEqual((summary.found, summary.hit), (0, 0))
        self.assertEqual(summary.file_counts, {})
        self.assertIn("LCOV is not valid UTF-8", summary.errors)

    def test_target_manifest_rejects_an_sf_outside_the_target(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        target_root = Path(temporary_directory.name) / "SSRVPN_Test"
        (target_root / "lib").mkdir(parents=True)
        (target_root / "lib" / "real.dart").write_text(
            "int real() => 1;\n",
            encoding="utf-8",
        )
        path = self._write_lcov(
            "SF:lib/real.dart\n"
            "DA:1,0\n"
            "LF:1\n"
            "LH:0\n"
            "end_of_record\n"
            "SF:/tmp/fake/lib/fake.dart\n"
            "DA:1,1\n"
            "DA:2,1\n"
            "LF:2\n"
            "LH:2\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Test",
            path,
            total_threshold=50.0,
            critical_thresholds={},
            target_root=target_root,
        )

        self.assertEqual((report.found, report.hit), (1, 0))
        self.assertFalse(report.total_passed)
        self.assertIn("outside production source manifest", " ".join(report.total_errors))

    def test_target_manifest_fails_when_a_production_source_is_missing(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        target_root = Path(temporary_directory.name) / "SSRVPN_Test"
        (target_root / "lib").mkdir(parents=True)
        for name in ("covered.dart", "missing.dart"):
            (target_root / "lib" / name).write_text(
                f"int {name.removesuffix('.dart')}() => 1;\n",
                encoding="utf-8",
            )
        path = self._write_lcov(
            "SF:lib/covered.dart\n"
            "DA:1,1\n"
            "LF:1\n"
            "LH:1\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Test",
            path,
            total_threshold=50.0,
            critical_thresholds={},
            target_root=target_root,
        )

        self.assertFalse(report.total_passed)
        self.assertIn(
            "production source missing from LCOV: lib/missing.dart",
            report.total_errors,
        )

    def test_source_manifest_includes_owned_parts_and_excludes_generated_files(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        target_root = Path(temporary_directory.name) / "SSRVPN_Test"
        (target_root / "lib").mkdir(parents=True)
        (target_root / "lib" / "owner.dart").write_text(
            "part 'owned_part.dart';\nint owner() => owned();\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "owned_part.dart").write_text(
            "part of 'owner.dart';\nint owned() => 1;\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "external_part.dart").write_text(
            "part of external_library;\nint external() => 1;\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "model.g.dart").write_text(
            "int generated() => 1;\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "header_generated.dart").write_text(
            "// GENERATED CODE - DO NOT MODIFY BY HAND\nint generated() => 1;\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "generated_codex.dart").write_text(
            "// GENERATED CODEX is a product name, not a generator marker\n"
            "int real() => 1;\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "exports.dart").write_text(
            "library;\nexport 'owner.dart';\n",
            encoding="utf-8",
        )

        manifest = coverage.discover_production_sources(target_root)

        self.assertEqual(
            manifest.included,
            frozenset(
                {
                    "lib/generated_codex.dart",
                    "lib/owner.dart",
                    "lib/owned_part.dart",
                }
            ),
        )
        self.assertEqual(
            manifest.excluded_generated,
            frozenset({"lib/model.g.dart", "lib/header_generated.dart"}),
        )
        self.assertEqual(
            manifest.excluded_external_parts,
            frozenset({"lib/external_part.dart"}),
        )
        self.assertEqual(
            manifest.excluded_non_coverable,
            frozenset({"lib/exports.dart"}),
        )

    def test_manifest_ignores_part_and_generated_decoys_in_comments_and_strings(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        target_root = Path(temporary_directory.name) / "SSRVPN_Test"
        (target_root / "lib").mkdir(parents=True)
        decoys = {
            "block_comment.dart": (
                "/*\npart of fake;\n// GENERATED CODE\n*/\n"
                "int blockCommentValue() => 1;\n"
            ),
            "triple_string.dart": (
                "const marker = '''\npart of fake;\n// GENERATED CODE\n''';\n"
                "int tripleStringValue() => 1;\n"
            ),
        }
        for name, text in decoys.items():
            (target_root / "lib" / name).write_text(text, encoding="utf-8")

        manifest = coverage.discover_production_sources(target_root)

        for name in decoys:
            relative = f"lib/{name}"
            self.assertIn(relative, manifest.included)
            self.assertNotIn(relative, manifest.excluded_generated)
            self.assertNotIn(relative, manifest.excluded_external_parts)

    def test_manifest_lexically_normalises_owned_part_parent_segments(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        target_root = Path(temporary_directory.name) / "SSRVPN_Test"
        (target_root / "lib" / "nested").mkdir(parents=True)
        (target_root / "lib" / "nested" / "owner.dart").write_text(
            "part /* ownership comment */ '../owned.dart';\n"
            "int owner() => owned();\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "owned.dart").write_text(
            "part of 'nested/owner.dart';\nint owned() => 1;\n",
            encoding="utf-8",
        )

        manifest = coverage.discover_production_sources(target_root)

        self.assertIn("lib/owned.dart", manifest.included)
        self.assertNotIn("lib/owned.dart", manifest.excluded_external_parts)

    def test_manifest_never_resolves_a_part_above_the_lib_root(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        target_root = Path(temporary_directory.name) / "SSRVPN_Test"
        (target_root / "lib").mkdir(parents=True)
        (target_root / "lib" / "owner.dart").write_text(
            "part '../../outside.dart';\nint owner() => 1;\n",
            encoding="utf-8",
        )
        (target_root / "outside.dart").write_text(
            "part of 'lib/owner.dart';\nint outside() => 1;\n",
            encoding="utf-8",
        )

        manifest = coverage.discover_production_sources(target_root)

        self.assertEqual(manifest.included, frozenset({"lib/owner.dart"}))

    def test_non_coverable_exception_closes_when_source_gains_behavior(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        target_root = Path(temporary_directory.name) / "ssrvpn_shared"
        source = target_root / "lib" / "constants" / "app_constants.dart"
        source.parent.mkdir(parents=True)
        source.write_text(
            "class AppConstants {\n"
            "  static const value = 1;\n"
            "  static int runtimeValue() => value;\n"
            "}\n",
            encoding="utf-8",
        )

        manifest = coverage.discover_production_sources(
            target_root,
            "packages/ssrvpn_shared",
        )

        self.assertIn("lib/constants/app_constants.dart", manifest.included)
        self.assertNotIn(
            "lib/constants/app_constants.dart",
            manifest.excluded_non_coverable,
        )

    def test_desktop_manifest_counts_only_locally_owned_shared_parts(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        repo_root = Path(temporary_directory.name)
        target_root = repo_root / "SSRVPN_MacOS"
        shared_lib = repo_root / "packages" / "ssrvpn_shared" / "lib"
        (target_root / "lib").mkdir(parents=True)
        (shared_lib / "desktop_ui").mkdir(parents=True)
        (shared_lib / "models").mkdir(parents=True)
        (target_root / "lib" / "screen.dart").write_text(
            "library desktop_screen;\n"
            "part 'package:ssrvpn_shared/desktop_ui/screen_part.dart';\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "runtime.dart").write_text(
            "int runtime() => 1;\n",
            encoding="utf-8",
        )
        (shared_lib / "desktop_ui" / "screen_part.dart").write_text(
            "part of desktop_screen;\nint screenValue() => 1;\n",
            encoding="utf-8",
        )
        (shared_lib / "models" / "dependency.dart").write_text(
            "int dependency() => 1;\n",
            encoding="utf-8",
        )
        path = self._write_lcov(
            "SF:lib/runtime.dart\n"
            "DA:1,0\n"
            "LF:1\n"
            "LH:0\n"
            "end_of_record\n"
            "SF:../packages/ssrvpn_shared/lib/desktop_ui/screen_part.dart\n"
            "DA:2,0\n"
            "LF:1\n"
            "LH:0\n"
            "end_of_record\n"
            "SF:../packages/ssrvpn_shared/lib/models/dependency.dart\n"
            "DA:1,1\n"
            "LF:1\n"
            "LH:1\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_MacOS",
            path,
            total_threshold=1.0,
            critical_thresholds={},
            target_root=target_root,
        )

        self.assertEqual((report.found, report.hit), (2, 0))
        self.assertFalse(report.total_passed)
        self.assertEqual(report.total_errors, ())

    def test_desktop_manifest_requires_every_locally_owned_shared_part(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        repo_root = Path(temporary_directory.name)
        target_root = repo_root / "SSRVPN_Windows"
        shared_part = (
            repo_root
            / "packages"
            / "ssrvpn_shared"
            / "lib"
            / "desktop_ui"
            / "screen_part.dart"
        )
        (target_root / "lib").mkdir(parents=True)
        shared_part.parent.mkdir(parents=True)
        (target_root / "lib" / "screen.dart").write_text(
            "library desktop_screen;\n"
            "part 'package:ssrvpn_shared/desktop_ui/screen_part.dart';\n",
            encoding="utf-8",
        )
        (target_root / "lib" / "runtime.dart").write_text(
            "int runtime() => 1;\n",
            encoding="utf-8",
        )
        shared_part.write_text(
            "part of desktop_screen;\nint screenValue() => 1;\n",
            encoding="utf-8",
        )
        path = self._write_lcov(
            "SF:lib/runtime.dart\n"
            "DA:1,1\n"
            "LF:1\n"
            "LH:1\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_Windows",
            path,
            total_threshold=1.0,
            critical_thresholds={},
            target_root=target_root,
        )

        self.assertFalse(report.total_passed)
        self.assertIn(
            "production source missing from LCOV: "
            "../packages/ssrvpn_shared/lib/desktop_ui/screen_part.dart",
            report.total_errors,
        )

    def test_desktop_manifest_rejects_a_fake_shared_dependency_source(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        repo_root = Path(temporary_directory.name)
        target_root = repo_root / "SSRVPN_MacOS"
        (target_root / "lib").mkdir(parents=True)
        (repo_root / "packages" / "ssrvpn_shared" / "lib").mkdir(parents=True)
        (target_root / "lib" / "runtime.dart").write_text(
            "int runtime() => 1;\n",
            encoding="utf-8",
        )
        path = self._write_lcov(
            "SF:lib/runtime.dart\n"
            "DA:1,0\n"
            "LF:1\n"
            "LH:0\n"
            "end_of_record\n"
            "SF:../packages/ssrvpn_shared/lib/fake.dart\n"
            "DA:1,1\n"
            "DA:2,1\n"
            "LF:2\n"
            "LH:2\n"
            "end_of_record\n"
        )

        report = coverage.evaluate_lcov(
            "SSRVPN_MacOS",
            path,
            total_threshold=1.0,
            critical_thresholds={},
            target_root=target_root,
        )

        self.assertEqual((report.found, report.hit), (1, 0))
        self.assertFalse(report.total_passed)
        self.assertIn("outside production source manifest", " ".join(report.total_errors))

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
            coverage.TOTAL_THRESHOLDS["SSRVPN_Android"],
            30.0,
        )
        self.assertGreaterEqual(
            coverage.CRITICAL_FILE_THRESHOLDS["SSRVPN_Windows"]
            ["lib/services/clash_service_lifecycle.dart"],
            4.19,
        )
        self.assertGreaterEqual(
            coverage.CRITICAL_FILE_THRESHOLDS["SSRVPN_MacOS"]
            ["lib/services/clash_service_lifecycle.dart"],
            60.0,
        )
        self.assertGreaterEqual(
            coverage.CRITICAL_FILE_THRESHOLDS["SSRVPN_MacOS"]
            ["lib/services/system_proxy_service.dart"],
            80.0,
        )


if __name__ == "__main__":
    unittest.main()
