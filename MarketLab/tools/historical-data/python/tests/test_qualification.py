"""Qualification orchestration: strict gates, conversion, manifest and determinism."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.csv_source import CsvSourceConfig  # noqa: E402
from marketlab_historical_data.qualification import (  # noqa: E402
    dump_json,
    run_qualification,
)
from marketlab_historical_data.replay import EXPECTATION_CONTRACT  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"

PASS_CSV = (
    "timestamp,bid,ask\n"
    "2014-05-05 08:00:00.000,1291.6770,1292.0330\n"
    "2014-05-05 08:00:00.100,1291.680,1291.680\n"
    "2014-05-05 08:00:00.100,1291.681,1291.684\n"
    "2014-05-05 08:00:00.250,1291.69,1291.72\n"
)
FIXTURE_DIGEST = "sha256:92db8c553e1229145d107d52e8da0e40f645b3f929bbe41a864d2c0e4053d218"


class QualificationCase(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)
        data = self.root / "data"
        (data / "market-hours").mkdir(parents=True)
        shutil.copyfile(
            FIXTURES / "market-hours-fixture.json",
            data / "market-hours" / "market-hours-database.json",
        )
        self.data = data

    def tearDown(self):
        self._directory.cleanup()

    def write_source(self, text, name="source.csv"):
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        return path

    def qualify(self, text, force=False, name="source.csv"):
        return run_qualification(
            source_path=self.write_source(text, name),
            data_folder=self.data,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=force,
        )


class PassingQualificationTests(QualificationCase):
    def test_full_pass_writes_manifest_expectation_and_partition(self):
        outcome = self.qualify(PASS_CSV)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        manifest = outcome.manifest
        self.assertEqual(manifest["contract"], "marketlab-historical-data-qualification-v1")
        self.assertEqual(manifest["counts"]["accepted_row_count"], 4)
        self.assertEqual(manifest["counts"]["rejected_row_count"], 0)
        self.assertEqual(manifest["counts"]["converted_row_count"], 4)
        self.assertEqual(manifest["qualification"]["source_qualification"], "PASS")
        self.assertEqual(manifest["qualification"]["native_lean_timestamp_parity"], "PASS")
        self.assertEqual(manifest["qualification"]["native_conversion"], "PASS")
        self.assertEqual(manifest["qualification"]["overall_qualification"], "PENDING_NATIVE_REPLAY")
        self.assertEqual(manifest["lean"]["data_time_zone"], "UTC")
        self.assertEqual(manifest["lean"]["exchange_time_zone"], "America/New_York")
        self.assertEqual(manifest["lean"]["market_hours_database"]["entry_key"], "Cfd-oanda-XAUUSD")
        self.assertEqual(len(manifest["lean"]["market_hours_database"]["database_sha256"]), 64)
        self.assertEqual(manifest["semantic"]["ordered_source_semantic_digest"], FIXTURE_DIGEST)
        self.assertEqual(len(manifest["native"]["partitions"]), 1)
        self.assertEqual(
            manifest["native"]["partitions"][0]["member_name"], "20140505_xauusd_tick_quote.csv"
        )
        self.assertEqual(manifest["per_day"]["accepted"], {"2014-05-05": 4})
        self.assertEqual(manifest["per_day"]["converted"], {"2014-05-05": 4})
        self.assertEqual(manifest["counts"]["first_canonical_utc"], "2014-05-05T08:00:00.000Z")
        self.assertEqual(manifest["counts"]["last_canonical_utc"], "2014-05-05T08:00:00.250Z")
        expectation = json.loads(
            (self.data / "marketlab-qualification" / "replay-expectation.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(expectation["contract"], EXPECTATION_CONTRACT)
        self.assertEqual(expectation["lean_run_window"], {"start_date": "2014-05-05", "end_date": "2014-05-05"})
        self.assertEqual(expectation["partitions"]["2014-05-05"]["accepted_row_count"], 4)
        self.assertTrue(
            (self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip").is_file()
        )

    def test_manifest_is_deterministic_at_the_semantic_level(self):
        first = self.qualify(PASS_CSV, force=False, name="first.csv")
        first_bytes = dump_json(first.manifest).encode("utf-8")
        second = self.qualify(PASS_CSV, force=True, name="second.csv")
        second_bytes = dump_json(second.manifest).encode("utf-8")
        first_manifest = json.loads(first_bytes)
        second_manifest = json.loads(second_bytes)
        for manifest in (first_manifest, second_manifest):
            manifest["source"]["path"] = "source.csv"
            manifest["lean"]["data_folder"] = "data"
            manifest["lean"]["converter_checkout"] = None
        self.assertEqual(first_manifest, second_manifest)

    def test_conversion_is_idempotent_with_force(self):
        self.qualify(PASS_CSV)
        first_zip = (self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip").read_bytes()
        self.qualify(PASS_CSV, force=True)
        second_zip = (self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip").read_bytes()
        self.assertEqual(first_zip, second_zip)


class FailingQualificationTests(QualificationCase):
    def test_rejected_rows_fail_qualification_before_conversion(self):
        outcome = self.qualify(
            "timestamp,bid,ask\n2014-05-05 08:00:00.000,1291.7,1291.6\n"
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertIn("SourceRejectedRows", outcome.failures)
        self.assertEqual(outcome.manifest["counts"]["rejected_row_count"], 1)
        self.assertEqual(outcome.manifest["qualification"]["native_conversion"], "NOT_RUN")
        self.assertFalse((self.data / "cfd").exists())
        expectation = self.data / "marketlab-qualification" / "replay-expectation.json"
        self.assertFalse(expectation.exists(), "no expectation may be written on failure")

    def test_sub_millisecond_precision_fails_the_native_gate(self):
        outcome = self.qualify(
            "timestamp,bid,ask\n2014-05-05 08:00:00.123456,1291.6,1291.7\n"
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertIn("SourcePrecisionExceedsLeanTickFormat", outcome.failures)
        self.assertEqual(outcome.manifest["counts"]["sub_millisecond_row_count"], 1)
        self.assertEqual(outcome.manifest["qualification"]["native_conversion"], "NOT_RUN")
        self.assertIsNone(outcome.manifest["semantic"]["ordered_source_semantic_digest"])
        self.assertFalse((self.data / "cfd").exists())

    def test_unrepresentable_decimal_fails_the_decimal_gate(self):
        outcome = self.qualify(
            "timestamp,bid,ask\n2014-05-05 08:00:00.000,0.00000000000000000000000000001,1.0\n"
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertIn("SourcePriceExceedsLeanDecimalFormat", outcome.failures)
        self.assertFalse((self.data / "cfd").exists())

    def test_second_run_without_force_is_refused(self):
        self.qualify(PASS_CSV)
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "again.csv"),
            data_folder=self.data,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertIn("ManifestNotWritten", outcome.failures[0])

    def test_missing_runtime_market_hours_database_is_a_configuration_error(self):
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "no-db.csv"),
            data_folder=self.root,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("MarketHoursDatabaseUnusable"))


if __name__ == "__main__":
    unittest.main()
