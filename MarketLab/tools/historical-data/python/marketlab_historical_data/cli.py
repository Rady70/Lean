"""Command-line interface for the offline qualification and replay verification."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .csv_source import CsvSourceConfig
from .identity import (
    RuntimeIdentityError,
    prepare_runtime_identity,
)
from .qualification import (
    artifacts_directory,
    dump_json,
    load_json,
    manifest_path,
    record_path,
    run_qualification,
)
from .replay import (
    build_record,
    require_manifest_structure,
    require_probe_structure,
    require_runtime_binaries_structure,
)
from .summary import FullHistorySummaryError, build_full_history_summary
from .transactions import OutputTransaction, OutputTransactionError

__all__ = ["main"]


def _qualify_parser(subparsers) -> None:
    parser = subparsers.add_parser(
        "qualify",
        help="strictly qualify a historical bid/ask CSV and convert it to native LEAN ticks",
    )
    parser.add_argument("--source", required=True, help="historical bid/ask CSV source file")
    parser.add_argument(
        "--data-folder",
        required=True,
        help="runtime LEAN data folder (market-hours + symbol-properties must be present); "
        "native partitions and qualification artifacts are written here",
    )
    parser.add_argument("--timestamp-column")
    parser.add_argument("--date-column")
    parser.add_argument("--time-column")
    parser.add_argument("--bid-column")
    parser.add_argument("--ask-column")
    parser.add_argument("--delimiter", help="source delimiter; '\\t' means tab (default: sniffed)")
    parser.add_argument("--timestamp-format", help="explicit strptime format for the timestamp text")
    parser.add_argument(
        "--source-timezone",
        help="IANA timezone of timezone-naive timestamps (required for naive sources; must not "
        "be given when timestamps carry an embedded UTC offset)",
    )
    parser.add_argument("--symbol", default="XAUUSD")
    parser.add_argument("--market", default="oanda")
    parser.add_argument("--security-type", default="Cfd")
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace existing native partitions, manifest and expectation atomically",
    )
    parser.add_argument("--json", action="store_true", help="print the manifest JSON to stdout")


def _prepare_identity_parser(subparsers) -> None:
    parser = subparsers.add_parser(
        "prepare-identity",
        help="derive the always-open runtime identity databases for a replay subscription",
    )
    parser.add_argument(
        "--data-folder",
        required=True,
        help="runtime LEAN data folder the derived market-hours/symbol-properties databases "
        "are written into",
    )
    parser.add_argument(
        "--source-data-folder",
        required=True,
        help="data folder holding the unchanged auxiliary databases the derived identity is "
        "built from (the engine fixtures, typically <LeanRoot>\\Data)",
    )
    parser.add_argument("--symbol", default="XAUUSD")
    parser.add_argument("--market", default="dukascopy")
    parser.add_argument("--security-type", default="Cfd")
    parser.add_argument(
        "--force",
        action="store_true",
        help="replace derived identity databases whose bytes differ from the required derivation",
    )
    parser.add_argument("--json", action="store_true", help="print the provenance JSON to stdout")


def _summarize_history_parser(subparsers) -> None:
    parser = subparsers.add_parser(
        "summarize-history",
        help="validate and aggregate a contiguous sequence of per-file PR-1 month records",
    )
    parser.add_argument(
        "--months-root",
        required=True,
        help="directory containing one subdirectory per month, each holding "
        "data\\marketlab-qualification\\qualification-record.json (the per-file sweep layout)",
    )
    parser.add_argument(
        "--output",
        help="summary path (default: <months-root>\\full-history-summary.json)",
    )
    parser.add_argument("--json", action="store_true", help="print the summary JSON to stdout")


def _verify_parser(subparsers) -> None:
    parser = subparsers.add_parser(
        "verify",
        help="combine a qualification manifest with the LEAN replay probe result into one record",
    )
    parser.add_argument("--manifest", help="qualification manifest path (default: data folder)")
    parser.add_argument("--data-folder", help="runtime data folder (default: from the manifest)")
    parser.add_argument("--probe-result", help="replay-result.json written by the LEAN probe run")
    parser.add_argument(
        "--failed-data-requests",
        help="LEAN helper failed-data-requests-*.txt for the probe run",
    )
    parser.add_argument(
        "--runtime-binaries",
        help="JSON of the runtime binary hashes recorded by the driver "
        "({\"files\": {\"name.dll\": \"<sha256>\"}})",
    )
    parser.add_argument(
        "--helper-exit-code",
        type=int,
        help="exit code of the LEAN helper run; a PASS record requires 0 (a nonzero code is "
        "accepted only for a deliberate probe replay mismatch)",
    )
    parser.add_argument("--report", help="output record path (default: data folder)")
    parser.add_argument(
        "--force", action="store_true", help="replace an existing qualification record"
    )
    parser.add_argument("--json", action="store_true", help="print the record JSON to stdout")


def _read_failed_requests(path: Path) -> list[str]:
    lines = Path(path).read_text(encoding="utf-8-sig", errors="replace").splitlines()
    return [line.strip() for line in lines if line.strip()]


def _print_manifest_summary(manifest: dict) -> None:
    counts = manifest["counts"]
    qualification = manifest["qualification"]
    print(f"source rows: {counts['raw_row_count']} raw, {counts['accepted_row_count']} accepted, "
          f"{counts['rejected_row_count']} rejected")
    if counts["rejected_row_reasons"]:
        print(f"rejection reasons: {counts['rejected_row_reasons']}")
    print(
        f"out-of-order: {counts['out_of_order_count']}; duplicates: "
        f"{counts['duplicate_timestamp_count']}; sub-millisecond rows: "
        f"{counts['sub_millisecond_row_count']}; same-LEAN-millisecond collisions: "
        f"{counts['same_lean_millisecond_collision_count']} "
        f"(max {counts['maximum_rows_per_lean_millisecond']} rows per millisecond)"
    )
    print(
        f"source qualification: {qualification['source_qualification']}; native timestamp parity: "
        f"{qualification['native_lean_timestamp_parity']}; price decimal parity: "
        f"{qualification['native_price_decimal_parity']}; conversion: "
        f"{qualification['native_conversion']}"
    )
    if manifest["semantic"]["ordered_source_semantic_digest"]:
        print(f"ordered source semantic digest: {manifest['semantic']['ordered_source_semantic_digest']}")
    else:
        print(f"ordered source semantic digest: not evaluated ({manifest['semantic']['digest_status']})")
    runtime_identity = manifest.get("lean", {}).get("runtime_identity")
    if isinstance(runtime_identity, dict):
        source_database = runtime_identity.get("source_market_hours_database")
        source_path = source_database.get("path") if isinstance(source_database, dict) else None
        print(f"runtime identity: {runtime_identity.get('entry_key')} "
              f"(prepared from {source_path})")
    print(f"converted rows: {counts['converted_row_count']} across "
          f"{len(manifest['native']['partitions'])} native partitions")
    if qualification.get("conversion_error"):
        print(f"conversion error: {qualification['conversion_error']}")


def _print_record_summary(record: dict) -> None:
    replay = record["native_replay"]
    print(f"manifest: {record['manifest_path']}")
    print(f"accepted rows: {replay['accepted_row_count']}; converted rows: "
          f"{replay['converted_row_count']}; LEAN delivered rows: "
          f"{replay['lean_delivered_row_count']}")
    print(f"ordered source semantic digest: {replay['ordered_source_semantic_digest']}")
    print(f"ordered delivered semantic digest: {replay['ordered_lean_delivered_semantic_digest']}")
    print(f"session/delivery difference: {replay['session_delivery_difference']}")
    if replay.get("source_absent_days"):
        print(f"source-absent tradable days (no source rows, expected under an always-open "
              f"identity): {len(replay['source_absent_days'])}")
    if replay["unrelated_failed_data_requests"]:
        print(f"unrelated failed data requests (not tick partitions): "
              f"{len(replay['unrelated_failed_data_requests'])}")
    runtime_binaries = record.get("runtime_binaries") or {}
    if runtime_binaries.get("files"):
        print(f"runtime binaries recorded: {len(runtime_binaries['files'])}")
    print(f"LEAN helper exit code: {record.get('helper_exit_code')}")
    print(f"overall qualification: {record['overall_qualification']}")
    if record["failure_reasons"]:
        print(f"failure reasons: {record['failure_reasons']}")


def _run_prepare_identity(args) -> int:
    try:
        payload = prepare_runtime_identity(
            data_folder=Path(args.data_folder),
            source_data_folder=Path(args.source_data_folder),
            symbol=args.symbol,
            market=args.market,
            security_type=args.security_type,
            force=args.force,
        )
    except RuntimeIdentityError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(
        f"runtime identity: {payload['entry_key']} "
        f"({payload['data_time_zone']}/{payload['exchange_time_zone']}, always open); "
        f"market-hours {payload['derived_market_hours_database']['sha256'][:12]}, "
        f"symbol-properties {payload['derived_symbol_properties_database']['sha256'][:12]}"
    )
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False))
    return 0


def _run_summarize_history(args) -> int:
    try:
        summary = build_full_history_summary(Path(args.months_root))
    except FullHistorySummaryError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    output = (
        Path(args.output)
        if args.output
        else Path(args.months_root) / "full-history-summary.json"
    )
    try:
        with OutputTransaction(allow_overwrite=True) as transaction:
            transaction.stage_text(output, dump_json(summary))
            transaction.commit()
    except OutputTransactionError as error:
        print(f"ERROR: summary not written: {error}", file=sys.stderr)
        return 2

    totals = summary["totals"]
    print(
        f"months: {summary['month_count']} (pass {summary['months_pass']}, "
        f"fail {summary['months_fail']})"
    )
    print(
        f"accepted: {totals['accepted_row_count']}; converted: "
        f"{totals['converted_row_count']}; delivered: "
        f"{totals['lean_delivered_row_count']}; probe processed: "
        f"{totals['probe_processed_row_count']}"
    )
    print(f"source file set: {summary['source_file_set_sha256']}")
    print(f"month digest chain: {summary['ordered_month_digest_chain_sha256']}")
    print(f"summary: {output}")
    if args.json:
        print(dump_json(summary))
    if summary["errors"]:
        for error in summary["errors"]:
            print(f"FAIL: {error}", file=sys.stderr)
        print("summarize-history: FAIL", file=sys.stderr)
        return 1
    if summary["month_count"] == 0:
        print("ERROR: no month records were aggregated", file=sys.stderr)
        return 2
    print("summarize-history: PASS")
    return 0


def _run_qualify(args) -> int:
    config = CsvSourceConfig(
        delimiter=args.delimiter,
        timestamp_column=args.timestamp_column,
        date_column=args.date_column,
        time_column=args.time_column,
        bid_column=args.bid_column,
        ask_column=args.ask_column,
        timestamp_format=args.timestamp_format,
        source_timezone=args.source_timezone,
    )
    outcome = run_qualification(
        source_path=Path(args.source),
        data_folder=Path(args.data_folder),
        config=config,
        symbol=args.symbol,
        market=args.market,
        security_type=args.security_type,
        force=args.force,
    )
    if outcome.manifest is not None:
        _print_manifest_summary(outcome.manifest)
    for failure in outcome.failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if outcome.manifest_path:
        print(f"manifest: {outcome.manifest_path}")
        expectation_file = artifacts_directory(Path(args.data_folder)) / "replay-expectation.json"
        if expectation_file.is_file():
            print(f"expectation: {expectation_file}")
    if args.json and outcome.manifest is not None:
        print(dump_json(outcome.manifest))
    if outcome.exit_code == 2:
        print("qualify: configuration error; LEAN was not run and nothing was converted", file=sys.stderr)
    elif outcome.exit_code == 0:
        print("qualify: PASS (awaiting the native LEAN replay probe)")
    else:
        print("qualify: FAIL", file=sys.stderr)
    return outcome.exit_code


def _run_verify(args) -> int:
    manifest_file = Path(args.manifest) if args.manifest else None
    data_folder = Path(args.data_folder) if args.data_folder else None
    if manifest_file is None:
        if data_folder is None:
            print("ERROR: verify needs --manifest or --data-folder", file=sys.stderr)
            return 2
        manifest_file = manifest_path(data_folder)
    if not manifest_file.is_file():
        print(f"ERROR: manifest not found: {manifest_file}", file=sys.stderr)
        return 2
    try:
        manifest = load_json(manifest_file)
    except (OSError, json.JSONDecodeError) as error:
        print(f"ERROR: manifest is not readable JSON: {manifest_file}: {error}", file=sys.stderr)
        return 2
    if not isinstance(manifest, dict):
        print(f"ERROR: manifest is not a JSON object: {manifest_file}", file=sys.stderr)
        return 2
    try:
        require_manifest_structure(manifest)
    except ValueError as error:
        print(f"ERROR: not a usable MarketLab qualification manifest: {manifest_file}: {error}", file=sys.stderr)
        return 2
    if data_folder is None:
        recorded = manifest.get("lean", {}).get("data_folder")
        data_folder = Path(recorded) if recorded else manifest_file.parent.parent

    probe_result = None
    probe_file = None
    if args.probe_result:
        probe_file = Path(args.probe_result)
        if not probe_file.is_file():
            print(f"ERROR: probe result not found: {probe_file}", file=sys.stderr)
            return 2
        try:
            probe_result = load_json(probe_file)
        except (OSError, json.JSONDecodeError) as error:
            print(f"ERROR: probe result is not readable JSON: {probe_file}: {error}", file=sys.stderr)
            return 2
        try:
            require_probe_structure(probe_result)
        except ValueError as error:
            print(f"ERROR: not a usable replay probe result: {probe_file}: {error}", file=sys.stderr)
            return 2

    failed_requests: list[str] = []
    evidence_paths = [manifest_file]
    if args.failed_data_requests:
        failed_path = Path(args.failed_data_requests)
        if not failed_path.is_file():
            print(f"ERROR: failed-data-requests file not found: {failed_path}", file=sys.stderr)
            return 2
        try:
            failed_requests = _read_failed_requests(failed_path)
        except OSError as error:
            print(f"ERROR: failed-data-requests file is not readable: {failed_path}: {error}", file=sys.stderr)
            return 2
        evidence_paths.append(failed_path)
    if probe_file is not None:
        evidence_paths.append(probe_file)

    runtime_binaries = None
    if args.runtime_binaries:
        runtime_file = Path(args.runtime_binaries)
        if not runtime_file.is_file():
            print(f"ERROR: runtime-binaries file not found: {runtime_file}", file=sys.stderr)
            return 2
        try:
            runtime_binaries = load_json(runtime_file)
        except (OSError, json.JSONDecodeError) as error:
            print(f"ERROR: runtime-binaries file is not readable JSON: {runtime_file}: {error}", file=sys.stderr)
            return 2
        try:
            require_runtime_binaries_structure(runtime_binaries)
        except ValueError as error:
            print(f"ERROR: malformed runtime-binaries evidence: {runtime_file}: {error}", file=sys.stderr)
            return 2
        evidence_paths.append(runtime_file)

    record = build_record(
        manifest=manifest,
        manifest_path=manifest_file,
        probe_result=probe_result,
        probe_path=probe_file,
        failed_request_paths=failed_requests,
        data_folder=data_folder,
        runtime_binaries=runtime_binaries,
        helper_exit_code=args.helper_exit_code,
    )
    report_file = Path(args.report) if args.report else record_path(data_folder)
    for evidence in evidence_paths:
        if os.path.normcase(str(report_file.resolve())) == os.path.normcase(str(Path(evidence).resolve())):
            print(
                f"ERROR: the report path must not replace an evidence input: {report_file}",
                file=sys.stderr,
            )
            return 2
    try:
        with OutputTransaction(allow_overwrite=args.force) as transaction:
            transaction.stage_text(report_file, dump_json(record))
            transaction.commit()
    except OutputTransactionError as error:
        print(f"ERROR: record not written: {error}", file=sys.stderr)
        return 2

    _print_record_summary(record)
    print(f"record: {report_file}")
    if args.json:
        print(dump_json(record))
    if record["overall_qualification"] == "PASS":
        print("verify: PASS")
        return 0
    print("verify: FAIL", file=sys.stderr)
    return 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="marketlab_historical_data",
        description=(
            "MarketLab offline historical-data qualification: strict CSV validation, exact-decimal "
            "native LEAN tick conversion, and replay verification against the actual LEAN delivery."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    _prepare_identity_parser(subparsers)
    _qualify_parser(subparsers)
    _verify_parser(subparsers)
    _summarize_history_parser(subparsers)
    args = parser.parse_args(argv)
    if args.command == "prepare-identity":
        return _run_prepare_identity(args)
    if args.command == "qualify":
        return _run_qualify(args)
    if args.command == "verify":
        return _run_verify(args)
    if args.command == "summarize-history":
        return _run_summarize_history(args)
    parser.error(f"unknown command {args.command!r}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
