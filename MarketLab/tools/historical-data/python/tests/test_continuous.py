"""Continuous native-history composition and continuous replay verification.

The tests build small synthetic month records with real native partition zips,
so the composition is exercised end to end without any historical data: the
partition hashes, the reconstructed global digest, the expectation, the
composition record and the continuous verification are all real.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.canonical import sha256_file  # noqa: E402
from marketlab_historical_data.continuous import (  # noqa: E402
    COMPOSITION_CONTRACT,
    build_continuous_record,
    compose_history,
    composition_path,
    continuous_record_path,
)
from marketlab_historical_data.lean_native import build_zip_bytes  # noqa: E402
from marketlab_historical_data.canonical import SemanticStreamDigest  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[5]
REPO_DATA = REPO_ROOT / "Data"
MARKET_HOURS_SHA = "325a7abc8214216c9107d45bb4e0a7fd291d2a5d771d3ebed6828d02da72518e"
SYMBOL_PROPERTIES_SHA = "7d52262f53fbec169b6e03c7acb220a73ea4ff95f48c198e4977e2280407d5ed"
RUNTIME_FILES = {
    "MarketLab.HistoricalDataProbe.dll": "a" * 64,
    "QuantConnect.Lean.Launcher.dll": "b" * 64,
    "QuantConnect.Lean.Engine.dll": "c" * 64,
    "QuantConnect.AlgorithmFactory.dll": "d" * 64,
    "QuantConnect.Algorithm.dll": "e" * 64,
    "QuantConnect.Common.dll": "f" * 64,
}

# Two months, two partitions each, a few canonical rows per partition.
ROWS = {
    "2023_01": {
        "2023-01-01": [(0, "1800.1", "1800.4"), (1, "1800.2", "1800.5"), (1500, "1800.3", "1800.6")],
        "2023-01-02": [(86400000 - 1, "1801", "1801.2"), (3600000, "1801.1", "1801.3")],
    },
    "2023_02": {
        "2023-02-01": [(0, "1810", "1810.5")],
        "2023-02-02": [(0, "1811", "1811.1"), (60000, "1811.2", "1811.4"), (120000, "1811.3", "1811.5")],
    },
}


def _timestamp(partition: str, millisecond: int) -> datetime:
    day = date.fromisoformat(partition)
    return datetime(day.year, day.month, day.day, tzinfo=timezone.utc) + timedelta(
        milliseconds=millisecond
    )


def _partition_digest(partition: str, rows) -> tuple[int, str, str, str]:
    digest = SemanticStreamDigest()
    for millisecond, bid, ask in rows:
        digest.add(_timestamp(partition, millisecond), Decimal(bid), Decimal(ask))
    return digest.count, digest.digest(), digest.first_timestamp, digest.last_timestamp


def _global_digest(rows_by_partition) -> tuple[int, str, str, str]:
    digest = SemanticStreamDigest()
    for partition, rows in rows_by_partition:
        for millisecond, bid, ask in rows:
            digest.add(_timestamp(partition, millisecond), Decimal(bid), Decimal(ask))
    return digest.count, digest.digest(), digest.first_timestamp, digest.last_timestamp


def _write_partition(root: Path, month: str, partition: str, rows) -> dict:
    member_name = f"{partition.replace('-', '')}_xauusd_tick_quote.csv"
    content = "\n".join(f"{millisecond},{bid},{ask}" for millisecond, bid, ask in rows).encode("utf-8")
    payload = build_zip_bytes(member_name, content)
    relative = f"cfd/dukascopy/tick/xauusd/{partition.replace('-', '')}_quote.zip"
    target = root / month / "data" / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(payload)
    count, digest, first, last = _partition_digest(partition, rows)
    return {
        "partition": partition,
        "zip_relative_path": relative,
        "zip_sha256": hashlib.sha256(payload).hexdigest(),
        "member_name": member_name,
        "member_sha256": hashlib.sha256(content).hexdigest(),
        "member_size_bytes": len(content),
        "row_count": count,
        "first_millisecond": rows[0][0],
        "last_millisecond": rows[-1][0],
        "semantic_digest": digest,
        "first_canonical_utc": first,
        "last_canonical_utc": last,
    }


def _write_month(root: Path, month: str, raw_root: Path) -> None:
    artifacts = [
        _write_partition(root, month, partition, rows)
        for partition, rows in ROWS[month].items()
    ]
    accepted = sum(artifact["row_count"] for artifact in artifacts)
    rows_flat = [(artifact["partition"], ROWS[month][artifact["partition"]]) for artifact in artifacts]
    _, month_digest, first, last = _global_digest(rows_flat)
    manifest = {
        "contract": "marketlab-historical-data-qualification-v1",
        "source": {
            "path": str(raw_root / f"XAUUSD_{month}_DUKASCOPY_JFOREX_FULL.csv"),
            "sha256": hashlib.sha256(f"source-{month}".encode()).hexdigest(),
            "size_bytes": 100,
        },
        "lean": {
            "symbol": "XAUUSD",
            "market": "dukascopy",
            "security_type": "Cfd",
            "data_time_zone": "UTC",
            "exchange_time_zone": "UTC",
            "market_hours_database": {
                "entry_key": "Cfd-dukascopy-XAUUSD",
                "database_sha256": MARKET_HOURS_SHA,
                "always_open": True,
            },
            "symbol_properties_database": {"sha256": SYMBOL_PROPERTIES_SHA},
            "runtime_identity": {
                "contract": "marketlab-runtime-identity-v1",
                "derived_market_hours_database": {"sha256": MARKET_HOURS_SHA},
                "derived_symbol_properties_database": {"sha256": SYMBOL_PROPERTIES_SHA},
            },
            "native_layout": {"zip_directory": "cfd/dukascopy/tick/xauusd"},
            "converter_source": {"aggregate_sha256": "1" * 64},
            "converter_checkout": {"head_sha": "2" * 40, "dirty": False},
        },
        "counts": {
            "raw_row_count": accepted,
            "accepted_row_count": accepted,
            "rejected_row_count": 0,
            "converted_row_count": accepted,
            "first_canonical_utc": artifacts[0]["first_canonical_utc"],
            "last_canonical_utc": artifacts[-1]["last_canonical_utc"],
        },
        "per_day": {
            "accepted": {artifact["partition"]: artifact["row_count"] for artifact in artifacts},
            "converted": {artifact["partition"]: artifact["row_count"] for artifact in artifacts},
        },
        "semantic": {
            "ordered_source_semantic_digest": month_digest,
            "per_partition": {
                artifact["partition"]: {
                    "accepted_row_count": artifact["row_count"],
                    "semantic_digest": artifact["semantic_digest"],
                }
                for artifact in artifacts
            },
        },
        "native": {
            "layout": {"zip_directory": "cfd/dukascopy/tick/xauusd"},
            "converted_row_count": accepted,
            "partitions": [
                {key: artifact[key] for key in (
                    "partition",
                    "zip_relative_path",
                    "zip_sha256",
                    "member_name",
                    "member_sha256",
                    "member_size_bytes",
                    "row_count",
                    "first_millisecond",
                    "last_millisecond",
                )}
                for artifact in artifacts
            ],
        },
        "qualification": {
            "source_qualification": "PASS",
            "native_lean_timestamp_parity": "PASS",
            "native_price_decimal_parity": "PASS",
            "native_conversion": "PASS",
            "converted_row_count": accepted,
        },
    }
    record = {
        "contract": "marketlab-historical-data-qualification-record-v1",
        "overall_qualification": "PASS",
        "failure_reasons": [],
        "helper_exit_code": 0,
        "manifest_sha256": "3" * 64,
        "manifest": manifest,
        "native_replay": {
            "accepted_row_count": accepted,
            "converted_row_count": accepted,
            "lean_delivered_row_count": accepted,
            "ordered_source_semantic_digest": month_digest,
            "ordered_lean_delivered_semantic_digest": month_digest,
            "session_delivery_difference": 0,
            "source_absent_days": [],
            "source_coverage_gap_days": [],
            "native_partition_failed_data_requests": [],
            "out_of_window_failed_data_requests": [],
            "unrelated_failed_data_requests": [],
            "missing_native_partitions": [],
            "missing_native_partition_files": [],
            "native_partition_hash_mismatches": [],
            "stale_native_partitions": [],
        },
        "probe": {
            "sha256": "4" * 64,
            "runtime": {"engine_quotes_processed": accepted},
            "delivered": {
                "per_partition": {
                    artifact["partition"]: {
                        "quote_count": artifact["row_count"],
                        "semantic_digest": artifact["semantic_digest"],
                    }
                    for artifact in artifacts
                }
            },
        },
        "runtime_binaries": {"files": dict(RUNTIME_FILES)},
    }
    record_path = root / month / "data" / "marketlab-qualification" / "qualification-record.json"
    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.write_text(json.dumps(record), encoding="utf-8")


def _compose_fixture(root: Path, *, session_map: bytes | None = None) -> tuple[Path, Path]:
    months_root = root / "months"
    raw_root = root / "raw"
    raw_root.mkdir(parents=True, exist_ok=True)
    for month in ROWS:
        _write_month(months_root, month, raw_root)
    data_folder = root / "continuous"
    session_path = None
    if session_map is not None:
        session_path = root / "xauusd-sessions.json"
        session_path.write_bytes(session_map)
    outcome = compose_history(
        months_root,
        data_folder,
        expected_first_month="2023_01",
        expected_last_month="2023_02",
        source_data_folder=REPO_DATA,
        session_map=session_path,
        force=False,
    )
    if outcome.exit_code != 0:
        raise AssertionError(f"compose failed: {outcome.failures}")
    return months_root, data_folder


def _matching_probe(data_folder: Path) -> dict:
    expectation = json.loads(
        (data_folder / "marketlab-qualification" / "replay-expectation.json").read_text(
            encoding="utf-8"
        )
    )
    return {
        "contract": "marketlab-single-anchor-replay-probe-v1",
        "completed": True,
        "qualification": "PASS",
        "failure_reasons": [],
        "expected": expectation,
        "delivered": {
            "quote_count": expectation["accepted_row_count"],
            "semantic_digest": expectation["ordered_source_semantic_digest"],
            "first_canonical_utc": expectation["first_canonical_utc"],
            "last_canonical_utc": expectation["last_canonical_utc"],
            "per_partition": {
                day: {"quote_count": entry["accepted_row_count"], "semantic_digest": entry["semantic_digest"]}
                for day, entry in expectation["partitions"].items()
            },
        },
        "comparison": {
            "count_matches": True,
            "digest_matches": True,
            "first_matches": True,
            "last_matches": True,
            "per_partition_counts_match": True,
            "per_partition_digests_match": True,
            "engine_quotes_match_delivered": True,
            "session_delivery_difference": 0,
        },
        "runtime": {
            "data_time_zone": "UTC",
            "exchange_time_zone": "UTC",
            "market_hours_database_sha256": MARKET_HOURS_SHA,
            "engine_quotes_processed": expectation["accepted_row_count"],
            "start_date": expectation["lean_run_window"]["start_date"],
            "end_date": expectation["lean_run_window"]["end_date"],
        },
    }


class ContinuousCompositionTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)

    def tearDown(self):
        self._directory.cleanup()

    def test_compose_builds_the_continuous_tree_expectation_and_identity(self):
        months_root = self.root / "months"
        raw_root = self.root / "raw"
        raw_root.mkdir()
        for month in ROWS:
            _write_month(months_root, month, raw_root)
        data_folder = self.root / "continuous"
        outcome = compose_history(
            months_root,
            data_folder,
            expected_first_month="2023_01",
            expected_last_month="2023_02",
            source_data_folder=REPO_DATA,
        )
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        self.assertEqual(composition_path(data_folder).is_file(), True)
        composition = json.loads(composition_path(data_folder).read_text(encoding="utf-8"))
        self.assertEqual(composition["contract"], "marketlab-historical-data-qualification-v1")
        self.assertEqual(composition["composition"]["contract"], COMPOSITION_CONTRACT)
        self.assertEqual(composition["composition"]["month_count"], 2)
        self.assertEqual(composition["composition"]["partition_count"], 4)
        self.assertEqual(composition["counts"]["accepted_row_count"], 9)
        self.assertEqual(composition["composition"]["source_file_set_sha256"], (
            hashlib.sha256(
                "\n".join(
                    sorted(
                        f"XAUUSD_{month}_DUKASCOPY_JFOREX_FULL.csv:"
                        + hashlib.sha256(f"source-{month}".encode()).hexdigest()
                        for month in ROWS
                    )
                ).encode("utf-8")
            ).hexdigest()
        ))
        expected_rows = [
            (partition, rows)
            for month in ROWS
            for partition, rows in ROWS[month].items()
        ]
        total, digest, first, last = _global_digest(expected_rows)
        self.assertEqual(composition["counts"]["accepted_row_count"], total)
        self.assertEqual(composition["semantic"]["ordered_source_semantic_digest"], digest)
        self.assertEqual(composition["counts"]["first_canonical_utc"], first)
        self.assertEqual(composition["counts"]["last_canonical_utc"], last)
        expectation = json.loads(
            (data_folder / "marketlab-qualification" / "replay-expectation.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(expectation["ordered_source_semantic_digest"], digest)
        self.assertEqual(expectation["accepted_row_count"], total)
        self.assertEqual(set(expectation["partitions"]), {partition for partition, _ in expected_rows})
        self.assertEqual(
            (data_folder / "market-hours" / "market-hours-database.json").is_file(), True
        )
        for relative in composition["native"]["partitions"]:
            self.assertEqual(
                sha256_file(data_folder / relative["zip_relative_path"]), relative["zip_sha256"]
            )

    def test_compose_copies_the_session_map_and_records_its_hash(self):
        session_map = b'{"contract": "marketlab-single-anchor-session-map-v1"}'
        months_root, data_folder = _compose_fixture(self.root, session_map=session_map)
        composition = json.loads(composition_path(data_folder).read_text(encoding="utf-8"))
        recorded = composition["composition"]["session_map"]
        self.assertEqual(recorded["sha256"], hashlib.sha256(session_map).hexdigest())
        target = data_folder / recorded["relative_path"]
        self.assertEqual(target.read_bytes(), session_map)

    def test_compose_refuses_existing_partitions_without_force(self):
        months_root, data_folder = _compose_fixture(self.root)
        outcome = compose_history(
            months_root,
            data_folder,
            expected_first_month="2023_01",
            expected_last_month="2023_02",
            source_data_folder=REPO_DATA,
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(any("OutputsExistWithoutForce" in failure for failure in outcome.failures))

    def test_compose_refuses_a_corrupted_partition_and_publishes_nothing(self):
        months_root = self.root / "months"
        raw_root = self.root / "raw"
        raw_root.mkdir()
        for month in ROWS:
            _write_month(months_root, month, raw_root)
        partition = months_root / "2023_01" / "data" / "cfd" / "dukascopy" / "tick" / "xauusd" / "20230101_quote.zip"
        partition.write_bytes(b"not the qualified zip")
        data_folder = self.root / "continuous"
        outcome = compose_history(
            months_root,
            data_folder,
            expected_first_month="2023_01",
            expected_last_month="2023_02",
            source_data_folder=REPO_DATA,
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertTrue(any("hash mismatch" in failure for failure in outcome.failures))
        self.assertFalse(composition_path(data_folder).exists())
        self.assertFalse(
            (data_folder / "marketlab-qualification" / "replay-expectation.json").exists()
        )
        tick_directory = data_folder / "cfd" / "dukascopy" / "tick" / "xauusd"
        self.assertEqual(
            len(list(tick_directory.glob("*_quote.zip"))) if tick_directory.is_dir() else 0, 0
        )


class ContinuousVerificationTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)
        self.months_root, self.data_folder = _compose_fixture(self.root)

    def tearDown(self):
        self._directory.cleanup()

    def verification(self, probe, *, failed=(), runtime_binaries=None):
        composition_file = composition_path(self.data_folder)
        composition = json.loads(composition_file.read_text(encoding="utf-8"))
        return build_continuous_record(
            composition=composition,
            composition_path=composition_file,
            probe_result=probe,
            probe_path=None,
            failed_request_paths=list(failed),
            data_folder=self.data_folder,
            runtime_binaries=runtime_binaries or {"files": dict(RUNTIME_FILES)},
            helper_exit_code=0,
        )

    def test_continuous_record_passes_for_matching_delivery(self):
        record = self.verification(_matching_probe(self.data_folder))
        self.assertEqual(record["overall_qualification"], "PASS", record["failure_reasons"])
        self.assertEqual(record["continuous"]["partition_count"], 4)
        self.assertEqual(record["continuous"]["month_count"], 2)
        self.assertTrue(all(record["continuous"]["checks"].values()))

    def test_continuous_record_fails_on_a_missing_partition(self):
        probe = _matching_probe(self.data_folder)
        day = next(iter(probe["delivered"]["per_partition"]))
        del probe["delivered"]["per_partition"][day]
        probe["comparison"]["per_partition_counts_match"] = False
        record = self.verification(probe)
        self.assertEqual(record["overall_qualification"], "FAIL")
        self.assertIn("PerPartitionCountsDiffer", record["failure_reasons"])

    def test_continuous_record_reports_partition_failures_and_source_absent_days(self):
        probe = _matching_probe(self.data_folder)
        record = self.verification(
            probe, failed=["cfd/dukascopy/tick/xauusd/20230103_quote.zip", "cfd/dukascopy/hour/xauusd.zip"]
        )
        replay = record["native_replay"]
        self.assertEqual(replay["source_absent_days"], ["20230103"])
        self.assertEqual(
            replay["native_partition_failed_data_requests"],
            ["cfd/dukascopy/tick/xauusd/20230103_quote.zip"],
        )
        self.assertEqual(replay["unrelated_failed_data_requests"], ["cfd/dukascopy/hour/xauusd.zip"])
        self.assertEqual(record["overall_qualification"], "PASS", record["failure_reasons"])

    def test_continuous_record_fails_when_the_session_map_changed(self):
        session_map = b'{"contract": "marketlab-single-anchor-session-map-v1"}'
        months_root, data_folder = _compose_fixture(self.root / "session", session_map=session_map)
        composition_file = composition_path(data_folder)
        composition = json.loads(composition_file.read_text(encoding="utf-8"))
        (data_folder / composition["composition"]["session_map"]["relative_path"]).write_bytes(b"tampered")
        record = build_continuous_record(
            composition=composition,
            composition_path=composition_file,
            probe_result=_matching_probe(data_folder),
            probe_path=None,
            failed_request_paths=[],
            data_folder=data_folder,
            runtime_binaries={"files": dict(RUNTIME_FILES)},
            helper_exit_code=0,
        )
        self.assertEqual(record["overall_qualification"], "FAIL")
        self.assertIn("CompositionSessionMapMismatch", record["failure_reasons"])

    def test_continuous_record_fails_on_a_wrong_delivered_digest(self):
        probe = _matching_probe(self.data_folder)
        probe["delivered"]["semantic_digest"] = "sha256:" + "0" * 64
        probe["comparison"]["digest_matches"] = False
        record = self.verification(probe)
        self.assertEqual(record["overall_qualification"], "FAIL")
        self.assertIn("DeliveredSemanticDigestDiffers", record["failure_reasons"])


class ContinuousCliTests(unittest.TestCase):
    def test_cli_compose_and_verify_continuous(self):
        package_root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            months_root = root / "months"
            raw_root = root / "raw"
            raw_root.mkdir()
            for month in ROWS:
                _write_month(months_root, month, raw_root)
            data_folder = root / "continuous"
            environment = dict(os.environ)
            environment["PYTHONPATH"] = str(package_root)
            compose = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "marketlab_historical_data",
                    "compose-history",
                    "--months-root",
                    str(months_root),
                    "--data-folder",
                    str(data_folder),
                    "--expected-first-month",
                    "2023_01",
                    "--expected-last-month",
                    "2023_02",
                    "--source-data-folder",
                    str(REPO_DATA),
                ],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )
            self.assertEqual(compose.returncode, 0, compose.stderr + compose.stdout)
            self.assertIn("compose-history: PASS", compose.stdout)
            probe = _matching_probe(data_folder)
            probe_file = root / "probe.json"
            probe_file.write_text(json.dumps(probe), encoding="utf-8")
            binaries_file = root / "runtime-binaries.json"
            binaries_file.write_text(json.dumps({"files": dict(RUNTIME_FILES)}), encoding="utf-8")
            verify = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "marketlab_historical_data",
                    "verify-continuous",
                    "--data-folder",
                    str(data_folder),
                    "--probe-result",
                    str(probe_file),
                    "--runtime-binaries",
                    str(binaries_file),
                    "--helper-exit-code",
                    "0",
                ],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )
            self.assertEqual(verify.returncode, 0, verify.stderr + verify.stdout)
            self.assertIn("verify-continuous: PASS", verify.stdout)
            self.assertTrue(continuous_record_path(data_folder).is_file())


if __name__ == "__main__":
    unittest.main()
