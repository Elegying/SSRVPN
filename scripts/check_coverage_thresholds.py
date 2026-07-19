#!/usr/bin/env python3
"""Enforce aggregate and critical-file line coverage floors."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import sys
from typing import Mapping, Sequence


TOTAL_THRESHOLDS = {
    "packages/ssrvpn_shared": 65.0,
    "SSRVPN_Android": 50.0,
    "SSRVPN_MacOS": 30.0,
    "SSRVPN_Windows": 30.0,
}

# These floors ratchet the review's measured baselines. Raising a floor requires
# fresh full-suite coverage evidence; lowering one requires an explicit review.
CRITICAL_FILE_THRESHOLDS = {
    "SSRVPN_MacOS": {
        "lib/services/clash_service_lifecycle.dart": 16.98,
        "lib/services/system_proxy_service.dart": 17.75,
    },
    "SSRVPN_Windows": {
        "lib/services/clash_service_lifecycle.dart": 4.19,
    },
}


@dataclass(frozen=True)
class LcovRecord:
    source: str
    found: int
    hit: int
    saw_da: bool
    valid_da: bool
    line_hits: tuple[tuple[int, int], ...]


@dataclass(frozen=True)
class LcovSummary:
    found: int
    hit: int
    file_counts: Mapping[str, tuple[int, int]]
    records: tuple[LcovRecord, ...]
    errors: tuple[str, ...]


@dataclass(frozen=True)
class FileCoverage:
    path: str
    found: int
    hit: int
    threshold: float
    error: str | None = None

    @property
    def percent(self) -> float:
        return self.hit / self.found * 100 if self.found else 0.0

    @property
    def passed(self) -> bool:
        return (
            self.error is None
            and self.found > 0
            and self.percent + 1e-9 >= self.threshold
        )


@dataclass(frozen=True)
class CoverageReport:
    target: str
    found: int
    hit: int
    total_threshold: float
    critical_files: tuple[FileCoverage, ...]
    total_errors: tuple[str, ...] = ()

    @property
    def percent(self) -> float:
        return self.hit / self.found * 100 if self.found else 0.0

    @property
    def total_passed(self) -> bool:
        return (
            not self.total_errors
            and self.found > 0
            and self.percent + 1e-9 >= self.total_threshold
        )

    @property
    def passed(self) -> bool:
        return self.total_passed and all(item.passed for item in self.critical_files)


def _normalise_source(source: str) -> str:
    normalised = source.strip().replace("\\", "/")
    while normalised.startswith("./"):
        normalised = normalised[2:]
    return normalised


def read_lcov(path: Path) -> LcovSummary:
    records: list[LcovRecord] = []
    source: str | None = None
    declared_found: int | None = None
    declared_hit: int | None = None
    line_hits: dict[int, int] = {}
    saw_da = False
    invalid_da = False

    def finish_record() -> None:
        nonlocal source, declared_found, declared_hit, line_hits, saw_da, invalid_da
        if source is not None:
            if line_hits:
                found = len(line_hits)
                hit = sum(1 for count in line_hits.values() if count > 0)
            else:
                found = declared_found or 0
                hit = declared_hit or 0
            records.append(
                LcovRecord(
                    source,
                    found,
                    hit,
                    saw_da=saw_da,
                    valid_da=saw_da and not invalid_da and bool(line_hits),
                    line_hits=tuple(sorted(line_hits.items())),
                )
            )
        source = None
        declared_found = None
        declared_hit = None
        line_hits = {}
        saw_da = False
        invalid_da = False

    for raw_line in path.read_text(errors="ignore").splitlines():
        if raw_line.startswith("SF:"):
            finish_record()
            source = _normalise_source(raw_line.split(":", 1)[1])
        elif raw_line.startswith("DA:") and source is not None:
            saw_da = True
            fields = raw_line.split(":", 1)[1].split(",")
            if len(fields) < 2:
                invalid_da = True
                continue
            try:
                line = int(fields[0])
                count = int(fields[1])
            except ValueError:
                invalid_da = True
                continue
            if line <= 0 or count < 0:
                invalid_da = True
                continue
            line_hits[line] = max(line_hits.get(line, 0), count)
        elif raw_line.startswith("LF:"):
            declared_found = int(raw_line.split(":", 1)[1])
        elif raw_line.startswith("LH:"):
            declared_hit = int(raw_line.split(":", 1)[1])
        elif raw_line == "end_of_record":
            finish_record()
    finish_record()

    records_by_source: dict[str, list[LcovRecord]] = {}
    for record in records:
        records_by_source.setdefault(record.source, []).append(record)

    file_counts: dict[str, tuple[int, int]] = {}
    errors: list[str] = []
    for record_source, source_records in records_by_source.items():
        has_summary_only = any(not record.saw_da for record in source_records)
        has_invalid_da = any(
            record.saw_da and not record.valid_da for record in source_records
        )
        if has_summary_only or has_invalid_da:
            file_counts[record_source] = (0, 0)
            if has_summary_only and has_invalid_da:
                kind = "summary-only/invalid DA"
            elif has_summary_only:
                kind = "summary-only"
            else:
                kind = "invalid DA"
            duplicate = "duplicate " if len(source_records) > 1 else ""
            errors.append(
                f"{duplicate}{kind} LCOV record rejected: {record_source}"
            )
            continue
        if len(source_records) == 1:
            record = source_records[0]
            file_counts[record_source] = (record.found, record.hit)
            continue

        merged_line_hits: dict[int, int] = {}
        for record in source_records:
            for line, count in record.line_hits:
                merged_line_hits[line] = max(
                    merged_line_hits.get(line, 0),
                    count,
                )
        file_counts[record_source] = (
            len(merged_line_hits),
            sum(1 for count in merged_line_hits.values() if count > 0),
        )

    return LcovSummary(
        found=sum(counts[0] for counts in file_counts.values()),
        hit=sum(counts[1] for counts in file_counts.values()),
        file_counts=file_counts,
        records=tuple(records),
        errors=tuple(errors),
    )


def _critical_file_coverage(
    summary: LcovSummary,
    relative_path: str,
    threshold: float,
    target_root: Path | None,
) -> FileCoverage:
    relative_path = _normalise_source(relative_path)
    candidates = [
        record
        for record in summary.records
        if record.source == relative_path
        or record.source.endswith(f"/{relative_path}")
    ]
    canonical_sources = {relative_path}
    if target_root is not None:
        canonical_sources.add(
            _normalise_source(str(target_root.resolve() / relative_path))
        )
    canonical = [
        record for record in candidates if record.source in canonical_sources
    ]
    aliases = [
        record for record in candidates if record.source not in canonical_sources
    ]

    if aliases:
        alias_names = ", ".join(sorted({record.source for record in aliases}))
        return FileCoverage(
            relative_path,
            0,
            0,
            threshold,
            error=f"alias LCOV record rejected: {alias_names}",
        )
    if len(canonical) > 1:
        return FileCoverage(
            relative_path,
            0,
            0,
            threshold,
            error="multiple canonical LCOV records rejected",
        )
    if not canonical:
        return FileCoverage(
            relative_path,
            0,
            0,
            threshold,
            error="canonical LCOV record missing",
        )

    record = canonical[0]
    if not record.saw_da:
        return FileCoverage(
            relative_path,
            0,
            0,
            threshold,
            error="canonical LCOV record missing DA line coverage",
        )
    if not record.valid_da:
        return FileCoverage(
            relative_path,
            0,
            0,
            threshold,
            error="canonical LCOV record has invalid DA line coverage",
        )
    return FileCoverage(
        relative_path,
        record.found,
        record.hit,
        threshold,
    )


def evaluate_lcov(
    target: str,
    path: Path,
    *,
    total_threshold: float,
    critical_thresholds: Mapping[str, float],
    target_root: Path | None = None,
) -> CoverageReport:
    summary = read_lcov(path)
    critical_files = [
        _critical_file_coverage(
            summary,
            relative_path,
            threshold,
            target_root,
        )
        for relative_path, threshold in critical_thresholds.items()
    ]
    return CoverageReport(
        target=target,
        found=summary.found,
        hit=summary.hit,
        total_threshold=total_threshold,
        critical_files=tuple(critical_files),
        total_errors=summary.errors,
    )


def is_shared_source(source: str) -> bool:
    if source.startswith("package:ssrvpn_shared/"):
        relative = source.removeprefix("package:ssrvpn_shared/")
        return relative == "ssrvpn_shared.dart" or relative.split("/", 1)[0] in {
            "controllers",
            "desktop_ui",
            "models",
            "services",
            "utils",
            "widgets",
        }
    return "/packages/ssrvpn_shared/lib/" in source


def read_dart_vm_coverage(directory: Path) -> tuple[int, int]:
    covered_lines: dict[tuple[str, int], int] = {}
    for path in directory.rglob("*.vm.json"):
        try:
            data = json.loads(path.read_text(errors="ignore"))
        except json.JSONDecodeError:
            print(f"coverage: warning invalid JSON {path}")
            continue
        for entry in data.get("coverage", []):
            source = entry.get("source", "")
            if not is_shared_source(source):
                continue
            hits = entry.get("hits") or []
            for index in range(0, len(hits), 2):
                key = (source, int(hits[index]))
                covered_lines[key] = max(
                    covered_lines.get(key, 0),
                    int(hits[index + 1]),
                )
    return len(covered_lines), sum(1 for count in covered_lines.values() if count > 0)


def _print_report(report: CoverageReport) -> None:
    print(
        f"coverage: {report.target} {report.percent:.2f}% "
        f"({report.hit}/{report.found}), threshold {report.total_threshold:.2f}%"
    )
    for error in report.total_errors:
        print(f"coverage: fail {report.target} aggregate: {error}")
    for item in report.critical_files:
        if item.error is not None:
            print(
                f"coverage: fail {report.target}/{item.path}: {item.error}"
            )
            continue
        print(
            f"coverage: {report.target}/{item.path} {item.percent:.2f}% "
            f"({item.hit}/{item.found}), floor {item.threshold:.2f}%"
        )


def run(root: Path, targets: Sequence[str]) -> int:
    selected_targets = list(targets) or list(TOTAL_THRESHOLDS)
    failed = False
    for target in selected_targets:
        threshold = TOTAL_THRESHOLDS.get(target)
        if threshold is None:
            print(f"coverage: fail unknown target {target}", file=sys.stderr)
            return 1

        coverage_dir = root / target / "coverage"
        lcov = coverage_dir / "lcov.info"
        if lcov.exists():
            report = evaluate_lcov(
                target,
                lcov,
                total_threshold=threshold,
                critical_thresholds=CRITICAL_FILE_THRESHOLDS.get(target, {}),
                target_root=root / target,
            )
            _print_report(report)
            failed = failed or not report.passed
            continue

        if target == "packages/ssrvpn_shared" and coverage_dir.exists():
            found, hit = read_dart_vm_coverage(coverage_dir)
            percent = hit / found * 100 if found else 0.0
            print(
                f"coverage: {target} {percent:.2f}% ({hit}/{found}), "
                f"threshold {threshold:.2f}%"
            )
            failed = failed or found == 0 or percent + 1e-9 < threshold
            continue

        print(f"coverage: fail {target}, missing coverage output")
        failed = True

    if failed:
        print("coverage threshold failed", file=sys.stderr)
        return 1
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    root = Path(__file__).resolve().parents[1]
    return run(root, arguments)


if __name__ == "__main__":
    raise SystemExit(main())
