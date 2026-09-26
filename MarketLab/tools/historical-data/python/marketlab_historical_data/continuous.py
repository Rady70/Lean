"""Continuous LEAN-native history composition and its replay qualification.

PR 1 qualifies one source file per run and writes one native LEAN data folder
per run. This module turns the already-qualified monthly native partitions into
one continuous LEAN data folder and re-proves its delivery with the same probe
and the same equality contract, without re-converting anything:

- the 90 month records must still aggregate into a valid full-history summary
  (contiguous, ordered, singleton identity, accepted = converted = delivered =
  processed, zero rejected rows and zero session difference);
- every daily partition zip is copied byte for byte and its SHA-256 must equal
  the hash its month manifest recorded, so the previously qualified native
  inputs are used, never re-derived;
- the continuous expectation (the probe's input) is rebuilt from the composed
  partitions: the global ordered semantic digest is recomputed over the
  concatenated rows with continuous ordinals, and it must reproduce the
  qualified first/last boundaries and total; the per-partition expectations are
  the recorded monthly evidence, unchanged;
- the composed data folder carries the same derived always-open runtime
  identity and, when supplied, the qualified source-derived session map.

The composition file is manifest-shaped (the same sections the single-file
manifests use) plus a ``composition`` block, so the final record is produced by
the established ``build_record`` verification with only the continuous checks
added on top.
"""

from __future__ import annotations

import hashlib
import io
import json
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from .canonical import sha256_file
from .identity import prepare_runtime_identity
from .lean_native import NativeLeanTickLayout
from .qualification import ARTIFACTS_DIRECTORY, dump_json
from .replay import (
    MANIFEST_CONTRACT,
    build_record,
    require_manifest_structure,
)
from .summary import (
    FullHistorySummaryError,
    build_full_history_summary,
    load_qualification_record,
)
from .transactions import OutputTransaction, OutputTransactionError

__all__ = [
    "COMPOSITION_CONTRACT",
    "ContinuousHistoryError",
    "ContinuousOutcome",
    "build_continuous_record",
    "compose_history",
    "composition_path",
    "continuous_record_path",
    "session_map_relative_path",
]

COMPOSITION_CONTRACT = "marketlab-continuous-history-composition-v1"
COMPOSITION_NAME = "continuous-composition.json"
CONTINUOUS_RECORD_NAME = "continuous-qualification-record.json"
EXPECTATION_NAME = "replay-expectation.json"
SESSION_MAP_RELATIVE = Path("marketlab-sessions") / "xauusd-sessions.json"


class ContinuousHistoryError(Exception):
    """The continuous native history cannot be composed or verified."""


class ContinuousOutcome:
    """Result of a composition attempt."""

    def __init__(self, exit_code: int, failures, composition, composition_path):
        self.exit_code = exit_code
        self.failures = list(failures)
        self.composition = composition
        self.composition_path = composition_path


def composition_path(data_folder: Path) -> Path:
    return Path(data_folder) / ARTIFACTS_DIRECTORY / COMPOSITION_NAME


def continuous_record_path(data_folder: Path) -> Path:
    return Path(data_folder) / ARTIFACTS_DIRECTORY / CONTINUOUS_RECORD_NAME


def session_map_relative_path() -> str:
    return SESSION_MAP_RELATIVE.as_posix()


def _sha256_or_none(path: Path) -> str | None:
    try:
        return sha256_file(path)
    except OSError:
        return None


def _deduplicate(values) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            result.append(value)
    return result


def _singleton(sets: dict, name: str) -> str:
    values = sets.get(name)
    if not isinstance(values, list) or len(values) != 1:
        raise ContinuousHistoryError(f"the {name} is not a singleton across the month records: {values}")
    return values[0]


def _build_month_entries(months_root: Path, summary: dict) -> list[dict]:
    """Per-month composition entries plus their validated native partition artifacts."""
    entries: list[dict] = []
    for month_entry in summary["months"]:
        month = month_entry["month"]
        record_path = (
            Path(months_root) / month / "data" / "marketlab-qualification" / "qualification-record.json"
        )
        record = load_qualification_record(record_path)
        manifest = record.get("manifest")
        try:
            require_manifest_structure(manifest)
        except ValueError as error:
            raise ContinuousHistoryError(f"{month}: month manifest is not usable: {error}") from error
        per_partition = manifest["semantic"]["per_partition"]
        per_day = manifest["per_day"]["accepted"]
        artifacts = []
        for artifact in manifest["native"]["partitions"]:
            day = artifact["partition"]
            semantic = per_partition.get(day)
            if not isinstance(semantic, dict):
                raise ContinuousHistoryError(f"{month}: partition {day} has no per-partition evidence")
            if semantic.get("accepted_row_count") != artifact["row_count"]:
                raise ContinuousHistoryError(
                    f"{month}: partition {day} has a row-count disagreement between the native "
                    "artifact and the per-partition evidence"
                )
            if per_day.get(day) != artifact["row_count"]:
                raise ContinuousHistoryError(
                    f"{month}: partition {day} is not consistent with the recorded per-day counts"
                )
            artifacts.append(
                {
                    "month": month,
                    "partition": day,
                    "zip_relative_path": artifact["zip_relative_path"],
                    "zip_sha256": artifact["zip_sha256"],
                    "member_name": artifact.get("member_name"),
                    "member_sha256": artifact.get("member_sha256"),
                    "member_size_bytes": artifact.get("member_size_bytes"),
                    "row_count": artifact["row_count"],
                    "semantic_digest": semantic["semantic_digest"],
                    "first_millisecond": artifact.get("first_millisecond"),
                    "last_millisecond": artifact.get("last_millisecond"),
                }
            )
        entries.append(
            {
                "month": month,
                "source_file_name": month_entry["source_file_name"],
                "source_sha256": month_entry["source_sha256"],
                "source_size_bytes": month_entry["source_size_bytes"],
                "record_sha256": month_entry["record_sha256"],
                "manifest_sha256": month_entry["manifest_sha256"],
                "accepted_row_count": month_entry["accepted_row_count"],
                "partition_count": month_entry["partition_count"],
                "ordered_source_semantic_digest": month_entry["source_semantic_digest"],
                "artifacts": artifacts,
            }
        )
    return entries


def _owned_partitions(data_folder: Path) -> dict[str, str] | None:
    """Partition zips the existing MarketLab composition owns, by file name."""
    path = composition_path(data_folder)
    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict) or payload.get("contract") != MANIFEST_CONTRACT:
        return None
    partitions = (payload.get("native") or {}).get("partitions")
    if not isinstance(partitions, list):
        return None
    owned: dict[str, str] = {}
    for artifact in partitions:
        if not isinstance(artifact, dict):
            return None
        relative = artifact.get("zip_relative_path")
        digest = artifact.get("zip_sha256")
        if not isinstance(relative, str) or not isinstance(digest, str) or len(digest) != 64:
            return None
        owned[Path(relative).name] = digest
    return owned


def _partition_lines(payload: bytes, label: str) -> list[bytes]:
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            names = archive.namelist()
            if len(names) != 1:
                raise ContinuousHistoryError(
                    f"{label}: the native partition must contain exactly one member: {names}"
                )
            content = archive.read(names[0])
    except (zipfile.BadZipFile, OSError) as error:
        raise ContinuousHistoryError(f"{label}: the native partition is not a usable zip: {error}") from error
    if not content:
        raise ContinuousHistoryError(f"{label}: the native partition is empty")
    lines = content.split(b"\n")
    if any(not line for line in lines):
        raise ContinuousHistoryError(f"{label}: the native partition contains an empty row")
    return lines


def _global_digest_line(ordinal: int, day: bytes, millisecond: int, bid: bytes, ask: bytes) -> bytes:
    hour, remainder = divmod(millisecond, 3_600_000)
    minute, remainder = divmod(remainder, 60_000)
    second, fraction = divmod(remainder, 1000)
    return b"%d|%sT%02d:%02d:%02d.%03dZ|%s|%s\n" % (
        ordinal,
        day,
        hour,
        minute,
        second,
        fraction,
        bid,
        ask,
    )


def compose_history(
    months_root: Path,
    data_folder: Path,
    *,
    expected_first_month: str,
    expected_last_month: str,
    source_data_folder: Path,
    session_map: Path | None = None,
    symbol: str = "XAUUSD",
    market: str = "dukascopy",
    security_type: str = "Cfd",
    force: bool = False,
) -> ContinuousOutcome:
    """Composes the already-qualified monthly native partitions into one data folder."""
    months_root = Path(months_root).resolve()
    data_folder = Path(data_folder).resolve()

    try:
        summary = build_full_history_summary(
            months_root,
            expected_first_month=expected_first_month,
            expected_last_month=expected_last_month,
        )
    except FullHistorySummaryError as error:
        return ContinuousOutcome(2, [f"MonthsRootUnusable: {error}"], None, None)
    if summary.get("errors"):
        return ContinuousOutcome(2, [f"MonthRecordsNotConforming: {error}" for error in summary["errors"]], None, None)
    if summary.get("months_fail"):
        return ContinuousOutcome(2, [f"MonthRecordsFailed: {summary['months_fail']} month(s) not PASS"], None, None)

    identity = summary["identity"]
    try:
        record_symbol = _singleton(identity, "symbol_set")
        record_market = _singleton(identity, "market_set")
        record_security_type = _singleton(identity, "security_type_set")
        data_time_zone = _singleton(identity, "data_time_zone_set")
        exchange_time_zone = _singleton(identity, "exchange_time_zone_set")
        market_hours_sha = _singleton(identity, "market_hours_database_sha256_set")
        symbol_properties_sha = _singleton(identity, "symbol_properties_database_sha256_set")
        entry_key = _singleton(identity, "market_hours_entry_key_set")
    except ContinuousHistoryError as error:
        return ContinuousOutcome(2, [f"IdentityNotSingleton: {error}"], None, None)
    if (
        record_symbol != symbol
        or record_market != market
        or record_security_type != security_type
    ):
        return ContinuousOutcome(
            2,
            [
                "IdentityMismatch: the month records qualified "
                f"{record_symbol}/{record_market}/{record_security_type}, not "
                f"{symbol}/{market}/{security_type}"
            ],
            None,
            None,
        )
    if data_time_zone != "UTC" or exchange_time_zone != "UTC":
        return ContinuousOutcome(
            2,
            [
                "IdentityTimezoneUnsupported: continuous composition is qualified only for the "
                f"UTC/UTC identity (records: {data_time_zone}/{exchange_time_zone})"
            ],
            None,
            None,
        )

    try:
        month_entries = _build_month_entries(months_root, summary)
    except (ContinuousHistoryError, FullHistorySummaryError) as error:
        return ContinuousOutcome(2, [str(error)], None, None)
    partitions = [artifact for entry in month_entries for artifact in entry["artifacts"]]
    if not partitions:
        return ContinuousOutcome(2, ["NoQualifiedPartitions: the month records carry no native partitions"], None, None)
    by_day: dict[str, dict] = {}
    duplicates = []
    for artifact in partitions:
        if artifact["partition"] in by_day:
            duplicates.append(artifact["partition"])
        by_day[artifact["partition"]] = artifact
    if duplicates:
        return ContinuousOutcome(
            2,
            ["DuplicateNativePartition: the same date appears in more than one month: " + ", ".join(sorted(set(duplicates)))],
            None,
            None,
        )
    ordered_partitions = sorted(partitions, key=lambda artifact: artifact["partition"])
    if [artifact["partition"] for artifact in ordered_partitions] != [artifact["partition"] for artifact in partitions]:
        return ContinuousOutcome(2, ["PartitionOrderMismatch: partitions are not in month/date order"], None, None)
    total_rows = sum(artifact["row_count"] for artifact in ordered_partitions)
    if total_rows != summary["totals"]["accepted_row_count"]:
        return ContinuousOutcome(
            2,
            [
                f"PartitionRowTotalMismatch: {total_rows} native rows vs "
                f"{summary['totals']['accepted_row_count']} accepted rows"
            ],
            None,
            None,
        )

    layout = NativeLeanTickLayout(symbol=symbol, market=market, security_type=security_type)
    tick_directory = data_folder / layout.relative_directory
    existing_zips = (
        {path.name: path for path in tick_directory.glob("*_quote.zip")}
        if tick_directory.is_dir()
        else {}
    )
    if existing_zips and not force:
        return ContinuousOutcome(
            2,
            [
                "OutputsExistWithoutForce: the data folder already holds native partitions "
                f"({len(existing_zips)} file(s)); pass --force to replace the owned generation"
            ],
            None,
            None,
        )
    owned: dict[str, str] = {}
    if force:
        owned = _owned_partitions(data_folder) or {}
        foreign = []
        for name, path in existing_zips.items():
            digest = owned.get(name)
            if digest is None or _sha256_or_none(path) != digest:
                foreign.append(str(path))
        if foreign:
            return ContinuousOutcome(
                2,
                [
                    "ForeignNativePartitions: the tick directory contains native partitions the "
                    f"previous MarketLab composition does not own ({', '.join(sorted(foreign)[:5])}); "
                    "--force will not delete or replace data it did not create"
                ],
                None,
                None,
            )
    if composition_path(data_folder).exists() and not force:
        return ContinuousOutcome(
            2,
            [f"OutputsExistWithoutForce: {composition_path(data_folder)} already exists"],
            None,
            None,
        )

    session_record = None
    session_bytes = None
    if session_map is not None:
        session_map = Path(session_map)
        if not session_map.is_file():
            return ContinuousOutcome(2, [f"SessionMapNotFound: {session_map}"], None, None)
        session_bytes = session_map.read_bytes()
        recorded_session = {
            "source_path": str(session_map),
            "sha256": hashlib.sha256(session_bytes).hexdigest(),
            "relative_path": session_map_relative_path(),
        }
        target = data_folder / SESSION_MAP_RELATIVE
        if target.is_file():
            if hashlib.sha256(target.read_bytes()).hexdigest() != recorded_session["sha256"] and not force:
                return ContinuousOutcome(
                    2,
                    [f"SessionMapExists: {target} differs from {session_map}; pass --force to replace it"],
                    None,
                    None,
                )
        session_record = recorded_session

    try:
        data_folder.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        return ContinuousOutcome(2, [f"DataFolderUnusable: {error}"], None, None)

    try:
        runtime_identity = prepare_runtime_identity(
            data_folder=data_folder,
            source_data_folder=Path(source_data_folder),
            symbol=symbol,
            market=market,
            security_type=security_type,
            force=force,
        )
    except Exception as error:  # noqa: BLE001 - reported as a controlled outcome
        return ContinuousOutcome(2, [f"RuntimeIdentityUnusable: {error}"], None, None)
    derived_market_hours = runtime_identity["derived_market_hours_database"]["sha256"]
    derived_symbol_properties = runtime_identity["derived_symbol_properties_database"]["sha256"]
    if derived_market_hours != market_hours_sha:
        return ContinuousOutcome(
            2,
            [
                "RuntimeIdentityProvenanceMismatch: the derived market-hours database "
                f"{derived_market_hours} does not match the qualified identity {market_hours_sha}"
            ],
            None,
            None,
        )
    if derived_symbol_properties != symbol_properties_sha:
        return ContinuousOutcome(
            2,
            [
                "RuntimeIdentityProvenanceMismatch: the derived symbol-properties database "
                f"{derived_symbol_properties} does not match the qualified identity "
                f"{symbol_properties_sha}"
            ],
            None,
            None,
        )

    digest = hashlib.sha256()
    ordinal = 0
    computed_first = None
    computed_last = None
    composition_partitions = []
    try:
        with OutputTransaction(allow_overwrite=force) as transaction:
            new_names = {Path(artifact["zip_relative_path"]).name for artifact in ordered_partitions}
            for name, path in existing_zips.items():
                if name not in new_names:
                    transaction.register_removal(path)
            for artifact in ordered_partitions:
                source_zip = months_root / artifact["month"] / "data" / artifact["zip_relative_path"]
                try:
                    payload = source_zip.read_bytes()
                except OSError as error:
                    raise ContinuousHistoryError(
                        f"{artifact['month']}: native partition is unreadable: {source_zip}: {error}"
                    ) from error
                actual = hashlib.sha256(payload).hexdigest()
                if actual != artifact["zip_sha256"]:
                    raise ContinuousHistoryError(
                        f"{artifact['month']}: native partition hash mismatch for "
                        f"{artifact['partition']}: {actual} != {artifact['zip_sha256']}"
                    )
                lines = _partition_lines(payload, f"{artifact['month']}/{artifact['partition']}")
                if len(lines) != artifact["row_count"]:
                    raise ContinuousHistoryError(
                        f"{artifact['month']}: native partition {artifact['partition']} holds "
                        f"{len(lines)} rows, recorded {artifact['row_count']}"
                    )
                day_bytes = artifact["partition"].encode("ascii")
                for line in lines:
                    millisecond_text, bid, ask = line.split(b",", 2)
                    ordinal += 1
                    digest.update(
                        _global_digest_line(ordinal, day_bytes, int(millisecond_text), bid, ask)
                    )
                    if computed_first is None:
                        computed_first = _timestamp_text(artifact["partition"], int(millisecond_text))
                    computed_last = _timestamp_text(artifact["partition"], int(millisecond_text))
                target = data_folder / artifact["zip_relative_path"]
                transaction.stage_bytes(target, payload)
                composition_partitions.append(
                    {
                        "partition": artifact["partition"],
                        "month": artifact["month"],
                        "zip_relative_path": artifact["zip_relative_path"],
                        "zip_sha256": artifact["zip_sha256"],
                        "member_name": artifact["member_name"],
                        "member_sha256": artifact["member_sha256"],
                        "member_size_bytes": artifact["member_size_bytes"],
                        "row_count": artifact["row_count"],
                        "semantic_digest": artifact["semantic_digest"],
                    }
                )
            if ordinal != total_rows:
                raise ContinuousHistoryError(
                    f"the composed stream holds {ordinal} rows, expected {total_rows}"
                )
            expected_first = summary["first_delivered_canonical_utc"]
            expected_last = summary["last_delivered_canonical_utc"]
            if computed_first != expected_first or computed_last != expected_last:
                raise ContinuousHistoryError(
                    "the composed stream boundaries do not reproduce the qualified boundaries: "
                    f"{computed_first}..{computed_last} vs {expected_first}..{expected_last}"
                )
            global_digest = "sha256:" + digest.hexdigest()
            expectation = {
                "contract": "marketlab-single-anchor-replay-expectation-v1",
                "symbol": symbol,
                "market": market,
                "security_type": security_type,
                "data_time_zone": data_time_zone,
                "exchange_time_zone": exchange_time_zone,
                "source_path": summary["source_directory"],
                "source_file_sha256": summary["source_file_set_sha256"],
                "accepted_row_count": total_rows,
                "ordered_source_semantic_digest": global_digest,
                "first_canonical_utc": computed_first,
                "last_canonical_utc": computed_last,
                "lean_run_window": {
                    "start_date": ordered_partitions[0]["partition"],
                    "end_date": ordered_partitions[-1]["partition"],
                },
                "partitions": {
                    artifact["partition"]: {
                        "accepted_row_count": artifact["row_count"],
                        "semantic_digest": artifact["semantic_digest"],
                    }
                    for artifact in ordered_partitions
                },
            }
            composition = {
                "contract": MANIFEST_CONTRACT,
                "source": {
                    "path": summary["source_directory"],
                    "sha256": summary["source_file_set_sha256"],
                    "size_bytes": sum(entry["source_size_bytes"] for entry in month_entries),
                    "kind": "qualified-90-file-set-composed-native-history",
                    "months_root": str(months_root),
                },
                "lean": {
                    "symbol": symbol,
                    "market": market,
                    "security_type": security_type,
                    "data_time_zone": data_time_zone,
                    "exchange_time_zone": exchange_time_zone,
                    "market_hours_database": {
                        "entry_key": entry_key,
                        "database_sha256": market_hours_sha,
                        "always_open": True,
                    },
                    "symbol_properties_database": {"sha256": symbol_properties_sha},
                    "native_layout": layout.describe(),
                    "runtime_identity": runtime_identity,
                },
                "counts": {
                    "raw_row_count": total_rows,
                    "accepted_row_count": total_rows,
                    "rejected_row_count": 0,
                    "converted_row_count": total_rows,
                    "first_canonical_utc": computed_first,
                    "last_canonical_utc": computed_last,
                },
                "per_day": {
                    "accepted": {artifact["partition"]: artifact["row_count"] for artifact in ordered_partitions},
                    "converted": {artifact["partition"]: artifact["row_count"] for artifact in ordered_partitions},
                },
                "semantic": {
                    "ordered_source_semantic_digest": global_digest,
                    "per_partition": {
                        artifact["partition"]: {
                            "accepted_row_count": artifact["row_count"],
                            "semantic_digest": artifact["semantic_digest"],
                        }
                        for artifact in ordered_partitions
                    },
                },
                "native": {
                    "layout": layout.describe(),
                    "converted_row_count": total_rows,
                    "partitions": [
                        {
                            "partition": artifact["partition"],
                            "zip_relative_path": artifact["zip_relative_path"],
                            "zip_sha256": artifact["zip_sha256"],
                            "member_name": artifact["member_name"],
                            "member_sha256": artifact["member_sha256"],
                            "member_size_bytes": artifact["member_size_bytes"],
                            "row_count": artifact["row_count"],
                            "first_millisecond": artifact["first_millisecond"],
                            "last_millisecond": artifact["last_millisecond"],
                        }
                        for artifact in ordered_partitions
                    ],
                },
                "qualification": {
                    "source_qualification": "PASS",
                    "native_lean_timestamp_parity": "PASS",
                    "native_price_decimal_parity": "PASS",
                    "native_conversion": "PASS",
                    "converted_row_count": total_rows,
                },
                "composition": {
                    "contract": COMPOSITION_CONTRACT,
                    "months_root": str(months_root),
                    "month_count": len(month_entries),
                    "months": [
                        {
                            "month": entry["month"],
                            "source_file_name": entry["source_file_name"],
                            "source_sha256": entry["source_sha256"],
                            "source_size_bytes": entry["source_size_bytes"],
                            "record_sha256": entry["record_sha256"],
                            "manifest_sha256": entry["manifest_sha256"],
                            "accepted_row_count": entry["accepted_row_count"],
                            "partition_count": entry["partition_count"],
                            "ordered_source_semantic_digest": entry["ordered_source_semantic_digest"],
                        }
                        for entry in month_entries
                    ],
                    "partition_count": len(composition_partitions),
                    "source_directory": summary["source_directory"],
                    "source_file_set_sha256": summary["source_file_set_sha256"],
                    "ordered_month_digest_chain_sha256": summary["ordered_month_digest_chain_sha256"],
                    "lean_run_window": {
                        "start_date": ordered_partitions[0]["partition"],
                        "end_date": ordered_partitions[-1]["partition"],
                    },
                    "first_canonical_utc": computed_first,
                    "last_canonical_utc": computed_last,
                    "ordered_source_semantic_digest": global_digest,
                    "created_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "session_map": session_record,
                },
            }
            transaction.stage_text(
                data_folder / ARTIFACTS_DIRECTORY / EXPECTATION_NAME, dump_json(expectation)
            )
            transaction.stage_text(composition_path(data_folder), dump_json(composition))
            if session_bytes is not None:
                transaction.stage_bytes(data_folder / SESSION_MAP_RELATIVE, session_bytes)
            transaction.commit()
    except (ContinuousHistoryError, OutputTransactionError, OSError, ValueError) as error:
        return ContinuousOutcome(1, [f"CompositionFailed: {error}"], None, None)

    return ContinuousOutcome(0, [], composition, composition_path(data_folder))


def _timestamp_text(partition: str, millisecond: int) -> str:
    hour, remainder = divmod(millisecond, 3_600_000)
    minute, remainder = divmod(remainder, 60_000)
    second, fraction = divmod(remainder, 1000)
    return f"{partition}T{hour:02d}:{minute:02d}:{second:02d}.{fraction:03d}Z"


def _require_composition_structure(composition: dict) -> None:
    require_manifest_structure(composition)
    section = composition.get("composition")
    if not isinstance(section, dict) or section.get("contract") != COMPOSITION_CONTRACT:
        raise ValueError("manifest composition block is missing or not a MarketLab composition")
    for field in ("months_root", "partition_count", "lean_run_window"):
        if field not in section:
            raise ValueError(f"manifest composition.{field} is missing")


def build_continuous_record(
    composition: dict,
    composition_path: Path,
    probe_result: dict | None,
    probe_path: Path | None,
    failed_request_paths,
    data_folder: Path | None,
    runtime_binaries: dict | None = None,
    helper_exit_code: int | None = None,
) -> dict:
    """Builds the continuous qualification record on top of the established record."""
    _require_composition_structure(composition)
    record = build_record(
        manifest=composition,
        manifest_path=Path(composition_path),
        probe_result=probe_result,
        probe_path=probe_path,
        failed_request_paths=failed_request_paths,
        data_folder=Path(data_folder) if data_folder is not None else None,
        runtime_binaries=runtime_binaries,
        helper_exit_code=helper_exit_code,
    )
    failures = list(record.get("failure_reasons") or [])
    section = composition["composition"]
    partitions = composition["native"]["partitions"]
    checks: dict[str, bool] = {}

    def check(name: str, ok: bool, failure: str) -> None:
        checks[name] = bool(ok)
        if not ok:
            failures.append(failure)

    check(
        "partition_count",
        section.get("partition_count") == len(partitions)
        == len(composition["semantic"]["per_partition"])
        == len(composition["per_day"]["accepted"]),
        "CompositionPartitionCountMismatch",
    )
    check(
        "month_count",
        isinstance(section.get("months"), list) and section.get("month_count") == len(section["months"]),
        "CompositionMonthCountMismatch",
    )
    check(
        "partition_row_total",
        sum(artifact["row_count"] for artifact in partitions)
        == composition["counts"]["accepted_row_count"],
        "CompositionRowTotalMismatch",
    )
    check(
        "global_digest_binding",
        section.get("ordered_source_semantic_digest")
        == composition["semantic"]["ordered_source_semantic_digest"],
        "CompositionDigestBindingMismatch",
    )

    folder = Path(data_folder) if data_folder is not None else None
    if folder is not None:
        market_hours_file = folder / "market-hours" / "market-hours-database.json"
        symbol_properties_file = folder / "symbol-properties" / "symbol-properties-database.csv"
        check(
            "market_hours_file",
            market_hours_file.is_file()
            and _sha256_or_none(market_hours_file)
            == composition["lean"]["market_hours_database"]["database_sha256"],
            "CompositionMarketHoursFileMismatch",
        )
        check(
            "symbol_properties_file",
            symbol_properties_file.is_file()
            and _sha256_or_none(symbol_properties_file)
            == composition["lean"]["symbol_properties_database"]["sha256"],
            "CompositionSymbolPropertiesFileMismatch",
        )
        identity_file = folder / ARTIFACTS_DIRECTORY / "runtime-identity.json"
        identity_ok = False
        if identity_file.is_file():
            try:
                identity = json.loads(identity_file.read_text(encoding="utf-8-sig"))
            except (OSError, json.JSONDecodeError):
                identity = None
            if isinstance(identity, dict):
                identity_ok = (
                    (identity.get("derived_market_hours_database") or {}).get("sha256")
                    == composition["lean"]["market_hours_database"]["database_sha256"]
                    and (identity.get("derived_symbol_properties_database") or {}).get("sha256")
                    == composition["lean"]["symbol_properties_database"]["sha256"]
                )
        check("runtime_identity_file", identity_ok, "CompositionRuntimeIdentityFileMismatch")
        session = section.get("session_map")
        if isinstance(session, dict) and session.get("relative_path") and session.get("sha256"):
            session_file = folder / session["relative_path"]
            check(
                "session_map_file",
                session_file.is_file()
                and _sha256_or_none(session_file) == session.get("sha256"),
                "CompositionSessionMapMismatch",
            )
        if probe_result is not None:
            runtime = probe_result.get("runtime") or {}
            window = section.get("lean_run_window") or {}
            check(
                "probe_window",
                runtime.get("start_date") == window.get("start_date")
                and runtime.get("end_date") == window.get("end_date"),
                "CompositionProbeWindowMismatch",
            )
    record["continuous"] = {
        "contract": COMPOSITION_CONTRACT,
        "composition_path": str(composition_path),
        "composition_sha256": _sha256_or_none(Path(composition_path)),
        "partition_count": len(partitions),
        "month_count": len(section.get("months") or []),
        "session_map": section.get("session_map"),
        "lean_run_window": section.get("lean_run_window"),
        "checks": checks,
    }
    record["failure_reasons"] = _deduplicate(failures)
    record["overall_qualification"] = "PASS" if not failures else "FAIL"
    return record
