"""Qualification orchestration: strict source gate, conversion, manifest.

The order is fixed: ``source -> validate -> PASS or FAIL -> convert only after
PASS``. The manifest is written even on failure, with the exact failure
reasons, so a rejected dataset leaves recoverable evidence instead of a silent
partial output.
"""

from __future__ import annotations

import csv
import hashlib
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from zoneinfo import ZoneInfo

from .canonical import sha256_file
from .csv_source import (
    CsvSourceConfig,
    QualificationFailure,
    SourceQualification,
    convert_source,
    qualify_source,
    resolve_csv_layout,
)
from .identity import RuntimeIdentityError, load_runtime_identity
from .lean_native import NativeConversionError, NativeLeanTickLayout, NativeTickWriter
from .market_hours import (
    MarketHoursDatabaseError,
    ResolvedMarketHours,
    SessionEvaluator,
    load_market_hours,
)
from .replay import MANIFEST_CONTRACT, build_expectation, semantic_digest_line_format
from .transactions import OutputTransaction, OutputTransactionError

ARTIFACTS_DIRECTORY = "marketlab-qualification"
MANIFEST_NAME = "qualification-manifest.json"
EXPECTATION_NAME = "replay-expectation.json"
RECORD_NAME = "qualification-record.json"
CONTRACT = MANIFEST_CONTRACT


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
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def repository_identity(start_path: Path) -> dict:
    """Records the checkout identity that holds both the converter and the engine.

    This is source provenance only: the actual runtime binary identity is
    recorded by the probe from the assemblies it executes.
    """
    root = repository_root(start_path)
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


def repository_root(start: Path) -> Path | None:
    """Returns the enclosing Git worktree root, or None outside a checkout."""
    current = Path(start).resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".git").exists():
            return candidate
    return None


def _hash_file(path: Path) -> str | None:
    try:
        return sha256_file(path)
    except OSError:
        return None


def _existing_generation_outputs(data_folder: Path, native_layout: NativeLeanTickLayout) -> list[Path]:
    """Every artifact of a previous qualification generation in this data folder."""
    outputs = [
        candidate
        for candidate in (
            manifest_path(data_folder),
            expectation_path(data_folder),
            record_path(data_folder),
        )
        if candidate.is_file()
    ]
    tick_directory = data_folder / native_layout.relative_directory
    if tick_directory.is_dir():
        outputs.extend(sorted(tick_directory.glob("*_quote.zip")))
    return outputs


def _register_record_invalidation(data_folder: Path, transaction: OutputTransaction) -> None:
    """A replaced qualification invalidates the record that certified the old manifest."""
    record = record_path(data_folder)
    if record.is_file():
        transaction.register_removal(record)


def _previous_recorded_hashes(data_folder: Path) -> dict[str, str] | None:
    """Recorded partition hashes of a usable previous MarketLab manifest, or None."""
    manifest_file = manifest_path(data_folder)
    try:
        manifest = json.loads(manifest_file.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(manifest, dict) or manifest.get("contract") != CONTRACT:
        return None
    native = manifest.get("native")
    if not isinstance(native, dict):
        return None
    partitions = native.get("partitions")
    if not isinstance(partitions, list):
        return None
    recorded: dict[str, str] = {}
    for artifact in partitions:
        if not isinstance(artifact, dict):
            return None
        relative = artifact.get("zip_relative_path")
        digest = artifact.get("zip_sha256")
        if not isinstance(relative, str) or not isinstance(digest, str) or len(digest) != 64:
            return None
        recorded[relative.replace("\\", "/")] = digest
    return recorded


def _snapshot_native_partitions(
    data_folder: Path, native_layout: NativeLeanTickLayout
) -> tuple[dict[Path, str], list[Path]]:
    """Splits existing native partitions into owned (path -> hash) and foreign files.

    Ownership requires the current manifest to list the partition with a
    matching SHA-256. Without a usable MarketLab manifest every existing
    partition is foreign, so ``--force`` can never delete or replace native
    history this tool did not create. Unreadable files are treated as foreign
    (fail closed) instead of escaping the controlled contract.
    """
    tick_directory = data_folder / native_layout.relative_directory
    if not tick_directory.is_dir():
        return {}, []
    existing = [
        candidate
        for candidate in sorted(tick_directory.glob("*_quote.zip"))
        if len(candidate.name) >= 8 and candidate.name[:8].isdigit()
    ]
    if not existing:
        return {}, []
    recorded = _previous_recorded_hashes(data_folder) or {}
    owned: dict[Path, str] = {}
    foreign: list[Path] = []
    for candidate in existing:
        expected = recorded.get(f"{native_layout.relative_directory}/{candidate.name}")
        if expected is None:
            foreign.append(candidate)
            continue
        try:
            actual = sha256_file(candidate)
        except OSError:
            foreign.append(candidate)
            continue
        if actual != expected:
            foreign.append(candidate)
        else:
            owned[candidate] = actual
    return owned, foreign


class NativePartitionSetChanged(Exception):
    """A native partition changed between the ownership check and publication."""


def _revalidate_native_partitions(
    owned: dict[Path, str], new_partition_paths: list[Path]
) -> None:
    """Rechecks every path a destructive commit will touch, immediately before it.

    New-generation paths that already exist must be owned with an unchanged
    hash; owned paths being removed must still exist with an unchanged hash. A
    file that appeared or changed since the ownership snapshot fails closed.
    """
    destructive = [path for path in new_partition_paths if path.exists()]
    destructive.extend(path for path in owned if path not in set(new_partition_paths))
    for path in destructive:
        expected = owned.get(path)
        if expected is None:
            raise NativePartitionSetChanged(
                f"a foreign native partition appeared before publication: {path}"
            )
        try:
            actual = sha256_file(path)
        except OSError as error:
            raise NativePartitionSetChanged(
                f"a native partition became unreadable before publication: {path}: {error}"
            ) from error
        if actual != expected:
            raise NativePartitionSetChanged(
                f"a native partition changed before publication: {path}"
            )


def converter_source_identity(start_path: Path) -> dict:
    """Hashes the actual converter Python sources, dirty checkout included.

    ``head_sha`` alone does not identify a modified working tree; this aggregate
    (and the per-file hashes) bind the exact converter source that produced a
    qualification manifest.
    """
    package = Path(start_path).resolve().parent
    files = {path.name: sha256_file(path) for path in sorted(package.glob("*.py"))}
    digest = hashlib.sha256()
    for name in sorted(files):
        digest.update(f"{name}:{files[name]}\n".encode("utf-8"))
    return {
        "file_count": len(files),
        "files": files,
        "aggregate_sha256": digest.hexdigest(),
    }


def _register_generation_cleanup(
    data_folder: Path,
    transaction: OutputTransaction,
    owned_partitions: set[Path],
) -> None:
    """A forced failed replacement clears the superseded artifacts it owns."""
    for candidate in (expectation_path(data_folder), record_path(data_folder)):
        if candidate.is_file():
            transaction.register_removal(candidate)
    for candidate in sorted(owned_partitions):
        transaction.register_removal(candidate)


class SourceIdentityChanged(Exception):
    """The source bytes changed between qualification and conversion."""


def run_qualification(
    source_path: Path,
    data_folder: Path,
    config: CsvSourceConfig,
    symbol: str = "XAUUSD",
    market: str = "oanda",
    security_type: str = "Cfd",
    force: bool = False,
) -> QualificationOutcome:
    """Validates the source, converts only after PASS, and writes the manifest.

    Qualification generations are coherent: a failing first run publishes only a
    failure manifest; ``force`` replaces the previous generation atomically and
    invalidates its record; a forced failing replacement clears the superseded
    expectation, record and native partitions. Output folders inside the Git
    worktree are refused because ``force`` can remove stale native partitions.
    """
    source_path = Path(source_path).resolve()
    data_folder = Path(data_folder).resolve()

    if not source_path.is_file():
        return QualificationOutcome(2, [f"SourceFileNotFound: {source_path}"], None, None)
    if not data_folder.is_dir():
        return QualificationOutcome(2, [f"DataFolderNotFound: {data_folder}"], None, None)

    worktree_root = repository_root(Path(__file__))
    if worktree_root is not None:
        try:
            data_folder.relative_to(worktree_root)
            return QualificationOutcome(
                2,
                [
                    "DataFolderInsideRepository: "
                    f"{data_folder} is inside the Git worktree {worktree_root}; "
                    "qualification outputs and native partitions must stay outside the repository"
                ],
                None,
                None,
            )
        except ValueError:
            pass

    symbol_properties = data_folder / "symbol-properties" / "symbol-properties-database.csv"
    if not symbol_properties.is_file():
        return QualificationOutcome(
            2,
            [f"SymbolPropertiesDatabaseMissing: {symbol_properties}"],
            None,
            None,
        )

    try:
        source_sha256 = sha256_file(source_path)
        source_size = source_path.stat().st_size
    except OSError as error:
        return QualificationOutcome(2, [f"SourceFileUnreadable: {error}"], None, None)

    try:
        hours, _ = load_market_hours(data_folder, security_type, market, symbol)
        data_zone = ZoneInfo(hours.data_time_zone)
        session_evaluator = SessionEvaluator(hours)
    except MarketHoursDatabaseError as error:
        return QualificationOutcome(2, [f"MarketHoursDatabaseUnusable: {error}"], None, None)
    except Exception as error:  # noqa: BLE001 - timezone resolution failure is a configuration error
        return QualificationOutcome(2, [f"DataTimeZoneUnusable: {error}"], None, None)

    try:
        runtime_identity = load_runtime_identity(data_folder, symbol, market, security_type)
    except RuntimeIdentityError as error:
        return QualificationOutcome(2, [f"RuntimeIdentityUnusable: {error}"], None, None)

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

    identity = repository_identity(Path(__file__))
    try:
        identity["converter_source"] = converter_source_identity(Path(__file__))
    except OSError as error:
        return QualificationOutcome(2, [f"ConverterSourceUnreadable: {error}"], None, None)
    native_layout = NativeLeanTickLayout(symbol=symbol, market=market, security_type=security_type)

    if not force:
        existing_outputs = _existing_generation_outputs(data_folder, native_layout)
        if existing_outputs:
            return QualificationOutcome(
                2,
                [
                    "OutputsExistWithoutForce: an existing qualification generation is present "
                    f"({len(existing_outputs)} file(s), first: {existing_outputs[0]}); "
                    "pass --force to replace it"
                ],
                None,
                None,
            )

    owned_partitions: dict[Path, str] = {}
    if force:
        owned_partitions, foreign_partitions = _snapshot_native_partitions(
            data_folder, native_layout
        )
        if foreign_partitions:
            names = ", ".join(candidate.name for candidate in foreign_partitions[:5])
            if len(foreign_partitions) > 5:
                names += ", ..."
            return QualificationOutcome(
                2,
                [
                    "ForeignNativePartitions: the tick directory contains native partitions the "
                    f"current MarketLab manifest does not own ({names}); --force will not delete "
                    "data it did not create. Use a clean/dedicated research data folder"
                ],
                None,
                None,
            )

    try:
        qualification = qualify_source(
            source_path, layout, config, data_zone, source_zone, session_evaluator
        )
    except (UnicodeDecodeError, LookupError, csv.Error, OSError) as error:
        return QualificationOutcome(
            2,
            [f"SourceUnreadable: the source could not be read during qualification: {error}"],
            None,
            None,
        )

    try:
        source_sha_after = sha256_file(source_path)
    except OSError as error:
        return QualificationOutcome(
            2,
            [f"SourceUnreadable: the source could not be re-read after qualification: {error}"],
            None,
            None,
        )
    if source_sha_after != source_sha256:
        return QualificationOutcome(
            2,
            [
                "SourceChangedDuringQualification: the source file changed while it was being "
                "qualified; no manifest or native data was published"
            ],
            None,
            None,
        )

    failures: list[str] = []
    if not qualification.source_qualification_passed:
        failures.append("SourceRejectedRows")
    if not qualification.timestamp_precision_passed:
        failures.append("SourcePrecisionExceedsLeanTickFormat")
    if not qualification.decimal_parity_passed:
        failures.append("SourcePriceExceedsLeanDecimalFormat")

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
                if sha256_file(source_path) != source_sha256:
                    raise SourceIdentityChanged(
                        "the source file changed between qualification and conversion; "
                        "nothing was published"
                    )
                if force:
                    _register_stale_partition_removals(
                        partitions, transaction, set(owned_partitions)
                    )
                    _register_record_invalidation(data_folder, transaction)
                manifest = _build_manifest(
                    qualification=qualification,
                    hours=hours,
                    native_layout=native_layout,
                    source_path=source_path,
                    source_sha256=source_sha256,
                    source_size=source_size,
                    data_folder=data_folder,
                    identity=identity,
                    runtime_identity=runtime_identity,
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
                if force:
                    _revalidate_native_partitions(
                        owned_partitions,
                        [native_layout.zip_path(data_folder, artifact.partition) for artifact in partitions],
                    )
                transaction.commit()
                published = True
        except SourceIdentityChanged as error:
            return QualificationOutcome(
                2,
                [f"SourceChangedDuringQualification: {error}"],
                None,
                None,
            )
        except NativePartitionSetChanged as error:
            return QualificationOutcome(2, [f"NativePartitionSetChanged: {error}"], None, None)
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
            source_sha256=source_sha256,
            source_size=source_size,
            data_folder=data_folder,
            identity=identity,
            runtime_identity=runtime_identity,
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
                if force:
                    _register_generation_cleanup(
                        data_folder, transaction, set(owned_partitions)
                    )
                    _revalidate_native_partitions(owned_partitions, [])
                transaction.commit()
        except NativePartitionSetChanged as error:
            return QualificationOutcome(2, [f"NativePartitionSetChanged: {error}"], None, None)
        except OutputTransactionError as error:
            return QualificationOutcome(2, [f"ManifestNotWritten: {error}"], None, None)

    return QualificationOutcome(
        exit_code=1 if failures else 0,
        failures=failures,
        manifest=manifest,
        manifest_path=str(manifest_path(data_folder)),
    )


def _register_stale_partition_removals(
    partitions,
    transaction: OutputTransaction,
    owned_partitions: set[Path],
) -> None:
    """With force: remove owned partitions the new qualification does not describe."""
    current_days = {artifact.partition.strftime("%Y%m%d") for artifact in partitions}
    for candidate in sorted(owned_partitions):
        day = candidate.name[:8]
        if day not in current_days:
            transaction.register_removal(candidate)


def _build_manifest(
    qualification: SourceQualification,
    hours: ResolvedMarketHours,
    native_layout: NativeLeanTickLayout,
    source_path: Path,
    source_sha256: str,
    source_size: int,
    data_folder: Path,
    identity: dict,
    runtime_identity: dict | None,
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
            "sha256": source_sha256,
            "size_bytes": source_size,
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
            "lean_checkout_git_sha": identity.get("head_sha"),
            "converter_checkout": identity,
            "runtime_identity_note": (
                "lean_checkout_git_sha is source provenance; the replay probe records the "
                "SHA-256 of the assemblies it actually executes under probe.runtime.assemblies, "
                "and the driver records the runtime binaries it launches under runtime_binaries"
            ),
            "converter_source": identity.get("converter_source"),
            "data_time_zone": hours.data_time_zone,
            "exchange_time_zone": hours.exchange_time_zone,
            "market_hours_database": hours.describe(),
            "symbol_properties_database": {
                "path": str(symbol_properties),
                "sha256": _hash_file(symbol_properties),
            },
            "runtime_identity": runtime_identity,
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
            "complete": qualification.spread_statistics_complete,
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
