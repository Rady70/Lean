"""Strict CSV source qualification: contract, order, decimals, timestamps."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.csv_source import (  # noqa: E402
    CsvSourceConfig,
    QualificationFailure,
    qualify_source,
    resolve_csv_layout,
)

UTC = ZoneInfo("UTC")
NEW_YORK = ZoneInfo("America/New_York")
NICOSIA = ZoneInfo("Europe/Nicosia")

HEADER = "timestamp,bid,ask\n"


class CsvQualificationCase(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)
        self.counter = 0

    def tearDown(self):
        self._directory.cleanup()

    def write_csv(self, text, name=None):
        self.counter += 1
        path = self.root / (name or f"source-{self.counter}.csv")
        path.write_text(text, encoding="utf-8")
        return path

    def qualify(self, text, config=None, source_zone=UTC, data_zone=UTC):
        path = self.write_csv(text)
        config = config or CsvSourceConfig()
        layout = resolve_csv_layout(path, config)
        return qualify_source(path, layout, config, data_zone, source_zone), layout


class SourceContractTests(CsvQualificationCase):
    def test_valid_rows_and_zero_spread_are_accepted(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00.000,1291.6770,1292.0330\n"
            + "2014-05-05 08:00:00.100,1291.680,1291.680\n"
        )
        self.assertTrue(result.source_qualification_passed)
        self.assertEqual(result.counters.accepted_row_count, 2)
        self.assertEqual(result.spread_min, "0")
        self.assertIsNotNone(result.source_semantic_digest)

    def test_crossed_quote_is_rejected(self):
        result, _ = self.qualify(HEADER + "2014-05-05 08:00:00.000,1291.700,1291.600\n")
        self.assertFalse(result.source_qualification_passed)
        self.assertEqual(result.counters.rejection_reasons["ask_less_than_bid"], 1)
        self.assertEqual(result.counters.accepted_row_count, 0)

    def test_non_positive_prices_are_rejected(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00.000,0,1291.6\n"
            + "2014-05-05 08:00:00.001,-1.0,1291.6\n"
            + "2014-05-05 08:00:00.002,1291.6,0\n"
        )
        self.assertEqual(result.counters.rejection_reasons["non_positive_bid"], 2)
        self.assertEqual(result.counters.rejection_reasons["non_positive_ask"], 1)

    def test_malformed_and_blank_numeric_fields_are_rejected(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00.000,abc,1291.6\n"
            + "2014-05-05 08:00:00.001,,1291.6\n"
            + "2014-05-05 08:00:00.002,nan,1291.6\n"
            + "2014-05-05 08:00:00.003,Infinity,1291.6\n"
        )
        self.assertEqual(result.counters.rejection_reasons["invalid_bid"], 3)
        self.assertEqual(result.counters.rejection_reasons["blank_bid"], 1)
        self.assertEqual(result.counters.rejection_reasons["non_positive_bid"], 0)

    def test_exact_exponent_prices_are_accepted_and_canonicalized(self):
        result, _ = self.qualify(HEADER + "2014-05-05 08:00:00.000,1.9e3,2.0e3\n")
        self.assertTrue(result.source_qualification_passed)
        self.assertEqual(result.counters.accepted_row_count, 1)
        self.assertEqual(result.spread_min, "100")
        self.assertEqual(result.spread_max, "100")

    def test_malformed_row_and_empty_row_are_rejected(self):
        result, _ = self.qualify(
            HEADER + "2014-05-05 08:00:00.000,1.0,1.1,extra\n" + "\n"
        )
        self.assertEqual(result.counters.rejection_reasons["malformed_row"], 1)
        self.assertEqual(result.counters.rejection_reasons["empty_row"], 1)

    def test_blank_timestamp_is_rejected(self):
        result, _ = self.qualify(HEADER + ",1.0,1.1\n")
        self.assertEqual(result.counters.rejection_reasons["blank_timestamp"], 1)

    def test_invalid_timestamp_is_rejected(self):
        result, _ = self.qualify(HEADER + "not-a-time,1.0,1.1\n")
        self.assertEqual(result.counters.rejection_reasons["invalid_timestamp"], 1)

    def test_decreasing_timestamp_is_rejected_and_not_sorted(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:01.000,1.0,1.1\n"
            + "2014-05-05 08:00:00.000,2.0,2.1\n"
        )
        self.assertFalse(result.source_qualification_passed)
        self.assertEqual(result.counters.out_of_order_count, 1)
        self.assertEqual(result.counters.rejection_reasons["decreasing_timestamp"], 1)
        self.assertEqual(result.counters.accepted_row_count, 1)

    def test_equal_timestamps_are_preserved_in_source_order(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00.000,1.0,1.1\n"
            + "2014-05-05 08:00:00.000,1.2,1.3\n"
        )
        self.assertEqual(result.counters.accepted_row_count, 2)
        self.assertEqual(result.counters.duplicate_timestamp_count, 1)
        self.assertEqual(result.counters.same_lean_millisecond_collision_count, 0)
        self.assertEqual(result.counters.same_lean_millisecond_collision_groups, 0)
        self.assertEqual(result.counters.maximum_rows_per_lean_millisecond, 2)

    def test_distinct_sub_millisecond_timestamps_in_one_millisecond_collide(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00.123100,1.0,1.1\n"
            + "2014-05-05 08:00:00.123900,1.0,1.1\n"
        )
        self.assertEqual(result.counters.accepted_row_count, 2)
        self.assertEqual(result.counters.duplicate_timestamp_count, 0)
        self.assertEqual(result.counters.sub_millisecond_row_count, 2)
        self.assertEqual(result.counters.same_lean_millisecond_collision_count, 1)
        self.assertEqual(result.counters.same_lean_millisecond_collision_groups, 1)
        self.assertEqual(result.counters.maximum_rows_per_lean_millisecond, 2)

    def test_swapping_equal_timestamps_changes_the_digest(self):
        first, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00.000,1.0,1.1\n"
            + "2014-05-05 08:00:00.000,1.2,1.3\n"
        )
        second, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00.000,1.2,1.3\n"
            + "2014-05-05 08:00:00.000,1.0,1.1\n"
        )
        self.assertNotEqual(first.source_semantic_digest, second.source_semantic_digest)

    def test_duplicate_rows_are_preserved_and_counted(self):
        text = HEADER + "2014-05-05 08:00:00.000,1.0,1.1\n" * 3
        result, _ = self.qualify(text)
        self.assertEqual(result.counters.accepted_row_count, 3)
        self.assertEqual(result.counters.duplicate_timestamp_count, 2)
        self.assertEqual(result.counters.same_lean_millisecond_collision_count, 0)
        self.assertEqual(result.counters.maximum_rows_per_lean_millisecond, 3)

    def test_extreme_exponent_price_fails_the_decimal_gate_without_crashing(self):
        result, _ = self.qualify(
            HEADER + "2014-05-05 08:00:00.000,1e999999999,1e999999999\n"
        )
        self.assertEqual(result.counters.accepted_row_count, 1)
        self.assertEqual(result.nonzero_decimal_unrepresentable_count, 1)
        self.assertFalse(result.decimal_parity_passed)
        self.assertFalse(result.spread_statistics_complete)
        self.assertIsNone(result.source_semantic_digest)
        self.assertIsNone(result.spread_min)

    def test_per_day_and_first_last(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 23:59:59.000,1.0,1.1\n"
            + "2014-05-06 00:00:00.000,1.0,1.1\n"
        )
        self.assertEqual(
            dict(result.counters.per_day_accepted_counts),
            {"2014-05-05": 1, "2014-05-06": 1},
        )
        self.assertEqual(result.first_canonical_utc, "2014-05-05T23:59:59.000Z")
        self.assertEqual(result.last_canonical_utc, "2014-05-06T00:00:00.000Z")


class TimestampPrecisionTests(CsvQualificationCase):
    def test_sub_millisecond_row_fails_the_precision_gate(self):
        result, _ = self.qualify(HEADER + "2014-05-05 08:00:00.123456,1.0,1.1\n")
        self.assertEqual(result.counters.sub_millisecond_row_count, 1)
        self.assertFalse(result.timestamp_precision_passed)
        self.assertIsNone(result.source_semantic_digest)

    def test_microsecond_row_is_millisecond_exact_only_when_the_value_is(self):
        result, _ = self.qualify(HEADER + "2014-05-05 08:00:00.1230000,1.0,1.1\n")
        self.assertEqual(result.counters.sub_millisecond_row_count, 0)
        result, _ = self.qualify(HEADER + "2014-05-05 08:00:00.1230001,1.0,1.1\n")
        self.assertEqual(result.counters.sub_millisecond_row_count, 1)

    def test_collisions_are_measured_on_truncated_milliseconds(self):
        result, _ = self.qualify(HEADER + "2014-05-05 08:00:00.123000,1.0,1.1\n")
        self.assertEqual(result.counters.maximum_rows_per_lean_millisecond, 1)

    def test_dotted_date_formats_measure_the_fraction_after_the_time(self):
        config = CsvSourceConfig(timestamp_format="%Y.%m.%d %H:%M:%S.%f")
        result, _ = self.qualify(HEADER + "2014.05.05 08:00:00.123000,1.0,1.1\n", config=config)
        self.assertEqual(result.counters.sub_millisecond_row_count, 0)
        self.assertEqual(result.counters.accepted_row_count, 1)
        self.assertEqual(result.timestamp_contract.max_fraction_digits, 6)
        result, _ = self.qualify(HEADER + "2014.05.05 08:00:00.1230007,1.0,1.1\n", config=config)
        self.assertEqual(result.counters.sub_millisecond_row_count, 1)
        self.assertFalse(result.timestamp_precision_passed)


class TimestampContractTests(CsvQualificationCase):
    def test_embedded_offset_is_normalized_without_a_source_timezone(self):
        result, _ = self.qualify(
            HEADER + "2014-05-05T08:00:00+02:00,1.0,1.1\n", source_zone=None
        )
        self.assertEqual(result.counters.accepted_row_count, 1)
        self.assertEqual(result.first_canonical_utc, "2014-05-05T06:00:00.000Z")
        self.assertEqual(result.timestamp_contract.representation, "embedded_offset")

    def test_embedded_offset_conflicts_with_a_declared_source_timezone(self):
        result, _ = self.qualify(
            HEADER + "2014-05-05T08:00:00+02:00,1.0,1.1\n", source_zone=UTC
        )
        self.assertEqual(result.counters.rejection_reasons["invalid_timestamp"], 1)

    def test_naive_timestamp_requires_a_source_timezone(self):
        result, _ = self.qualify(
            HEADER + "2014-05-05 08:00:00,1.0,1.1\n", source_zone=None
        )
        self.assertEqual(result.counters.rejection_reasons["invalid_timestamp"], 1)

    def test_naive_timestamp_is_normalized_from_the_source_timezone(self):
        result, _ = self.qualify(
            HEADER + "2014-05-05 11:00:00,1.0,1.1\n", source_zone=ZoneInfo("Europe/Nicosia")
        )
        self.assertEqual(result.first_canonical_utc, "2014-05-05T08:00:00.000Z")

    def test_mixed_representations_fail(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00,1.0,1.1\n"
            + "2014-05-05T08:00:01Z,1.0,1.1\n",
            source_zone=UTC,
        )
        self.assertEqual(result.counters.rejection_reasons["timestamp_representation_mixed"], 1)

    def test_dst_gap_and_fold_are_rejected(self):
        gap, _ = self.qualify(
            HEADER + "2014-03-09 02:30:00,1.0,1.1\n", source_zone=NEW_YORK
        )
        self.assertEqual(gap.counters.rejection_reasons["invalid_timestamp"], 1)
        fold, _ = self.qualify(
            HEADER + "2014-11-02 01:30:00,1.0,1.1\n", source_zone=NEW_YORK
        )
        self.assertEqual(fold.counters.rejection_reasons["invalid_timestamp"], 1)

    def test_explicit_timestamp_format(self):
        config = CsvSourceConfig(timestamp_format="%d/%m/%Y %H:%M:%S")
        result, _ = self.qualify(
            HEADER.replace("timestamp", "timestamp") + "05/05/2014 08:00:00,1.0,1.1\n",
            config=config,
        )
        self.assertEqual(result.first_canonical_utc, "2014-05-05T08:00:00.000Z")


class HeaderAndDelimiterTests(CsvQualificationCase):
    def test_normalized_headers_resolve_without_configuration(self):
        result, layout = self.qualify(
            "<Date>,<Time>,<BID>,<ASK>\n2014-05-05,08:00:00.000,1.10000,1.20000\n"
        )
        self.assertEqual(layout.timestamp_mode, "date_time")
        self.assertEqual(result.counters.accepted_row_count, 1)
        self.assertEqual(result.spread_min, "0.1")

    def test_bid_ask_are_exact_decimal_text(self):
        result, _ = self.qualify(HEADER + "2014-05-05 08:00:00.000,1.10000,1.20000\n")
        self.assertEqual(result.counters.accepted_row_count, 1)
        self.assertEqual(result.spread_max, "0.1")

    def test_explicit_columns_win(self):
        config = CsvSourceConfig(
            timestamp_column="ts", bid_column="b", ask_column="a"
        )
        result, layout = self.qualify(
            "ts,b,a\n2014-05-05 08:00:00.000,1.0,1.1\n", config=config
        )
        self.assertEqual(layout.bid_column, "b")
        self.assertEqual(result.counters.accepted_row_count, 1)

    def test_sniffed_semicolon_delimiter(self):
        result, layout = self.qualify(
            "timestamp;bid;ask\n2014-05-05 08:00:00.000;1.0;1.1\n"
        )
        self.assertEqual(layout.delimiter, ";")
        self.assertEqual(result.counters.accepted_row_count, 1)

    def test_tab_delimiter(self):
        config = CsvSourceConfig(delimiter="\\t")
        result, layout = self.qualify(
            "timestamp\tbid\task\n2014-05-05 08:00:00.000\t1.0\t1.1\n", config=config
        )
        self.assertEqual(layout.delimiter, "\t")
        self.assertEqual(result.counters.accepted_row_count, 1)

    def test_missing_columns_fail_resolution(self):
        path = self.write_csv("a,b\n1,2\n")
        with self.assertRaises(QualificationFailure):
            resolve_csv_layout(path, CsvSourceConfig())

    def test_explicit_unknown_column_fails_resolution(self):
        path = self.write_csv(HEADER + "2014-05-05 08:00:00.000,1.0,1.1\n")
        with self.assertRaises(QualificationFailure):
            resolve_csv_layout(path, CsvSourceConfig(bid_column="missing"))


class SpreadStatisticsTests(CsvQualificationCase):
    def test_spread_statistics_are_exact_decimal_diagnostics(self):
        result, _ = self.qualify(
            HEADER
            + "2014-05-05 08:00:00.000,1.0,1.5\n"
            + "2014-05-05 08:00:00.001,1.0,1.0\n"
            + "2014-05-05 08:00:00.002,1.0,1.2\n"
        )
        self.assertEqual(result.spread_min, "0")
        self.assertEqual(result.spread_max, "0.5")
        self.assertEqual(result.spread_median, "0.2")
        self.assertTrue(result.spread_mean.startswith("0.2333333"))


class SessionPreviewTests(CsvQualificationCase):
    def _evaluator(self):
        import shutil

        from marketlab_historical_data.market_hours import SessionEvaluator, load_market_hours

        data_root = self.root / "data"
        (data_root / "market-hours").mkdir(parents=True)
        shutil.copyfile(
            Path(__file__).resolve().parents[2] / "fixtures" / "market-hours-fixture.json",
            data_root / "market-hours" / "market-hours-database.json",
        )
        hours, _ = load_market_hours(data_root, "Cfd", "oanda", "XAUUSD")
        return SessionEvaluator(hours)

    def test_session_preview_counts_eligible_and_excluded_rows(self):
        evaluator = self._evaluator()
        path = self.write_csv(
            HEADER
            + "2014-05-05 08:00:00.000,1.0,1.1\n"
            + "2014-05-05 21:30:00.000,1.0,1.1\n"
        )
        config = CsvSourceConfig()
        layout = resolve_csv_layout(path, config)
        result = qualify_source(path, layout, config, UTC, UTC, evaluator)
        self.assertIsNotNone(result.session_preview)
        self.assertEqual(result.session_preview.session_eligible_rows, 1)
        self.assertEqual(result.session_preview.session_excluded_rows, 1)
        self.assertTrue(result.session_preview.preview_exact)


if __name__ == "__main__":
    unittest.main()
