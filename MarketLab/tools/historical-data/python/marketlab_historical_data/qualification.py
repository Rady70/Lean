"""Qualification orchestration: strict source gate, conversion, manifest.

The order is fixed: ``source -> validate -> PASS or FAIL -> convert only after
PASS``. The manifest is written even on failure, with the exact failure
reasons, so a rejected dataset leaves recoverable evidence instead of a silent
partial output.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo

from .canonical import sha256_hex
from .csv_source import (
    CsvSourceConfig,
    QualificationFailure,
    SourceQualification,
    convert_source,
    qualify_source,
    resolve_csv_layout,
)
from .lean_native import NativeConversionError, NativeLeanTickLayout, NativeTickWriter
from .market_hours import (
    MarketHoursDatabaseError,
    ResolvedMarketHours,
    SessionEvaluator,
    load_market_hours,
)
from .replay import build_expectation, semantic_digest_line_format
from .transactions import OutputTransaction, OutputTransactionError

ARTIFACTS_DIRECTORY = "marketlab-qualification"
MANIFEST_NAME = "qualification-manifest.json"
EXPECTATION_NAME = "replay-expectation.json"
RECORD_NAME = "qualification-record.json"
CONTRACT = "marketlab-historical-data-qualification-v1"


@dataclass
class QualificationOutcome:
    exit_code: int
    failures: list[str]
    manifest: dict | None
    manifest_path: str | None


def artifacts_directory(data_folder: Path) -> Path:
    return Path(data_folder) / ARTIFACTS_DIRECTORY


def manifest_path(data_folder: Path) -> Path:
    return artifacts_directory(data_folder) / MANIFEST_NAME


def expectation_path(data_folder: Path) -> Path:
    return artifacts_directory(data_folder) / EXPECTATION_NAME


def record_path(data_folder: Path) -> Path:
    return artifacts_directory(data_folder) / RECORD_NAME


def dump_json(payload: dict) -> str:
    return json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def load_json(path: Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def repository_identity(start_path: Path) -> dict:
    """Records the checkout identity that holds both the converter and the engine."""
    root = None
    current = Path(start_path).resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".git").exists():
            root = candidate
            break
    identity = {"root": str(root) if root else None, "head_sha": None, "branch": None, "dirty": None}
    if root is None:
        return identity
    try:
        head = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        branch = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        status = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if head.returncode == 0:
            identity["head_sha"] = head.stdout.strip()
        if branch.returncode == 0:
            identity["branch"] = branch.stdout.strip()
        if status.returncode == 0:
            identity["dirty"] = bool(status.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return identity


def _hash_file(path: Path) -> str | None:
    try:
        return sha256_hex(Path(path).read_bytes())
    except OSError:
        return None


def run_qualification(
    source_path: Path,
    data_folder: Path,
    config: CsvSourceConfig,
    symbol: str = "XAUUSD",
    market: str = "oanda",
    security_type: str = "Cfd",
    force: bool = False,
) -> QualificationOutcome:
    """Validates the source, converts only after PASS, and writes the manifest."""
    source_path = Path(source_path).resolve()
    data_folder = Path(data_folder).resolve()

    if not source_path.is_file():
        return QualificationOutcome(2, [f"SourceFileNotFound: {source_path}"], None, None)
    if not data_folder.is_dir():
        return QualificationOutcome(2, [f"DataFolderNotFound: {data_folder}"], None, None)

    try:
        hours, _ = load_market_hours(data_folder, security_type, market, symbol)
        data_zone = ZoneInfo(hours.data_time_zone)
        session_evaluator = SessionEvaluator(hours)
    except MarketHoursDatabaseError as error:
        return QualificationOutcome(2, [f"MarketHoursDatabaseUnusable: {error}"], None, None)
    except Exception as error:  # noqa: BLE001 - timezone resolution failure is a configuration error
        return QualificationOutcome(2, [f"DataTimeZoneUnusable: {error}"], None, None)

    source_zone = None
    if config.source_timezone:
        try:
            source_zone = ZoneInfo(config.source_timezone)
        except Exception as error:  # noqa: BLE001 - reported as a configuration error
            return QualificationOutcome(
                2, [f"SourceTimezoneUnknown: {config.source_timezone!r}: {error}"], None, None
            )

    try:
        layout = resolve_csv_layout(source_path, config)
    except QualificationFailure as error:
        return QualificationOutcome(2, [f"SourceLayoutUnusable: {error}"], None, None)

    qualification = qualify_source(
        source_path, layout, config, data_zone, source_zone, session_evaluator
    )

    failures: list[str] = []
    if not qualification.source_qualification_passed:
        failures.append("SourceRejectedRows")
    if not qualification.timestamp_precision_passed:
        failures.append("SourcePrecisionExceedsLeanTickFormat")
    if not qualification.decimal_parity_passed:
        failures.append("SourcePriceExceedsLeanDecimalFormat")

    identity = repository_identity(Path(__file__))
    native_layout = NativeLeanTickLayout(symbol=symbol, market=market, security_type=security_type)

    partitions = ()
    conversion_status = "PASS" if not failures else "NOT_RUN"
    conversion_error = None
    published = False

    if not failures:
        try:
            with OutputTransaction(allow_overwrite=force) as transaction:
                writer = NativeTickWriter(data_folder, native_layout, data_zone, transaction)
                convert_source(
                    source_path,
                    layout,
                    config,
                    source_zone,
                    writer,
                    qualification.counters.accepted_row_count,
                )
                partitions = writer.finish()
                manifest = _build_manifest(
                    qualification=qualification,
                    hours=hours,
                    native_layout=native_layout,
                    source_path=source_path,
                    data_folder=data_folder,
                    identity=identity,
                    conversion_status="PASS",
                    conversion_error=None,
                    partitions=partitions,
                    failures=failures,
                    symbol=symbol,
                    market=market,
                    security_type=security_type,
                )
                expectation = build_expectation(manifest)
                transaction.stage_text(manifest_path(data_folder), dump_json(manifest))
                transaction.stage_text(expectation_path(data_folder), dump_json(expectation))
                transaction.commit()
                published = True
        except (
            QualificationFailure,
            NativeConversionError,
            OutputTransactionError,
            OSError,
            ValueError,
        ) as error:
            conversion_status = "FAIL"
            conversion_error = str(error)
            failures.append("NativeLeanConversionFailed")

    if not published:
        manifest = _build_manifest(
            qualification=qualification,
            hours=hours,
            native_layout=native_layout,
            source_path=source_path,
            data_folder=data_folder,
            identity=identity,
            conversion_status=conversion_status,
            conversion_error=conversion_error,
            partitions=(),
            failures=failures,
            symbol=symbol,
            market=market,
            security_type=security_type,
        )
        try:
            with OutputTransaction(allow_overwrite=force) as transaction:
                transaction.stage_text(manifest_path(data_folder), dump_json(manifest))
                transaction.commit()
        except OutputTransactionError as error:
            return QualificationOutcome(2, [f"ManifestNotWritten: {error}"], None, None)

    return QualificationOutcome(
        exit_code=1 if failures else 0,
        failures=failures,
        manifest=manifest,
        manifest_path=str(manifest_path(data_folder)),
    )


def _build_manifest(
    qualification: SourceQualification,
    hours: ResolvedMarketHours,
    native_layout: NativeLeanTickLayout,
    source_path: Path,
    data_folder: Path,
    identity: dict,
    conversion_status: str,
    conversion_error: str | None,
    partitions,
    failures: list[str],
    symbol: str,
    market: str,
    security_type: str,
) -> dict:
    counters = qualification.counters
    per_day_converted = {artifact.partition: artifact.row_count for artifact in partitions}
    digest_status = "evaluated"
    if qualification.source_semantic_digest is None:
        if counters.rejected_row_count > 0:
            digest_status = "not_evaluated_source_rejected_rows"
        elif counters.sub_millisecond_row_count > 0:
            digest_status = "not_evaluated_sub_millisecond_precision"
        else:
            digest_status = "not_evaluated"
    symbol_properties = data_folder / "symbol-properties" / "symbol-properties-database.csv"
    per_partition_semantic = {
        day: {
            "accepted_row_count": counters.per_partition_counts[day],
            "semantic_digest": "sha256:" + counters.per_partition_digests[day].hexdigest(),
        }
        for day in sorted(counters.per_partition_digests)
    }
    return {
        "contract": CONTRACT,
        "source": {
            "path": str(source_path),
            "sha256": _hash_file(source_path),
            "size_bytes": source_path.stat().st_size,
            "encoding": qualification.config.encoding,
            "delimiter": qualification.layout.delimiter,
            "columns": {
                "timestamp_mode": qualification.layout.timestamp_mode,
                "timestamp": qualification.layout.timestamp_column,
                "date": qualification.layout.date_column,
                "time": qualification.layout.time_column,
                "bid": qualification.layout.bid_column,
                "ask": qualification.layout.ask_column,
            },
            "config": qualification.config.describe(),
            "timestamp_contract": qualification.timestamp_contract.describe(),
        },
        "lean": {
            "symbol": symbol,
            "market": market,
            "security_type": security_type,
            "data_folder": str(data_folder),
            "converter_git_sha": identity.get("head_sha"),
            "lean_git_sha": identity.get("head_sha"),
            "converter_checkout": identity,
            "data_time_zone": hours.data_time_zone,
            "exchange_time_zone": hours.exchange_time_zone,
            "market_hours_database": hours.describe(),
            "symbol_properties_database": {
                "path": str(symbol_properties),
                "sha256": _hash_file(symbol_properties),
            },
            "native_layout": native_layout.describe(),
        },
        "counts": {
            "raw_row_count": counters.raw_row_count,
            "accepted_row_count": counters.accepted_row_count,
            "rejected_row_count": counters.rejected_row_count,
            "rejected_row_reasons": dict(sorted(counters.rejection_reasons.items())),
            "rejected_row_samples": [
                {
                    "row_number": sample.row_number,
                    "reason": sample.reason,
                    "message": sample.message,
                }
                for sample in counters.rejection_samples
            ],
            "out_of_order_count": counters.out_of_order_count,
            "duplicate_timestamp_count": counters.duplicate_timestamp_count,
            "sub_millisecond_row_count": counters.sub_millisecond_row_count,
            "same_lean_millisecond_collision_count": counters.same_lean_millisecond_collision_count,
            "same_lean_millisecond_collision_groups": counters.same_lean_millisecond_collision_groups,
            "maximum_rows_per_lean_millisecond": counters.maximum_rows_per_lean_millisecond,
            "converted_row_count": sum(artifact.row_count for artifact in partitions),
            "first_canonical_utc": qualification.first_canonical_utc,
            "last_canonical_utc": qualification.last_canonical_utc,
        },
        "spread": {
            "units": "price units",
            "note": (
                "exact-decimal diagnostics; binary floating point is not used for conversion "
                "or comparison"
            ),
            "min": qualification.spread_min,
            "max": qualification.spread_max,
            "mean": qualification.spread_mean,
            "median": qualification.spread_median,
        },
        "per_day": {
            "accepted": {day: counters.per_day_accepted_counts[day] for day in sorted(counters.per_day_accepted_counts)},
            "converted": {
                artifact.partition.isoformat(): artifact.row_count
                for artifact in sorted(partitions, key=lambda item: item.partition)
            },
        },
        "session_preview": (
            {
                "preview_exact": qualification.session_preview.preview_exact,
                "session_eligible_rows": qualification.session_preview.session_eligible_rows,
                "session_excluded_rows": qualification.session_preview.session_excluded_rows,
                "note": (
                    "offline diagnostic from the resolved market-hours entry; the actual LEAN "
                    "replay is the authority"
                ),
            }
            if qualification.session_preview is not None
            else None
        ),
        "semantic": {
            "line_format": semantic_digest_line_format(),
            "digest_algorithm": "sha256",
            "ordered_source_semantic_digest": qualification.source_semantic_digest,
            "digest_status": digest_status,
            "per_partition": per_partition_semantic,
        },
        "native": {
            "layout": native_layout.describe(),
            "partitions": [artifact.describe() for artifact in partitions],
            "uncompressed_member_hashes": {
                artifact.partition.isoformat(): artifact.member_sha256 for artifact in partitions
            },
            "zip_container_sha256": {
                artifact.partition.isoformat(): artifact.zip_sha256 for artifact in partitions
            },
            "converted_row_count": sum(artifact.row_count for artifact in partitions),
        },
        "qualification": {
            "source_qualification": "PASS"
            if qualification.source_qualification_passed
            else "FAIL",
            "native_lean_timestamp_parity": "PASS"
            if qualification.timestamp_precision_passed
            else "FAIL",
            "native_price_decimal_parity": "PASS"
            if qualification.decimal_parity_passed
            else "FAIL",
            "native_conversion": conversion_status,
            "native_replay": "PENDING" if conversion_status == "PASS" else "NOT_RUN",
            "converted_row_count": sum(artifact.row_count for artifact in partitions),
            "conversion_error": conversion_error,
            "overall_qualification": "FAIL" if failures else "PENDING_NATIVE_REPLAY",
            "failure_reasons": list(failures),
        },
    }
