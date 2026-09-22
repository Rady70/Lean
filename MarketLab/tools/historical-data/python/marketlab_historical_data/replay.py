"""Replay expectation and the final qualification record.

The converter writes ``replay-expectation.json`` next to the qualification
manifest. The MarketLab C# replay probe reads it from the runtime data folder,
compares it with the quotes LEAN actually delivers, and writes
``replay-result.json`` into the run's object store. ``verify`` combines the
manifest, the probe result and the helper's failed-data-request list into one
machine-readable qualification record with an explicit overall PASS/FAIL.
"""

from __future__ import annotations

from pathlib import Path

from .canonical import sha256_file

__all__ = [
    "EXPECTATION_CONTRACT",
    "MANIFEST_CONTRACT",
    "RECORD_CONTRACT",
    "REPLAY_PROBE_CONTRACT",
    "build_expectation",
    "build_record",
    "classify_failed_data_requests",
    "require_manifest_structure",
    "require_probe_structure",
    "semantic_digest_line_format",
]

EXPECTATION_CONTRACT = "marketlab-single-anchor-replay-expectation-v1"
REPLAY_PROBE_CONTRACT = "marketlab-single-anchor-replay-probe-v1"
MANIFEST_CONTRACT = "marketlab-historical-data-qualification-v1"
RECORD_CONTRACT = "marketlab-historical-data-qualification-record-v1"

_DIGEST_LINE_FORMAT = "{ordinal}|{yyyy-MM-ddTHH:mm:ss.fffZ}|{canonical bid}|{canonical ask}\\n"

_MANIFEST_REQUIRED = {
    "source": ("path", "sha256"),
    "lean": (
        "symbol",
        "market",
        "security_type",
        "data_time_zone",
        "exchange_time_zone",
        "market_hours_database",
    ),
    "counts": ("accepted_row_count", "converted_row_count"),
    "per_day": ("accepted",),
    "semantic": ("ordered_source_semantic_digest",),
    "native": ("layout", "partitions"),
    "qualification": (
        "source_qualification",
        "native_lean_timestamp_parity",
        "native_price_decimal_parity",
        "native_conversion",
    ),
}

_PROBE_REQUIRED = (
    "completed",
    "qualification",
    "failure_reasons",
    "expected",
    "delivered",
    "comparison",
    "runtime",
)


def require_manifest_structure(manifest) -> None:
    """Raises ``ValueError`` when a manifest is not a complete MarketLab manifest."""
    if not isinstance(manifest, dict):
        raise ValueError("manifest is not a JSON object")
    if manifest.get("contract") != MANIFEST_CONTRACT:
        raise ValueError("manifest contract is missing or unknown")
    for section, keys in _MANIFEST_REQUIRED.items():
        value = manifest.get(section)
        if not isinstance(value, dict):
            raise ValueError(f"manifest section {section!r} is missing or not an object")
        for key in keys:
            if key not in value:
                raise ValueError(f"manifest section {section!r} is missing {key!r}")


def require_probe_structure(probe, label: str = "probe result") -> None:
    """Raises ``ValueError`` when replay evidence is not a complete probe result."""
    if not isinstance(probe, dict):
        raise ValueError(f"{label} is not a JSON object")
    if probe.get("contract") != REPLAY_PROBE_CONTRACT:
        raise ValueError(f"{label} contract is missing or unknown")
    for key in _PROBE_REQUIRED:
        if key not in probe:
            raise ValueError(f"{label} is missing {key!r}")
    for section in ("expected", "delivered", "comparison", "runtime"):
        if not isinstance(probe[section], dict):
            raise ValueError(f"{label} section {section!r} is not an object")
    delivered = probe["delivered"]
    if delivered.get("quote_count") is None or not delivered.get("semantic_digest"):
        raise ValueError(f"{label} delivered quote_count/semantic_digest is missing")
    runtime = probe["runtime"]
    for key in ("engine_quotes_processed", "data_time_zone", "exchange_time_zone", "market_hours_database_sha256"):
        if runtime.get(key) is None:
            raise ValueError(f"{label} runtime is missing {key!r}")
    if probe["comparison"].get("engine_quotes_match_delivered") is None:
        raise ValueError(f"{label} comparison is missing 'engine_quotes_match_delivered'")
    if probe["expected"].get("contract") != EXPECTATION_CONTRACT:
        raise ValueError(f"{label} embedded expectation contract is missing or unknown")


def semantic_digest_line_format() -> str:
    return _DIGEST_LINE_FORMAT


def build_expectation(manifest: dict) -> dict:
    """Builds the probe expectation from a passing qualification manifest."""
    lean = manifest["lean"]
    counts = manifest["counts"]
    semantic = manifest["semantic"]
    accepted_days = sorted(manifest["per_day"]["accepted"])
    if not accepted_days:
        raise ValueError("a passing conversion must have at least one accepted row")
    partitions = {}
    for day in accepted_days:
        digest = semantic["per_partition"].get(day, {}).get("semantic_digest")
        partitions[day] = {
            "accepted_row_count": manifest["per_day"]["accepted"][day],
            "semantic_digest": digest,
        }
    return {
        "contract": EXPECTATION_CONTRACT,
        "symbol": lean["symbol"],
        "market": lean["market"],
        "security_type": lean["security_type"],
        "data_time_zone": lean["data_time_zone"],
        "exchange_time_zone": lean["exchange_time_zone"],
        "source_path": manifest["source"]["path"],
        "source_file_sha256": manifest["source"]["sha256"],
        "accepted_row_count": counts["accepted_row_count"],
        "ordered_source_semantic_digest": semantic["ordered_source_semantic_digest"],
        "first_canonical_utc": counts["first_canonical_utc"],
        "last_canonical_utc": counts["last_canonical_utc"],
        "lean_run_window": {"start_date": accepted_days[0], "end_date": accepted_days[-1]},
        "partitions": partitions,
    }


def classify_failed_data_requests(
    failed_request_paths, tick_relative_directory: str
) -> tuple[list[str], list[str]]:
    """Splits failed data requests into native tick partitions and unrelated files."""
    prefix = tick_relative_directory.replace("\\", "/").strip("/") + "/"
    partitions: list[str] = []
    unrelated: list[str] = []
    for raw in failed_request_paths:
        normalized = str(raw).replace("\\", "/").lstrip("/")
        if normalized.lower().startswith(prefix.lower()) and normalized.lower().endswith(
            "_quote.zip"
        ):
            partitions.append(normalized)
        else:
            unrelated.append(normalized)
    return partitions, unrelated


def _file_sha256(path: Path) -> str | None:
    try:
        return sha256_file(path)
    except OSError:
        return None


def build_record(
    manifest: dict,
    manifest_path: Path,
    probe_result: dict | None,
    probe_path: Path | None,
    failed_request_paths,
    data_folder: Path | None,
) -> dict:
    """Builds the final qualification record; overall PASS only when every check passes."""
    failures: list[str] = []
    qualification = manifest.get("qualification", {})
    if qualification.get("source_qualification") != "PASS":
        failures.append("SourceQualificationFailed")
    if qualification.get("native_lean_timestamp_parity") != "PASS":
        failures.append("SourcePrecisionExceedsLeanTickFormat")
    if qualification.get("native_price_decimal_parity") != "PASS":
        failures.append("SourcePriceExceedsLeanDecimalFormat")
    if qualification.get("native_conversion") != "PASS":
        failures.append("NativeLeanConversionFailed")

    native_layout = manifest.get("native", {}).get("layout", {})
    tick_relative_directory = native_layout.get("zip_directory", "cfd/oanda/tick/xauusd")
    partition_failures, unrelated_failures = classify_failed_data_requests(
        failed_request_paths, tick_relative_directory
    )

    partition_rows_by_day = {
        artifact["partition"].replace("-", ""): artifact["row_count"]
        for artifact in manifest.get("native", {}).get("partitions", [])
    }
    manifest_partition_days = sorted(partition_rows_by_day)
    accepted_days = sorted(manifest["per_day"]["accepted"])
    window_start = accepted_days[0].replace("-", "") if accepted_days else ""
    window_end = accepted_days[-1].replace("-", "") if accepted_days else ""
    missing_partitions = []
    coverage_gap_days = []
    out_of_window_failures = []
    for path in partition_failures:
        day = Path(path).name[:8]
        if day in partition_rows_by_day:
            missing_partitions.append(day)
        elif window_start <= day <= window_end:
            coverage_gap_days.append(day)
        else:
            out_of_window_failures.append(path)
    missing_partitions = sorted(set(missing_partitions))
    coverage_gap_days = sorted(set(coverage_gap_days))

    conversion_passed = qualification.get("native_conversion") == "PASS"
    stale_partitions: list[str] = []
    missing_files: list[str] = []
    hash_mismatches: list[str] = []
    if conversion_passed and data_folder is not None:
        tick_directory = Path(data_folder) / tick_relative_directory
        existing_zip_days = set()
        if tick_directory.is_dir():
            for candidate in tick_directory.glob("*_quote.zip"):
                day = candidate.name[:8]
                if day.isdigit() and len(day) == 8:
                    existing_zip_days.add(day)
        manifest_days_compact = {day.replace("-", "") for day in manifest_partition_days}
        stale_partitions = sorted(existing_zip_days - manifest_days_compact)
        for artifact in manifest.get("native", {}).get("partitions", []):
            record_path = Path(data_folder) / artifact["zip_relative_path"]
            if not record_path.is_file():
                missing_files.append(artifact["partition"])
                continue
            actual = _file_sha256(record_path)
            if actual != artifact["zip_sha256"]:
                hash_mismatches.append(artifact["partition"])

    if missing_partitions:
        failures.append("NativePartitionMissing")
    if coverage_gap_days:
        failures.append("SourceCoverageGap")
    if stale_partitions:
        failures.append("StaleNativePartition")
    if missing_files:
        failures.append("NativePartitionFileMissing")
    if hash_mismatches:
        failures.append("NativePartitionHashMismatch")

    probe_present = probe_result is not None
    probe_completed = bool(probe_result and probe_result.get("completed") is True)
    delivered = probe_result.get("delivered", {}) if probe_present else {}
    runtime = probe_result.get("runtime", {}) if probe_present else {}
    comparison = probe_result.get("comparison", {}) if probe_present else {}

    if not probe_present:
        failures.append("NativeReplayProbeResultMissing")
    else:
        if not probe_completed:
            failures.append("NativeReplayProbeDidNotComplete")
        if probe_result.get("qualification") != "PASS":
            for reason in probe_result.get("failure_reasons") or ["NativeReplayProbeFailed"]:
                failures.append(reason)
        accepted_count = manifest["counts"]["accepted_row_count"]
        if delivered.get("quote_count") != accepted_count:
            failures.append("LeanDeliveredCountDiffersFromAcceptedCount")
        delivered_digest = delivered.get("semantic_digest")
        if (
            not delivered_digest
            or delivered_digest != manifest["semantic"]["ordered_source_semantic_digest"]
        ):
            failures.append("DeliveredSemanticDigestDiffers")
        if runtime.get("data_time_zone") != manifest["lean"].get("data_time_zone"):
            failures.append("ReplayRuntimeDataTimeZoneMismatch")
        if runtime.get("exchange_time_zone") != manifest["lean"].get("exchange_time_zone"):
            failures.append("ReplayRuntimeExchangeTimeZoneMismatch")
        manifest_mhdb_sha = manifest["lean"].get("market_hours_database", {}).get("database_sha256")
        if runtime.get("market_hours_database_sha256") != manifest_mhdb_sha:
            failures.append("ReplayRuntimeMarketHoursDatabaseMismatch")
        if runtime.get("engine_quotes_processed") != accepted_count:
            failures.append("EngineDidNotProcessEveryAcceptedQuote")
        if comparison.get("engine_quotes_match_delivered") is not True:
            failures.append("EngineDidNotProcessEveryDeliveredQuote")
        expected_bindings = {
            "contract": EXPECTATION_CONTRACT,
            "accepted_row_count": accepted_count,
            "ordered_source_semantic_digest": manifest["semantic"].get(
                "ordered_source_semantic_digest"
            ),
            "source_file_sha256": manifest["source"].get("sha256"),
            "symbol": manifest["lean"].get("symbol"),
            "market": manifest["lean"].get("market"),
            "security_type": manifest["lean"].get("security_type"),
            "data_time_zone": manifest["lean"].get("data_time_zone"),
            "exchange_time_zone": manifest["lean"].get("exchange_time_zone"),
        }
        expected = probe_result.get("expected") or {}
        for name, required in expected_bindings.items():
            if expected.get(name) != required:
                failures.append("ProbeExpectationDoesNotMatchManifest")
                break

    session_difference = None
    if probe_present and delivered.get("quote_count") is not None:
        session_difference = manifest["counts"]["accepted_row_count"] - delivered["quote_count"]

    record = {
        "contract": RECORD_CONTRACT,
        "manifest_path": str(manifest_path),
        "manifest_sha256": _file_sha256(manifest_path),
        "manifest": manifest,
        "probe": {
            "path": str(probe_path) if probe_path is not None else None,
            "sha256": _file_sha256(probe_path) if probe_path is not None else None,
            "present": probe_present,
            "completed": probe_completed,
            "qualification": probe_result.get("qualification") if probe_present else None,
            "delivered": delivered if probe_present else None,
            "comparison": comparison if probe_present else None,
            "runtime": runtime if probe_present else None,
            "semantic_digest_line_format": semantic_digest_line_format(),
        },
        "native_replay": {
            "accepted_row_count": manifest["counts"]["accepted_row_count"],
            "converted_row_count": qualification.get("converted_row_count"),
            "lean_delivered_row_count": delivered.get("quote_count") if probe_present else None,
            "ordered_source_semantic_digest": manifest["semantic"][
                "ordered_source_semantic_digest"
            ],
            "ordered_lean_delivered_semantic_digest": delivered.get("semantic_digest")
            if probe_present
            else None,
            "session_delivery_difference": session_difference,
            "missing_native_partitions": missing_partitions,
            "missing_partition_accepted_rows": sum(
                partition_rows_by_day.get(day, 0) for day in missing_partitions
            ),
            "source_coverage_gap_days": coverage_gap_days,
            "native_partition_failed_data_requests": partition_failures,
            "out_of_window_failed_data_requests": out_of_window_failures,
            "unrelated_failed_data_requests": unrelated_failures,
            "stale_native_partitions": stale_partitions,
            "missing_native_partition_files": missing_files,
            "native_partition_hash_mismatches": hash_mismatches,
        },
        "overall_qualification": "PASS" if not failures else "FAIL",
        "failure_reasons": _deduplicate(failures),
    }
    return record


def _deduplicate(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            result.append(value)
    return result
