#!/usr/bin/env python3
"""Enforce aggregate and critical-file line coverage floors."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys
from typing import Mapping, Sequence


TOTAL_THRESHOLDS = {
    "packages/ssrvpn_shared": 65.0,
    "SSRVPN_Android": 30.0,
    "SSRVPN_MacOS": 30.0,
    "SSRVPN_Windows": 30.0,
}

# These floors ratchet the review's measured baselines. Raising a floor requires
# fresh full-suite coverage evidence; lowering one requires an explicit review.
CRITICAL_FILE_THRESHOLDS = {
    "SSRVPN_MacOS": {
        "lib/services/clash_service_lifecycle.dart": 60.0,
        "lib/services/system_proxy_service.dart": 80.0,
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
    summary_error: str | None
    line_hits: tuple[tuple[int, int], ...]


@dataclass(frozen=True)
class LcovSummary:
    found: int
    hit: int
    file_counts: Mapping[str, tuple[int, int]]
    records: tuple[LcovRecord, ...]
    errors: tuple[str, ...]


@dataclass(frozen=True)
class ProductionSourceManifest:
    included: frozenset[str]
    included_external_parts: frozenset[str]
    ignored_dependency_sources: frozenset[str]
    excluded_generated: frozenset[str]
    excluded_external_parts: frozenset[str]
    excluded_non_coverable: frozenset[str]


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


def _is_ascii_decimal(value: str) -> bool:
    return bool(value) and value.isascii() and value.isdecimal()


_GENERATED_SUFFIXES = (".freezed.dart", ".g.dart", ".gr.dart", ".mocks.dart")
_PART_OF_DIRECTIVE = re.compile(r"(?m)^[ \t]*part\s+of\b")
_PART_DIRECTIVE = re.compile(r"(?m)^[ \t]*part\s+['\"]([^'\"]+)['\"]\s*;")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)
_FULL_LINE_COMMENT = re.compile(r"(?m)^[ \t]*//.*(?:\n|$)")
_DART_DIRECTIVE = re.compile(
    r"(?ms)^[ \t]*(?:library|import|export|part)\b.*?;[ \t]*(?:\n|$)"
)
_DART_STRING = re.compile(
    r'''(?sx)
    (?:r)?''' + "'''" + r'''.*?''' + "'''" + r'''|
    (?:r)?""".*?"""|
    (?:r)?'(?:\\.|[^'\\])*'|
    (?:r)?"(?:\\.|[^"\\])*"
    '''
)

# Dart's coverage format has no executable line entries for these declaration-
# only sources. Keeping the exception explicit prevents a broad syntax guess
# from silently excluding future production logic.
_EXPLICIT_NON_COVERABLE = {
    "packages/ssrvpn_shared": frozenset({"lib/constants/app_constants.dart"}),
}


def _contains_only_directives_and_comments(text: str) -> bool:
    without_comments = _FULL_LINE_COMMENT.sub("", _BLOCK_COMMENT.sub("", text))
    return not _DART_DIRECTIVE.sub("", without_comments).strip()


def _contains_only_static_constants(text: str) -> bool:
    without_strings = _DART_STRING.sub("''", text)
    without_comments = re.sub(
        r"(?m)//.*$",
        "",
        _BLOCK_COMMENT.sub("", without_strings),
    )
    match = re.fullmatch(
        r"\s*class\s+[A-Za-z_$][\w$]*\s*\{(?P<body>.*)\}\s*",
        without_comments,
        re.DOTALL,
    )
    if match is None:
        return False
    statements = [item.strip() for item in match.group("body").split(";")]
    return bool(statements) and all(
        not statement or re.match(r"^static\s+const\b", statement)
        for statement in statements
    )


def _has_generated_header(text: str) -> bool:
    stripped = text.lstrip("\ufeff \t\r\n")
    return re.match(r"^//\s*GENERATED CODE(?:[ \t]|$)", stripped) is not None


def _dart_code_flags(text: str) -> list[bool]:
    """Mark source positions that are outside Dart comments and strings."""

    flags = [True] * len(text)
    index = 0
    while index < len(text):
        if text.startswith("//", index):
            end = text.find("\n", index + 2)
            if end == -1:
                end = len(text)
            flags[index:end] = [False] * (end - index)
            index = end
            continue
        if text.startswith("/*", index):
            start = index
            depth = 1
            index += 2
            while index < len(text) and depth:
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            flags[start:index] = [False] * (index - start)
            continue
        if text[index] in {"'", '"'}:
            start = index
            quote = text[index]
            width = 3 if text.startswith(quote * 3, index) else 1
            raw = index > 0 and text[index - 1] in {"r", "R"}
            index += width
            while index < len(text):
                if text.startswith(quote * width, index):
                    index += width
                    break
                if not raw and text[index] == "\\":
                    index = min(index + 2, len(text))
                else:
                    index += 1
            flags[start:index] = [False] * (index - start)
            continue
        index += 1
    return flags


def _mask_dart_comments(text: str) -> str:
    """Replace comments with whitespace while preserving strings and offsets."""

    masked = list(text)
    index = 0
    while index < len(text):
        if text.startswith("//", index):
            end = text.find("\n", index + 2)
            if end == -1:
                end = len(text)
            for comment_index in range(index, end):
                masked[comment_index] = " "
            index = end
            continue
        if text.startswith("/*", index):
            start = index
            depth = 1
            index += 2
            while index < len(text) and depth:
                if text.startswith("/*", index):
                    depth += 1
                    index += 2
                elif text.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            for comment_index in range(start, index):
                if text[comment_index] not in {"\r", "\n"}:
                    masked[comment_index] = " "
            continue
        if text[index] in {"'", '"'}:
            quote = text[index]
            width = 3 if text.startswith(quote * 3, index) else 1
            raw = index > 0 and text[index - 1] in {"r", "R"}
            index += width
            while index < len(text):
                if text.startswith(quote * width, index):
                    index += width
                    break
                if not raw and text[index] == "\\":
                    index = min(index + 2, len(text))
                else:
                    index += 1
            continue
        index += 1
    return "".join(masked)


def _code_directive_matches(pattern: re.Pattern[str], text: str) -> list[re.Match[str]]:
    flags = _dart_code_flags(text)
    searchable = _mask_dart_comments(text)
    matches: list[re.Match[str]] = []
    for match in pattern.finditer(searchable):
        keyword = searchable.find("part", match.start(), match.end())
        if keyword >= 0 and flags[keyword]:
            matches.append(match)
    return matches


def _normalise_relative_source_path(value: str) -> str | None:
    parts: list[str] = []
    for part in value.replace("\\", "/").split("/"):
        if part in {"", "."}:
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
            continue
        parts.append(part)
    return "/".join(parts) or None


def discover_production_sources(
    target_root: Path,
    target: str | None = None,
) -> ProductionSourceManifest:
    """Build an auditable source inventory from a target's checked-in lib tree.

    Generated Dart outputs are excluded because their source of truth is the
    generator input. A `part of` fragment is included when a library in the
    same target owns it. Fragments owned by a consuming package (the shared
    desktop UI pattern) are excluded here because they cannot be loaded as a
    library in this target on their own.
    """

    lib_root = target_root / "lib"
    sources: dict[str, str] = {}
    generated: set[str] = set()
    if not lib_root.is_dir():
        return ProductionSourceManifest(
            frozenset(),
            frozenset(),
            frozenset(),
            frozenset(),
            frozenset(),
            frozenset(),
        )

    for path in sorted(lib_root.rglob("*.dart")):
        relative = _normalise_source(str(path.relative_to(target_root)))
        text = path.read_text(encoding="utf-8", errors="ignore")
        if path.name.endswith(_GENERATED_SUFFIXES) or _has_generated_header(text):
            generated.add(relative)
            continue
        sources[relative] = text

    locally_owned_parts: set[str] = set()
    for owner_relative, text in sources.items():
        owner_directory = Path(owner_relative).parent
        for match in _code_directive_matches(_PART_DIRECTIVE, text):
            uri = match.group(1)
            if ":" in uri:
                continue
            owned = _normalise_relative_source_path(str(owner_directory / uri))
            if owned is not None and owned.startswith("lib/") and owned in sources:
                locally_owned_parts.add(owned)

    external_parts = {
        relative
        for relative, text in sources.items()
        if _code_directive_matches(_PART_OF_DIRECTIVE, text)
        and relative not in locally_owned_parts
    }
    non_coverable = {
        relative
        for relative, text in sources.items()
        if _contains_only_directives_and_comments(text)
    }
    if target is not None:
        for relative in _EXPLICIT_NON_COVERABLE.get(target, ()):
            text = sources.get(relative)
            if text is not None and _contains_only_static_constants(text):
                non_coverable.add(relative)
    non_coverable.intersection_update(sources)
    included = set(sources) - external_parts - non_coverable

    included_external_parts: set[str] = set()
    ignored_dependency_sources: set[str] = set()
    if target in {"SSRVPN_MacOS", "SSRVPN_Windows"}:
        shared_lib = target_root.parent / "packages" / "ssrvpn_shared" / "lib"
        dependency_sources: set[str] = set()
        if shared_lib.is_dir():
            for path in sorted(shared_lib.rglob("*.dart")):
                dependency_relative = _normalise_source(
                    str(path.relative_to(shared_lib))
                )
                canonical = (
                    "../packages/ssrvpn_shared/lib/" + dependency_relative
                )
                dependency_sources.add(canonical)

        for text in sources.values():
            for match in _code_directive_matches(_PART_DIRECTIVE, text):
                uri = match.group(1)
                prefix = "package:ssrvpn_shared/"
                if not uri.startswith(prefix):
                    continue
                dependency_relative = _normalise_relative_source_path(
                    uri.removeprefix(prefix)
                )
                if dependency_relative is None:
                    continue
                canonical = (
                    "../packages/ssrvpn_shared/lib/" + dependency_relative
                )
                physical = shared_lib / dependency_relative
                if canonical not in dependency_sources or not physical.is_file():
                    continue
                part_text = physical.read_text(encoding="utf-8", errors="ignore")
                if physical.name.endswith(_GENERATED_SUFFIXES) or _has_generated_header(
                    part_text
                ):
                    continue
                included_external_parts.add(canonical)

        ignored_dependency_sources = dependency_sources - included_external_parts

    return ProductionSourceManifest(
        included=frozenset(included),
        included_external_parts=frozenset(included_external_parts),
        ignored_dependency_sources=frozenset(ignored_dependency_sources),
        excluded_generated=frozenset(generated),
        excluded_external_parts=frozenset(external_parts),
        excluded_non_coverable=frozenset(non_coverable),
    )


def read_lcov(path: Path) -> LcovSummary:
    records: list[LcovRecord] = []
    source: str | None = None
    summary_fields: dict[str, list[str]] = {"LF": [], "LH": []}
    line_hits: dict[int, int] = {}
    saw_da = False
    invalid_da = False

    def finish_record() -> None:
        nonlocal source, summary_fields, line_hits, saw_da, invalid_da
        if source is not None:
            found = len(line_hits)
            hit = sum(1 for count in line_hits.values() if count > 0)
            summary_issues: list[str] = []
            for field, expected in (("LF", found), ("LH", hit)):
                values = summary_fields[field]
                if not values:
                    summary_issues.append(f"missing {field}")
                    continue
                if len(values) != 1:
                    summary_issues.append(f"duplicate {field}")
                    continue

                raw_value = values[0]
                if not raw_value.isascii() or not raw_value.isdigit():
                    summary_issues.append(f"invalid {field}")
                    continue
                try:
                    declared = int(raw_value)
                except ValueError:
                    summary_issues.append(f"invalid {field}")
                    continue
                if declared != expected:
                    summary_issues.append(
                        f"{field}/DA mismatch: declared {declared}, computed {expected}"
                    )
            records.append(
                LcovRecord(
                    source,
                    found,
                    hit,
                    saw_da=saw_da,
                    valid_da=saw_da and not invalid_da and bool(line_hits),
                    summary_error="; ".join(summary_issues) or None,
                    line_hits=tuple(sorted(line_hits.items())),
                )
            )
        source = None
        summary_fields = {"LF": [], "LH": []}
        line_hits = {}
        saw_da = False
        invalid_da = False

    try:
        lcov_text = path.read_text(encoding="utf-8", errors="strict")
    except UnicodeDecodeError:
        return LcovSummary(
            found=0,
            hit=0,
            file_counts={},
            records=(),
            errors=("LCOV is not valid UTF-8",),
        )

    for raw_line in lcov_text.splitlines():
        if raw_line.startswith("SF:"):
            finish_record()
            source = _normalise_source(raw_line.split(":", 1)[1])
        elif raw_line.startswith("DA:") and source is not None:
            saw_da = True
            fields = raw_line.split(":", 1)[1].split(",")
            if len(fields) not in (2, 3) or (
                len(fields) == 3
                and (not fields[2] or any(char.isspace() for char in fields[2]))
            ):
                invalid_da = True
                continue
            if not _is_ascii_decimal(fields[0]) or not _is_ascii_decimal(fields[1]):
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
        elif raw_line.startswith("LF:") and source is not None:
            summary_fields["LF"].append(raw_line.split(":", 1)[1])
        elif raw_line.startswith("LH:") and source is not None:
            summary_fields["LH"].append(raw_line.split(":", 1)[1])
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
        summary_errors = sorted(
            {
                record.summary_error
                for record in source_records
                if record.summary_error is not None
            }
        )
        if has_summary_only or has_invalid_da or summary_errors:
            file_counts[record_source] = (0, 0)
            kinds: list[str] = []
            if has_summary_only:
                kinds.append("summary-only")
            if has_invalid_da:
                kinds.append("invalid DA")
            if summary_errors:
                kinds.append(f"invalid LF/LH ({'; '.join(summary_errors)})")
            kind = "/".join(kinds)
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
    if record.summary_error is not None:
        return FileCoverage(
            relative_path,
            0,
            0,
            threshold,
            error=(
                "canonical LCOV record has invalid LF/LH summary: "
                f"{record.summary_error}"
            ),
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
    found = summary.found
    hit = summary.hit
    total_errors = list(summary.errors)
    if target_root is not None:
        manifest = discover_production_sources(target_root, target)
        root_source = _normalise_source(str(target_root.resolve()))
        dependency_root_source = _normalise_source(
            str(
                (
                    target_root.parent
                    / "packages"
                    / "ssrvpn_shared"
                    / "lib"
                ).resolve()
            )
        )
        included_sources = manifest.included | manifest.included_external_parts
        records_by_manifest_source: dict[str, set[str]] = {}
        excluded = (
            manifest.excluded_generated
            | manifest.excluded_external_parts
            | manifest.excluded_non_coverable
        )

        for source in summary.file_counts:
            candidate: str | None = None
            if source == "lib" or source.startswith("lib/"):
                candidate = source
            elif source.startswith("../packages/ssrvpn_shared/lib/"):
                candidate = source
            elif source.startswith(f"{root_source}/"):
                candidate = source.removeprefix(f"{root_source}/")
            elif source.startswith(f"{dependency_root_source}/"):
                candidate = (
                    "../packages/ssrvpn_shared/lib/"
                    + source.removeprefix(f"{dependency_root_source}/")
                )

            if candidate in excluded:
                continue
            if candidate in manifest.ignored_dependency_sources:
                continue
            if candidate not in included_sources:
                total_errors.append(
                    f"LCOV source outside production source manifest: {source}"
                )
                continue
            records_by_manifest_source.setdefault(candidate, set()).add(source)

        manifest_counts: dict[str, tuple[int, int]] = {}
        for relative in sorted(included_sources):
            raw_sources = records_by_manifest_source.get(relative, set())
            if not raw_sources:
                total_errors.append(
                    f"production source missing from LCOV: {relative}"
                )
                continue
            if len(raw_sources) != 1:
                total_errors.append(
                    f"multiple LCOV aliases for production source: {relative}"
                )
                manifest_counts[relative] = (0, 0)
                continue
            manifest_counts[relative] = summary.file_counts[next(iter(raw_sources))]

        found = sum(counts[0] for counts in manifest_counts.values())
        hit = sum(counts[1] for counts in manifest_counts.values())

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
        found=found,
        hit=hit,
        total_threshold=total_threshold,
        critical_files=tuple(critical_files),
        total_errors=tuple(dict.fromkeys(total_errors)),
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
