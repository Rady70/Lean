"""Replay expectation, failed-request classification and the final record."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.replay import (  # noqa: E402
    build_expectation,
    build_record,
    classify_failed_data_requests,
)

DIGEST = "sha256:" + "a" * 64
MARKET_HOURS_SHA = "b" * 64


def base_manifest(zip_sha256, digest=DIGEST, counts=(4, 4), days=("2014-05-05",)):
    accepted, converted = counts
    partition_days = list(days)
    return {
        "contract": "marketlab-historical-data-qualification-v1",
        "source": {"path": "source.csv", "sha256": "b" * 64, "size_bytes": 100},
        "lean": {
            "symbol": "XAUUSD",
            "market": "oanda",
            "security_type": "Cfd",
            "data_folder": "data",
            "data_time_zone": "UTC",
            "exchange_time_zone": "America/New_York",
            "market_hours_database": {
                "entry_key": "Cfd-oanda-XAUUSD",
                "database_sha256": MARKET_HOURS_SHA,
            },
            "native_layout": {"zip_directory": "cfd/oanda/tick/xauusd"},
        },
        "counts": {
            "raw_row_count": accepted,
            "accepted_row_count": accepted,
            "rejected_row_count": 0,
            "out_of_order_count": 0,
            "duplicate_timestamp_count": 0,
            "sub_millisecond_row_count": 0,
            "same_lean_millisecond_collision_count": 0,
            "maximum_rows_per_lean_millisecond": 1,
            "converted_row_count": converted,
            "first_canonical_utc": "2014-05-05T08:00:00.000Z",
            "last_canonical_utc": "2014-05-05T08:00:00.250Z",
        },
        "per_day": {"accepted": {day: 4 for day in partition_days}, "converted": {}},
        "semantic": {
            "ordered_source_semantic_digest": digest,
            "per_partition": {
                day: {"accepted_row_count": 4, "semantic_digest": digest}
                for day in partition_days
            },
        },
        "native": {
            "layout": {"zip_directory": "cfd/oanda/tick/xauusd"},
            "partitions": [
                {
                    "partition": day,
                    "zip_relative_path": f"cfd/oanda/tick/xauusd/{day.replace('-', '')}_quote.zip",
                    "zip_sha256": zip_sha256,
                    "row_count": 4,
                }
                for day in partition_days
            ],
        },
        "qualification": {
            "source_qualification": "PASS",
            "native_lean_timestamp_parity": "PASS",
            "native_price_decimal_parity": "PASS",
            "native_conversion": "PASS",
            "converted_row_count": converted,
        },
    }


def base_probe(digest=DIGEST, count=4):
    return {
        "probe": "MarketLab.HistoricalDataReplayProbe",
        "completed": True,
        "qualification": "PASS",
        "failure_reasons": [],
        "delivered": {
            "quote_count": count,
            "semantic_digest": digest,
            "first_canonical_utc": "2014-05-05T08:00:00.000Z",
            "last_canonical_utc": "2014-05-05T08:00:00.250Z",
            "per_partition": {
                "2014-05-05": {"quote_count": count, "semantic_digest": digest}
            },
        },
        "comparison": {"session_delivery_difference": 0},
        "runtime": {
            "engine_quotes_processed": count,
            "data_time_zone": "UTC",
            "exchange_time_zone": "America/New_York",
            "market_hours_database_sha256": MARKET_HOURS_SHA,
        },
    }


class ClassifyFailedRequestsTests(unittest.TestCase):
    def test_tick_and_unrelated_requests_are_separated(self):
        partitions, unrelated = classify_failed_data_requests(
            [
                "\\cfd\\oanda\\tick\\xauusd\\20140504_quote.zip",
                "\\cfd\\oanda\\hour\\xauusd.zip",
                "/equity/usa/daily/spy.zip",
            ],
            "cfd/oanda/tick/xauusd",
        )
        self.assertEqual(partitions, ["cfd/oanda/tick/xauusd/20140504_quote.zip"])
        self.assertEqual(len(unrelated), 2)


class ExpectationTests(unittest.TestCase):
    def test_expectation_is_built_from_the_manifest(self):
        manifest = base_manifest("c" * 64)
        manifest["source"]["path"] = "source.csv"
        expectation = build_expectation(manifest)
        self.assertEqual(expectation["accepted_row_count"], 4)
        self.assertEqual(expectation["ordered_source_semantic_digest"], DIGEST)
        self.assertEqual(expectation["lean_run_window"], {"start_date": "2014-05-05", "end_date": "2014-05-05"})
        self.assertEqual(expectation["partitions"]["2014-05-05"]["semantic_digest"], DIGEST)


class RecordTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)
        self.data = self.root / "data"
        self.tick_directory = self.data / "cfd" / "oanda" / "tick" / "xauusd"
        self.tick_directory.mkdir(parents=True)
        (self.tick_directory / "20140505_quote.zip").write_bytes(b"zip-payload")
        self.zip_sha = hashlib.sha256(b"zip-payload").hexdigest()
        self.manifest = base_manifest(self.zip_sha)
        self.manifest_path = self.data / "marketlab-qualification" / "qualification-manifest.json"
        self.manifest_path.parent.mkdir(parents=True)
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def tearDown(self):
        self._directory.cleanup()

    def build(self, probe, failed_requests=()):
        return build_record(
            manifest=self.manifest,
            manifest_path=self.manifest_path,
            probe_result=probe,
            probe_path=None,
            failed_request_paths=list(failed_requests),
            data_folder=self.data,
        )

    def test_exact_delivery_passes(self):
        record = self.build(base_probe(), ["cfd/oanda/tick/xauusd/20140504_quote.zip"])
        self.assertEqual(record["overall_qualification"], "PASS")
        self.assertEqual(record["failure_reasons"], [])
        self.assertEqual(record["native_replay"]["lean_delivered_row_count"], 4)
        self.assertEqual(record["native_replay"]["session_delivery_difference"], 0)
        self.assertEqual(
            record["native_replay"]["out_of_window_failed_data_requests"],
            ["cfd/oanda/tick/xauusd/20140504_quote.zip"],
        )

    def test_delivery_count_difference_fails(self):
        record = self.build(base_probe(count=3))
        self.assertEqual(record["overall_qualification"], "FAIL")
        self.assertIn("LeanDeliveredCountDiffersFromAcceptedCount", record["failure_reasons"])
        self.assertEqual(record["native_replay"]["session_delivery_difference"], 1)

    def test_digest_mismatch_fails(self):
        record = self.build(base_probe(digest="sha256:" + "d" * 64))
        self.assertIn("DeliveredSemanticDigestDiffers", record["failure_reasons"])

    def test_missing_delivered_digest_fails(self):
        probe = base_probe()
        del probe["delivered"]["semantic_digest"]
        record = self.build(probe)
        self.assertIn("DeliveredSemanticDigestDiffers", record["failure_reasons"])

    def test_runtime_timezone_mismatch_fails(self):
        probe = base_probe()
        probe["runtime"]["exchange_time_zone"] = "Europe/London"
        record = self.build(probe)
        self.assertIn("ReplayRuntimeExchangeTimeZoneMismatch", record["failure_reasons"])

    def test_runtime_data_timezone_mismatch_fails(self):
        probe = base_probe()
        probe["runtime"]["data_time_zone"] = "Europe/London"
        record = self.build(probe)
        self.assertIn("ReplayRuntimeDataTimeZoneMismatch", record["failure_reasons"])

    def test_runtime_market_hours_database_mismatch_fails(self):
        probe = base_probe()
        probe["runtime"]["market_hours_database_sha256"] = "c" * 64
        record = self.build(probe)
        self.assertIn("ReplayRuntimeMarketHoursDatabaseMismatch", record["failure_reasons"])

    def test_probe_missing_fails(self):
        record = self.build(None)
        self.assertEqual(record["overall_qualification"], "FAIL")
        self.assertIn("NativeReplayProbeResultMissing", record["failure_reasons"])
        self.assertIsNone(record["native_replay"]["lean_delivered_row_count"])

    def test_failed_manifest_partition_fails_and_reports_rows(self):
        record = self.build(
            base_probe(), ["cfd/oanda/tick/xauusd/20140505_quote.zip"]
        )
        self.assertIn("NativePartitionMissing", record["failure_reasons"])
        self.assertEqual(record["native_replay"]["missing_native_partitions"], ["20140505"])
        self.assertEqual(record["native_replay"]["missing_partition_accepted_rows"], 4)

    def test_in_window_day_without_source_rows_is_a_coverage_gap(self):
        manifest = base_manifest(self.zip_sha, days=("2014-05-05", "2014-05-07"))
        manifest["per_day"]["accepted"] = {"2014-05-05": 4, "2014-05-07": 4}
        self.manifest = manifest
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        record = self.build(
            base_probe(), ["cfd/oanda/tick/xauusd/20140506_quote.zip"]
        )
        self.assertIn("SourceCoverageGap", record["failure_reasons"])

    def test_stale_partition_fails(self):
        (self.tick_directory / "20140506_quote.zip").write_bytes(b"stale")
        record = self.build(base_probe())
        self.assertIn("StaleNativePartition", record["failure_reasons"])
        self.assertEqual(record["native_replay"]["stale_native_partitions"], ["20140506"])

    def test_missing_partition_file_fails(self):
        (self.tick_directory / "20140505_quote.zip").unlink()
        record = self.build(base_probe())
        self.assertIn("NativePartitionFileMissing", record["failure_reasons"])

    def test_partition_hash_mismatch_fails(self):
        (self.tick_directory / "20140505_quote.zip").write_bytes(b"tampered")
        record = self.build(base_probe())
        self.assertIn("NativePartitionHashMismatch", record["failure_reasons"])

    def test_probe_failure_reasons_are_propagated(self):
        probe = base_probe()
        probe["qualification"] = "FAIL"
        probe["failure_reasons"] = ["DeliveredSemanticDigestMismatches"]
        probe["delivered"]["semantic_digest"] = "sha256:" + "e" * 64
        record = self.build(probe)
        self.assertIn("DeliveredSemanticDigestMismatches", record["failure_reasons"])
        self.assertIn("DeliveredSemanticDigestDiffers", record["failure_reasons"])


if __name__ == "__main__":
    unittest.main()
