"""Command-line interface for the offline qualification and replay verification."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .csv_source import CsvSourceConfig
from .qualification import (
    CONTRACT,
    artifacts_directory,
    dump_json,
    load_json,
    manifest_path,
    record_path,
    run_qualification,
)
from .replay import build_record
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
    parser.add_argument("--report", help="output record path (default: data folder)")
    parser.add_argument(
        "--force", action="store_true", help="replace an existing qualification record"
    )
    parser.add_argument("--json", action="store_true", help="print the record JSON to stdout")


def _read_failed_requests(path: Path) -> list[str]:
    lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
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
    if replay["unrelated_failed_data_requests"]:
        print(f"unrelated failed data requests (not tick partitions): "
              f"{len(replay['unrelated_failed_data_requests'])}")
    print(f"overall qualification: {record['overall_qualification']}")
    if record["failure_reasons"]:
        print(f"failure reasons: {record['failure_reasons']}")


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
    if manifest.get("contract") != CONTRACT:
        print(f"ERROR: not a MarketLab qualification manifest: {manifest_file}", file=sys.stderr)
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
        if not isinstance(probe_result, dict):
            print(f"ERROR: probe result is not a JSON object: {probe_file}", file=sys.stderr)
            return 2

    failed_requests: list[str] = []
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

    record = build_record(
        manifest=manifest,
        manifest_path=manifest_file,
        probe_result=probe_result,
        probe_path=probe_file,
        failed_request_paths=failed_requests,
        data_folder=data_folder,
    )
    report_file = Path(args.report) if args.report else record_path(data_folder)
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
    _qualify_parser(subparsers)
    _verify_parser(subparsers)
    args = parser.parse_args(argv)
    if args.command == "qualify":
        return _run_qualify(args)
    if args.command == "verify":
        return _run_verify(args)
    parser.error(f"unknown command {args.command!r}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
