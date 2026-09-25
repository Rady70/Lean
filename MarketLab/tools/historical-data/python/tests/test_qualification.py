"""Qualification orchestration: strict gates, conversion, manifest and determinism."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data import qualification as qualification_module  # noqa: E402
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
        (data / "symbol-properties").mkdir()
        (data / "symbol-properties" / "symbol-properties-database.csv").write_text(
            "market,symbol,type,description,quote_currency,contract_multiplier,"
            "minimum_price_variation,lot_size,market_ticker,minimum_order_size,price_magnifier,strike_multiplier\n"
            "oanda,XAUUSD,cfd,Gold,USD,1,0.001,1\n",
            encoding="utf-8",
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
        self.assertIsNone(manifest["lean"]["runtime_identity"])
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

    def test_prepared_always_open_identity_is_bound_into_the_manifest(self):
        from marketlab_historical_data.identity import prepare_runtime_identity

        data = self.root / "dukascopy-data"
        data.mkdir()
        prepare_runtime_identity(
            data_folder=data,
            source_data_folder=self.data,
            symbol="XAUUSD",
            market="dukascopy",
            security_type="Cfd",
        )
        source = self.write_source(
            "timestamp,bid,ask\n"
            "2014-05-05 21:30:00.000,1291.90,1292.10\n"
        )
        outcome = run_qualification(
            source_path=source,
            data_folder=data,
            config=CsvSourceConfig(source_timezone="UTC"),
            symbol="XAUUSD",
            market="dukascopy",
            security_type="Cfd",
        )
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        manifest = outcome.manifest
        self.assertEqual(manifest["lean"]["market"], "dukascopy")
        self.assertEqual(manifest["lean"]["data_time_zone"], "UTC")
        self.assertEqual(manifest["lean"]["exchange_time_zone"], "UTC")
        self.assertTrue(manifest["lean"]["market_hours_database"]["always_open"])
        runtime_identity = manifest["lean"]["runtime_identity"]
        self.assertEqual(runtime_identity["contract"], "marketlab-runtime-identity-v1")
        self.assertEqual(runtime_identity["entry_key"], "Cfd-dukascopy-XAUUSD")
        self.assertTrue(
            (
                data
                / "cfd"
                / "dukascopy"
                / "tick"
                / "xauusd"
                / "20140505_quote.zip"
            ).is_file()
        )

    def test_round_prices_convert_and_are_written_canonically(self):
        outcome = self.qualify(
            "timestamp,bid,ask\n2014-05-05 08:00:00.000,1900.00,1900.50\n"
        )
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        self.assertEqual(outcome.manifest["qualification"]["native_price_decimal_parity"], "PASS")
        zip_path = self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip"
        with zipfile.ZipFile(zip_path) as archive:
            content = archive.read(archive.namelist()[0]).decode("utf-8")
        self.assertEqual(content, "28800000,1900,1900.5")

    def test_exponent_prices_convert_to_the_integer_value(self):
        outcome = self.qualify(
            "timestamp,bid,ask\n2014-05-05 08:00:00.000,1.9e3,1.9e3\n"
        )
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        zip_path = self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip"
        with zipfile.ZipFile(zip_path) as archive:
            content = archive.read(archive.namelist()[0]).decode("utf-8")
        self.assertEqual(content, "28800000,1900,1900")

    def test_force_removes_owned_stale_partitions(self):
        two_days = (
            "timestamp,bid,ask\n"
            "2014-05-05 08:00:00.000,1291.6770,1292.0330\n"
            "2014-05-06 08:00:00.000,1291.70,1291.80\n"
        )
        self.qualify(two_days, name="two-days.csv")
        second_day = self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140506_quote.zip"
        self.assertTrue(second_day.is_file())
        outcome = self.qualify(PASS_CSV, force=True, name="one-day.csv")
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        self.assertFalse(second_day.exists())
        self.assertTrue(
            (self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip").is_file()
        )

    def test_force_refuses_foreign_partitions(self):
        self.qualify(PASS_CSV)
        foreign = self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140101_quote.zip"
        foreign.write_bytes(b"unrelated history")
        outcome = self.qualify(PASS_CSV, force=True)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("ForeignNativePartitions"))
        self.assertEqual(foreign.read_bytes(), b"unrelated history")

    def test_force_refuses_a_tampered_owned_partition(self):
        self.qualify(PASS_CSV)
        partition = self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip"
        partition.write_bytes(b"tampered")
        outcome = self.qualify(PASS_CSV, force=True)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("ForeignNativePartitions"))

    def test_force_refuses_partitions_without_a_previous_manifest(self):
        new_root = self.root / "no-manifest"
        shutil.copytree(self.data, new_root)
        foreign = new_root / "cfd" / "oanda" / "tick" / "xauusd" / "20140101_quote.zip"
        foreign.parent.mkdir(parents=True)
        foreign.write_bytes(b"unrelated history")
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "no-manifest.csv"),
            data_folder=new_root,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=True,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("ForeignNativePartitions"))
        self.assertEqual(foreign.read_bytes(), b"unrelated history")

    def test_malformed_previous_manifest_fails_closed_as_foreign(self):
        new_root = self.root / "malformed-manifest"
        shutil.copytree(self.data, new_root)
        artifacts = new_root / "marketlab-qualification"
        artifacts.mkdir()
        (artifacts / "qualification-manifest.json").write_text(
            json.dumps(
                {
                    "contract": "marketlab-historical-data-qualification-v1",
                    "native": "corrupt",
                }
            ),
            encoding="utf-8",
        )
        foreign = new_root / "cfd" / "oanda" / "tick" / "xauusd" / "20140101_quote.zip"
        foreign.parent.mkdir(parents=True)
        foreign.write_bytes(b"unrelated history")
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "malformed-manifest.csv"),
            data_folder=new_root,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=True,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("ForeignNativePartitions"))
        self.assertEqual(foreign.read_bytes(), b"unrelated history")

    def test_partition_change_before_publication_is_refused(self):
        from marketlab_historical_data.canonical import sha256_file
        from marketlab_historical_data.qualification import (
            NativePartitionSetChanged,
            _revalidate_native_partitions,
        )

        owned_path = self.root / "owned.zip"
        owned_path.write_bytes(b"original")
        owned = {owned_path: sha256_file(owned_path)}
        _revalidate_native_partitions(owned, [owned_path])
        owned_path.write_bytes(b"changed")
        with self.assertRaises(NativePartitionSetChanged):
            _revalidate_native_partitions(owned, [owned_path])
        appeared = self.root / "appeared.zip"
        appeared.write_bytes(b"foreign")
        with self.assertRaises(NativePartitionSetChanged):
            _revalidate_native_partitions(owned, [appeared])

    def test_converter_source_identity_is_recorded(self):
        outcome = self.qualify(PASS_CSV)
        converter_source = outcome.manifest["lean"]["converter_source"]
        self.assertEqual(len(converter_source["aggregate_sha256"]), 64)
        self.assertGreaterEqual(converter_source["file_count"], 10)
        recomputed = qualification_module.converter_source_identity(
            Path(qualification_module.__file__)
        )
        self.assertEqual(converter_source["aggregate_sha256"], recomputed["aggregate_sha256"])
        self.assertTrue(
            (self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip").is_file()
        )

    def test_source_identity_change_fails_before_publication(self):
        real_sha256_file = qualification_module.sha256_file
        calls = {"count": 0}

        def changing_hash(path, chunk_size=1 << 20):
            if Path(path).suffix == ".csv":
                calls["count"] += 1
                if calls["count"] == 2:
                    return "0" * 64
            return real_sha256_file(path, chunk_size)

        with mock.patch.object(qualification_module, "sha256_file", side_effect=changing_hash):
            outcome = self.qualify(PASS_CSV)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("SourceChangedDuringQualification"))
        self.assertIsNone(outcome.manifest)
        self.assertFalse((self.data / "marketlab-qualification" / "qualification-manifest.json").exists())
        tick_directory = self.data / "cfd" / "oanda" / "tick" / "xauusd"
        self.assertFalse(
            tick_directory.is_dir() and list(tick_directory.glob("*_quote.zip"))
        )

    def test_source_identity_change_during_a_failing_qualification_publishes_nothing(self):
        real_sha256_file = qualification_module.sha256_file
        calls = {"count": 0}

        def changing_hash(path, chunk_size=1 << 20):
            if Path(path).suffix == ".csv":
                calls["count"] += 1
                if calls["count"] == 2:
                    return "0" * 64
            return real_sha256_file(path, chunk_size)

        source = "timestamp,bid,ask\n2014-05-05 08:00:00.000,1291.7,1291.6\n"
        with mock.patch.object(qualification_module, "sha256_file", side_effect=changing_hash):
            outcome = self.qualify(source, name="changing-fail.csv")
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("SourceChangedDuringQualification"))
        self.assertFalse((self.data / "marketlab-qualification" / "qualification-manifest.json").exists())

    def test_forced_success_invalidates_the_previous_record(self):
        self.qualify(PASS_CSV)
        record = self.data / "marketlab-qualification" / "qualification-record.json"
        record.write_text("{}", encoding="utf-8")
        outcome = self.qualify(PASS_CSV, force=True)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        self.assertFalse(record.exists())
        self.assertTrue(
            (self.data / "marketlab-qualification" / "qualification-manifest.json").is_file()
        )

    def test_forced_failure_clears_the_superseded_generation(self):
        self.qualify(PASS_CSV)
        record = self.data / "marketlab-qualification" / "qualification-record.json"
        record.write_text("{}", encoding="utf-8")
        expectation = self.data / "marketlab-qualification" / "replay-expectation.json"
        partition = self.data / "cfd" / "oanda" / "tick" / "xauusd" / "20140505_quote.zip"
        self.assertTrue(expectation.is_file() and partition.is_file())
        outcome = self.qualify(
            "timestamp,bid,ask\n2014-05-05 08:00:00.000,1291.7,1291.6\n",
            force=True,
            name="failing-replacement.csv",
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual(outcome.manifest["qualification"]["native_conversion"], "NOT_RUN")
        self.assertFalse(expectation.exists())
        self.assertFalse(record.exists())
        self.assertFalse(partition.exists())
        self.assertTrue(
            (self.data / "marketlab-qualification" / "qualification-manifest.json").is_file()
        )

    def test_data_folder_inside_the_repository_is_refused(self):
        repository = Path(__file__).resolve().parents[5]
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "inside-repo.csv"),
            data_folder=repository,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("DataFolderInsideRepository"))


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

    def test_extreme_exponent_price_fails_the_decimal_gate_controlled(self):
        outcome = self.qualify(
            "timestamp,bid,ask\n2014-05-05 08:00:00.000,1e999999999,1e999999999\n"
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertIn("SourcePriceExceedsLeanDecimalFormat", outcome.failures)
        self.assertEqual(outcome.manifest["counts"]["accepted_row_count"], 1)
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
        self.assertTrue(outcome.failures[0].startswith("OutputsExistWithoutForce"))

    def test_missing_runtime_market_hours_database_is_a_configuration_error(self):
        data = self.root / "no-market-hours"
        (data / "symbol-properties").mkdir(parents=True)
        shutil.copyfile(
            self.data / "symbol-properties" / "symbol-properties-database.csv",
            data / "symbol-properties" / "symbol-properties-database.csv",
        )
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "no-db.csv"),
            data_folder=data,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("MarketHoursDatabaseUnusable"))

    def test_missing_symbol_properties_is_a_configuration_error(self):
        (self.data / "symbol-properties" / "symbol-properties-database.csv").unlink()
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "no-symbol-properties.csv"),
            data_folder=self.data,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("SymbolPropertiesDatabaseMissing"))

    def test_unreadable_runtime_identity_sidecar_is_a_configuration_error(self):
        from marketlab_historical_data.identity import (
            prepare_runtime_identity,
            runtime_identity_path,
        )

        data = self.root / "identity-data"
        data.mkdir()
        prepare_runtime_identity(
            data_folder=data,
            source_data_folder=self.data,
            symbol="XAUUSD",
            market="dukascopy",
            security_type="Cfd",
        )
        runtime_identity_path(data).write_text("{not json", encoding="utf-8")
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "identity.csv"),
            data_folder=data,
            config=CsvSourceConfig(source_timezone="UTC"),
            symbol="XAUUSD",
            market="dukascopy",
            security_type="Cfd",
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("RuntimeIdentityUnusable"))

    def test_invalid_source_encoding_is_a_configuration_error(self):
        path = self.root / "bad-encoding.csv"
        path.write_bytes(b"timestamp,bid,ask\n\xff\xfe,1.0,1.1\n")
        outcome = run_qualification(
            source_path=path,
            data_folder=self.data,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("SourceLayoutUnusable"))

    def test_csv_parser_error_during_qualification_is_controlled(self):
        path = self.root / "oversized-field.csv"
        path.write_text(
            "timestamp,bid,ask\n2014-05-05 08:00:00.000," + "1" * 200000 + ",1.1\n",
            encoding="utf-8",
        )
        outcome = run_qualification(
            source_path=path,
            data_folder=self.data,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("SourceUnreadable"))

    def test_nul_byte_source_row_is_rejected_without_a_traceback(self):
        path = self.root / "nul.csv"
        path.write_bytes(b"timestamp,bid,ask\n2014-05-05 08:00:00.000,1.0,1.1\n\x00\n")
        outcome = run_qualification(
            source_path=path,
            data_folder=self.data,
            config=CsvSourceConfig(source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertEqual(outcome.manifest["counts"]["rejected_row_count"], 1)

    def test_multi_character_delimiter_is_a_configuration_error(self):
        outcome = run_qualification(
            source_path=self.write_source(PASS_CSV, "multi-delimiter.csv"),
            data_folder=self.data,
            config=CsvSourceConfig(delimiter=";;", source_timezone="UTC"),
            force=False,
        )
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(outcome.failures[0].startswith("SourceLayoutUnusable"))


if __name__ == "__main__":
    unittest.main()
