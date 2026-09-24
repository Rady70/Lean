"""Deterministic aggregation of per-run PR-1 records into one summary.

The tooling qualifies one source file per run. A full-history qualification is
therefore a sequence of per-file PR-1 runs, and this module makes the
decomposition explicit and machine-checked:

- every record must be a structurally valid ``PASS`` with helper exit code 0;
- accepted = converted = LEAN-delivered = probe-processed, session difference
  0, and every per-partition count and semantic digest must equal the source;
- the run set must be one contiguous, ordered sequence of distinct calendar
  months (``YYYY_MM``), each record's source file name must match its month,
  each record's first/last timestamps must fall inside that month, and
  consecutive months must not overlap (previous last < next first);
- the identity must be a singleton across every run: symbol, market, security
  type, native path, time zones, market-hours database SHA-256,
  symbol-properties SHA-256, converter source aggregate, clean checkout and the
  runtime binary set.

Aggregate hashes (documented in ``aggregate_algorithm`` and in the emitted
summary):

- ``source_file_set_sha256`` = SHA-256 of the newline-joined
  ``<source file name>:<source sha256>`` lines in month order;
- ``ordered_month_digest_chain_sha256`` = SHA-256 of the newline-joined
  per-month ordered source semantic digests in month order.

Both are aggregates over the decomposition. They are **not** a single-run PR-1
ordinal digest: per-month ordinals restart per file and the tooling does not
ingest multiple source files into one run.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from pathlib import Path

from .replay import MANIFEST_CONTRACT, RECORD_CONTRACT, require_manifest_structure

__all__ = [
    "FULL_HISTORY_SUMMARY_CONTRACT",
    "FullHistorySummaryError",
    "build_full_history_summary",
    "discover_month_records",
    "load_qualification_record",
]

FULL_HISTORY_SUMMARY_CONTRACT = "marketlab-full-history-qualification-summary-v1"

_MONTH_PATTERN = re.compile(
    r"^XAUUSD_(?P<year>\d{4})_(?P<month>\d{2})_DUKASCOPY_JFOREX_FULL\.csv$",
    re.IGNORECASE,
)
_RECORD_RELATIVE = Path("data") / "marketlab-qualification" / "qualification-record.json"
_AGGREGATE_ALGORITHM = {
    "source_file_set_sha256": (
        "sha256 of the newline-joined '<source file name>:<source sha256>' lines in month order"
    ),
    "ordered_month_digest_chain_sha256": (
        "sha256 of the newline-joined per-month ordered source semantic digests in month order"
    ),
}


class FullHistorySummaryError(Exception):
    """The month-record set cannot be aggregated into a valid summary."""


def _month_key(value: str) -> str:
    match = _MONTH_PATTERN.match(value)
    if match is None:
        raise FullHistorySummaryError(
            f"the source file name {value!r} is not a Dukascopy monthly source file"
        )
    return f"{match.group('year')}_{match.group('month')}"


def _month_index(month: str) -> int:
    year, number = month.split("_")
    return int(year) * 12 + int(number)


def discover_month_records(months_root: Path) -> list[tuple[str, Path]]:
    """Every direct child month directory with a qualification record, sorted."""
    root = Path(months_root)
    if not root.is_dir():
        raise FullHistorySummaryError(f"months root not found: {root}")
    found: list[tuple[str, Path]] = []
    for candidate in sorted(root.iterdir(), key=lambda path: path.name):
        if not candidate.is_dir():
            continue
        record_path = candidate / _RECORD_RELATIVE
        if not record_path.is_file():
            raise FullHistorySummaryError(
                f"month directory {candidate.name} has no qualification record: {record_path}"
            )
        found.append((candidate.name, record_path))
    if not found:
        raise FullHistorySummaryError(f"no month directories under {root}")
    return found


def load_qualification_record(path: Path) -> dict:
    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as error:
        raise FullHistorySummaryError(
            f"qualification record is not readable JSON: {path}: {error}"
        ) from error
    if not isinstance(payload, dict):
        raise FullHistorySummaryError(f"qualification record is not a JSON object: {path}")
    return payload


def _runtime_binary_set_sha256(record: dict) -> str | None:
    files = (record.get("runtime_binaries") or {}).get("files")
    if not isinstance(files, dict) or not files:
        return None
    lines = "\n".join(f"{name}:{files[name]}" for name in sorted(files))
    return hashlib.sha256(lines.encode("utf-8")).hexdigest()


def _timestamp_month(timestamp: str) -> str | None:
    try:
        parsed = datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%S.%fZ")
    except (TypeError, ValueError):
        return None
    return f"{parsed.year:04d}_{parsed.month:02d}"


def build_full_history_summary(months_root: Path) -> dict:
    """Validates the ordered month records and returns the aggregate summary."""
    errors: list[str] = []
    month_entries: list[dict] = []
    for directory_name, record_path in discover_month_records(months_root):
        if not re.fullmatch(r"\d{4}_\d{2}", directory_name):
            errors.append(f"{directory_name}: month directory name is not YYYY_MM")
            continue
        record = load_qualification_record(record_path)
        if record.get("contract") != RECORD_CONTRACT:
            errors.append(f"{directory_name}: record contract is missing or unknown")
            continue
        manifest = record.get("manifest")
        try:
            require_manifest_structure(manifest)
        except ValueError as error:
            errors.append(f"{directory_name}: {error}")
            continue

        source_path = Path(manifest["source"]["path"])
        source_name = source_path.name
        try:
            source_month = _month_key(source_name)
        except FullHistorySummaryError as error:
            errors.append(f"{directory_name}: {error}")
            continue
        if source_month != directory_name:
            errors.append(
                f"{directory_name}: source file {source_name} is month {source_month}"
            )
            continue

        lean = manifest["lean"]
        counts = manifest["counts"]
        replay = record["native_replay"]
        probe = record.get("probe") or {}
        runtime = probe.get("runtime") or {}
        delivered = probe.get("delivered") or {}
        delivered_partitions = delivered.get("per_partition") or {}
        manifest_partitions = manifest["semantic"].get("per_partition") or {}
        accepted = counts["accepted_row_count"]
        converted = counts["converted_row_count"]
        delivered_count = replay.get("lean_delivered_row_count")
        processed = runtime.get("engine_quotes_processed")
        source_digest = replay.get("ordered_source_semantic_digest")
        delivered_digest = replay.get("ordered_lean_delivered_semantic_digest")

        if record.get("overall_qualification") != "PASS" or record.get("failure_reasons") != []:
            errors.append(
                f"{directory_name}: record is not a clean PASS "
                f"({record.get('overall_qualification')}: {record.get('failure_reasons')})"
            )
            continue
        if record.get("helper_exit_code") != 0:
            errors.append(f"{directory_name}: helper exit code is not 0")
            continue
        if (
            not isinstance(accepted, int)
            or accepted != converted
            or accepted != delivered_count
            or accepted != processed
        ):
            errors.append(
                f"{directory_name}: accepted/converted/delivered/processed differ "
                f"({accepted}/{converted}/{delivered_count}/{processed})"
            )
            continue
        if counts["rejected_row_count"] != 0:
            errors.append(f"{directory_name}: rejected rows are not zero")
            continue
        if manifest["qualification"].get("source_qualification") != "PASS":
            errors.append(f"{directory_name}: source qualification is not PASS")
            continue
        if replay.get("session_delivery_difference") != 0:
            errors.append(f"{directory_name}: session delivery difference is not zero")
            continue
        if source_digest != delivered_digest or not source_digest:
            errors.append(f"{directory_name}: source and delivered semantic digests differ")
            continue
        if set(manifest_partitions) != set(delivered_partitions):
            errors.append(f"{directory_name}: delivered partitions differ from the manifest")
            continue
        if any(
            delivered_partitions[day].get("quote_count") != manifest_partitions[day]["accepted_row_count"]
            or delivered_partitions[day].get("semantic_digest")
            != manifest_partitions[day]["semantic_digest"]
            for day in manifest_partitions
        ):
            errors.append(f"{directory_name}: per-partition counts or digests differ")
            continue
        for field, label in (
            ("missing_native_partitions", "missing native partitions"),
            ("source_coverage_gap_days", "source coverage gaps"),
            ("missing_native_partition_files", "missing partition files"),
            ("native_partition_hash_mismatches", "partition hash mismatches"),
            ("stale_native_partitions", "stale partitions"),
        ):
            if replay.get(field):
                errors.append(f"{directory_name}: {label}: {replay[field]}")
        first = counts.get("first_canonical_utc")
        last = counts.get("last_canonical_utc")
        first_month = _timestamp_month(first)
        last_month = _timestamp_month(last)
        if first_month is None or last_month is None:
            errors.append(
                f"{directory_name}: first/last timestamps are not canonical UTC "
                f"({first}..{last})"
            )
            continue
        if first_month != directory_name or last_month != directory_name:
            # Recorded, but the entry still participates in the ordering and
            # boundary checks below so overlapping evidence is reported too.
            errors.append(
                f"{directory_name}: first/last timestamps fall outside the month "
                f"({first}..{last})"
            )

        identity = lean.get("runtime_identity") or {}
        month_entries.append(
            {
                "month": directory_name,
                "source_file_name": source_name,
                "source_path": manifest["source"]["path"],
                "source_sha256": manifest["source"]["sha256"],
                "source_size_bytes": manifest["source"]["size_bytes"],
                "raw_row_count": counts["raw_row_count"],
                "accepted_row_count": accepted,
                "rejected_row_count": counts["rejected_row_count"],
                "converted_row_count": converted,
                "lean_delivered_row_count": delivered_count,
                "probe_processed_row_count": processed,
                "session_delivery_difference": replay["session_delivery_difference"],
                "source_semantic_digest": source_digest,
                "delivered_semantic_digest": delivered_digest,
                "digest_equal": source_digest == delivered_digest,
                "per_partition_equal": True,
                "first_canonical_utc": first,
                "last_canonical_utc": last,
                "partition_count": len(manifest["native"]["partitions"]),
                "source_absent_days": list(replay.get("source_absent_days") or []),
                "source_coverage_gap_days": list(replay.get("source_coverage_gap_days") or []),
                "native_partition_failed_data_requests": list(
                    replay.get("native_partition_failed_data_requests") or []
                ),
                "out_of_window_failed_data_requests": list(
                    replay.get("out_of_window_failed_data_requests") or []
                ),
                "unrelated_failed_data_requests": list(
                    replay.get("unrelated_failed_data_requests") or []
                ),
                "missing_native_partitions": list(replay.get("missing_native_partitions") or []),
                "symbol": lean["symbol"],
                "market": lean["market"],
                "security_type": lean["security_type"],
                "native_path": lean["native_layout"]["zip_directory"],
                "data_time_zone": lean["data_time_zone"],
                "exchange_time_zone": lean["exchange_time_zone"],
                "market_hours_entry_key": lean["market_hours_database"]["entry_key"],
                "market_hours_always_open": lean["market_hours_database"]["always_open"],
                "market_hours_database_sha256": lean["market_hours_database"]["database_sha256"],
                "symbol_properties_database_sha256": lean["symbol_properties_database"]["sha256"],
                "runtime_identity_contract": identity.get("contract"),
                "runtime_identity_derived_market_hours_sha256": (
                    identity.get("derived_market_hours_database") or {}
                ).get("sha256"),
                "converter_source_aggregate_sha256": (lean.get("converter_source") or {}).get(
                    "aggregate_sha256"
                ),
                "converter_checkout_head_sha": (lean.get("converter_checkout") or {}).get("head_sha"),
                "converter_checkout_dirty": (lean.get("converter_checkout") or {}).get("dirty"),
                "runtime_binary_set_sha256": _runtime_binary_set_sha256(record),
                "helper_exit_code": record.get("helper_exit_code"),
                "overall_qualification": record["overall_qualification"],
                "failure_reasons": list(record.get("failure_reasons") or []),
                "manifest_sha256": record.get("manifest_sha256"),
                "record_sha256": hashlib.sha256(record_path.read_bytes()).hexdigest(),
                "probe_result_sha256": probe.get("sha256"),
            }
        )

    if month_entries:
        months = [entry["month"] for entry in month_entries]
        expected = list(range(_month_index(months[0]), _month_index(months[0]) + len(months)))
        actual = [_month_index(month) for month in months]
        if actual != expected:
            errors.append(
                "the month sequence is not contiguous and ordered: " + ", ".join(months)
            )
        for previous, current in zip(month_entries, month_entries[1:]):
            if previous["last_canonical_utc"] >= current["first_canonical_utc"]:
                errors.append(
                    f"{previous['month']} and {current['month']} overlap "
                    f"({previous['last_canonical_utc']} >= {current['first_canonical_utc']})"
                )

    identity_fields = (
        "symbol",
        "market",
        "security_type",
        "native_path",
        "data_time_zone",
        "exchange_time_zone",
        "market_hours_entry_key",
        "market_hours_database_sha256",
        "symbol_properties_database_sha256",
        "runtime_identity_contract",
        "runtime_identity_derived_market_hours_sha256",
        "converter_source_aggregate_sha256",
        "converter_checkout_head_sha",
        "runtime_binary_set_sha256",
    )
    identity = {}
    for field in identity_fields:
        values = sorted({str(entry[field]) for entry in month_entries})
        identity[f"{field}_set"] = values
        if len(values) > 1:
            errors.append(f"the {field} is not a singleton across the month records: {values}")
    dirty_values = sorted({str(entry["converter_checkout_dirty"]) for entry in month_entries})
    identity["converter_checkout_dirty_set"] = dirty_values
    if dirty_values and dirty_values != ["False"]:
        errors.append(f"the converter checkout was not clean for every run: {dirty_values}")

    source_directory = None
    if month_entries:
        parents = {str(Path(entry["source_path"]).parent) for entry in month_entries}
        source_directory = parents.pop() if len(parents) == 1 else None
        if len(parents) > 1:
            errors.append(f"month records came from different source directories: {sorted(parents)}")

    source_lines = "\n".join(
        f"{entry['source_file_name']}:{entry['source_sha256']}" for entry in month_entries
    )
    digest_chain = hashlib.sha256(
        "\n".join(entry["source_semantic_digest"] for entry in month_entries).encode("utf-8")
    ).hexdigest()
    totals = {
        "source_size_bytes": sum(entry["source_size_bytes"] for entry in month_entries),
        "raw_row_count": sum(entry["raw_row_count"] for entry in month_entries),
        "accepted_row_count": sum(entry["accepted_row_count"] for entry in month_entries),
        "rejected_row_count": sum(entry["rejected_row_count"] for entry in month_entries),
        "converted_row_count": sum(entry["converted_row_count"] for entry in month_entries),
        "lean_delivered_row_count": sum(entry["lean_delivered_row_count"] for entry in month_entries),
        "probe_processed_row_count": sum(
            entry["probe_processed_row_count"] for entry in month_entries
        ),
        "session_delivery_difference": sum(
            entry["session_delivery_difference"] for entry in month_entries
        ),
        "source_absent_days": sum(len(entry["source_absent_days"]) for entry in month_entries),
        "source_coverage_gap_days": sum(
            len(entry["source_coverage_gap_days"]) for entry in month_entries
        ),
        "unrelated_failed_data_requests": sum(
            len(entry["unrelated_failed_data_requests"]) for entry in month_entries
        ),
        "missing_native_partitions": sum(
            len(entry["missing_native_partitions"]) for entry in month_entries
        ),
    }
    summary = {
        "contract": FULL_HISTORY_SUMMARY_CONTRACT,
        "note": (
            "Sequence of per-file PR-1 runs under one qualified identity. The aggregate hashes "
            "are over the decomposition; per-month ordinals restart per file and the tooling "
            "does not ingest multiple source files into one run, so there is no single-stream "
            "PR-1 ordinal digest."
        ),
        "source_directory": source_directory,
        "month_count": len(month_entries),
        "source_file_set_sha256": hashlib.sha256(source_lines.encode("utf-8")).hexdigest(),
        "ordered_month_digest_chain_sha256": digest_chain,
        "aggregate_algorithm": dict(_AGGREGATE_ALGORITHM),
        "months": month_entries,
        "totals": totals,
        "months_pass": sum(
            1 for entry in month_entries if entry["overall_qualification"] == "PASS"
        ),
        "months_fail": sum(
            1 for entry in month_entries if entry["overall_qualification"] != "PASS"
        ),
        "all_counts_equal": all(
            entry["accepted_row_count"]
            == entry["converted_row_count"]
            == entry["lean_delivered_row_count"]
            == entry["probe_processed_row_count"]
            for entry in month_entries
        ),
        "all_digests_equal": all(entry["digest_equal"] for entry in month_entries),
        "all_per_partition_equal": all(entry["per_partition_equal"] for entry in month_entries),
        "identity": identity,
        "first_delivered_canonical_utc": month_entries[0]["first_canonical_utc"]
        if month_entries
        else None,
        "last_delivered_canonical_utc": month_entries[-1]["last_canonical_utc"]
        if month_entries
        else None,
        "errors": errors,
    }
    return summary
