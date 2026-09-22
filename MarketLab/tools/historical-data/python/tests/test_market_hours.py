"""Runtime market-hours database resolution and the diagnostic session evaluator."""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.market_hours import (  # noqa: E402
    SessionEvaluator,
    load_market_hours,
    parse_market_hours_timespan,
)

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
LEAN_ROOT = Path(__file__).resolve().parents[5]


def utc(year, month, day, hour, minute):
    return datetime(year, month, day, hour, minute, tzinfo=timezone.utc)


class MarketHoursTimespanTests(unittest.TestCase):
    def test_timespans(self):
        self.assertEqual(parse_market_hours_timespan("18:03:00", "start"), 64980)
        self.assertEqual(parse_market_hours_timespan("1.00:00:00", "end"), 86400)
        self.assertEqual(parse_market_hours_timespan("0.00:00:00", "start"), 0)
        self.assertEqual(parse_market_hours_timespan("00:00:00.5000000", "start"), 0)

    def test_invalid_timespan_is_rejected(self):
        with self.assertRaises(Exception):
            parse_market_hours_timespan("nonsense", "start")


class ResolvedMarketHoursTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls._directory.name)
        (cls.root / "market-hours").mkdir()
        shutil.copyfile(
            FIXTURES / "market-hours-fixture.json",
            cls.root / "market-hours" / "market-hours-database.json",
        )

    @classmethod
    def tearDownClass(cls):
        cls._directory.cleanup()

    def test_exact_entry_resolution(self):
        hours, _ = load_market_hours(self.root, "Cfd", "oanda", "XAUUSD")
        self.assertEqual(hours.entry_key, "Cfd-oanda-XAUUSD")
        self.assertEqual(hours.entry_source, "exact")
        self.assertEqual(hours.data_time_zone, "UTC")
        self.assertEqual(hours.exchange_time_zone, "America/New_York")
        self.assertTrue(hours.preview_exact)
        self.assertEqual(len(hours.database_sha256), 64)

    def test_wildcard_entry_resolution(self):
        hours, _ = load_market_hours(self.root, "Cfd", "oanda", "NOTLISTED")
        self.assertEqual(hours.entry_key, "Cfd-oanda-[*]")
        self.assertEqual(hours.entry_source, "wildcard")

    def test_symbol_matching_is_case_insensitive_like_lean(self):
        hours, _ = load_market_hours(self.root, "Cfd", "oanda", "xauusd")
        self.assertEqual(hours.entry_key, "Cfd-oanda-XAUUSD")
        self.assertEqual(hours.entry_source, "exact")

    def test_sessions_break_weekend_and_holiday(self):
        hours, _ = load_market_hours(self.root, "Cfd", "oanda", "XAUUSD")
        evaluator = SessionEvaluator(hours)
        self.assertTrue(evaluator.is_open(utc(2014, 5, 5, 8, 0)))
        self.assertFalse(evaluator.is_open(utc(2014, 5, 5, 21, 30)))
        self.assertFalse(evaluator.is_open(utc(2014, 5, 5, 22, 0)))
        self.assertTrue(evaluator.is_open(utc(2014, 5, 5, 22, 3)))
        self.assertFalse(evaluator.is_open(utc(2014, 5, 3, 12, 0)))
        self.assertTrue(evaluator.is_open(utc(2014, 5, 4, 22, 30)))
        self.assertFalse(evaluator.is_open(utc(2017, 4, 14, 12, 0)))

    def test_market_day_classification(self):
        hours, _ = load_market_hours(self.root, "Cfd", "oanda", "XAUUSD")
        evaluator = SessionEvaluator(hours)
        self.assertTrue(evaluator.is_market_day(date(2014, 5, 5)))
        self.assertFalse(evaluator.is_market_day(date(2014, 5, 3)))
        self.assertTrue(evaluator.is_market_day(date(2014, 5, 4)))
        self.assertFalse(evaluator.is_market_day(date(2017, 4, 14)))

    def test_early_close_is_approximate_and_flagged(self):
        hours, _ = load_market_hours(self.root, "Cfd", "oanda", "EARLYCLOSE")
        evaluator = SessionEvaluator(hours)
        self.assertFalse(hours.preview_exact)
        self.assertTrue(evaluator.is_open(utc(2014, 5, 26, 15, 30)))
        self.assertFalse(evaluator.is_open(utc(2014, 5, 26, 16, 30)))

    def test_unknown_entry_is_an_explicit_error(self):
        with self.assertRaises(Exception):
            load_market_hours(self.root, "Equity", "usa", "AAPL")

    def test_missing_database_is_an_explicit_error(self):
        with self.assertRaises(Exception):
            load_market_hours(self.root / "nowhere", "Cfd", "oanda", "XAUUSD")


class RuntimeDatabaseTests(unittest.TestCase):
    """Validates against the actual runtime database in the checkout when present."""

    def test_checkout_database_resolves_xauusd(self):
        data_folder = LEAN_ROOT / "Data"
        if not (data_folder / "market-hours" / "market-hours-database.json").is_file():
            self.skipTest("checkout market-hours database is not present")
        hours, _ = load_market_hours(data_folder, "Cfd", "oanda", "XAUUSD")
        self.assertEqual(hours.entry_key, "Cfd-oanda-XAUUSD")
        self.assertEqual(hours.data_time_zone, "UTC")
        self.assertEqual(hours.exchange_time_zone, "America/New_York")
        evaluator = SessionEvaluator(hours)
        self.assertFalse(evaluator.is_open(utc(2014, 5, 5, 21, 30)))


if __name__ == "__main__":
    unittest.main()
