"""Runtime market-hours database resolution and the diagnostic session evaluator."""

from __future__ import annotations

import json
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
        self.assertFalse(hours.always_open)
        self.assertFalse(hours.describe()["always_open"])
        self.assertEqual(len(hours.database_sha256), 64)

    def test_always_open_entry_resolves_as_session_free(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "market-hours").mkdir()
            entry = {
                "dataTimeZone": "UTC",
                "exchangeTimeZone": "UTC",
                **{
                    day: [{"start": "00:00:00", "end": "1.00:00:00", "state": "market"}]
                    for day in (
                        "sunday",
                        "monday",
                        "tuesday",
                        "wednesday",
                        "thursday",
                        "friday",
                        "saturday",
                    )
                },
            }
            (root / "market-hours" / "market-hours-database.json").write_text(
                json.dumps({"entries": {"Cfd-dukascopy-XAUUSD": entry}}), encoding="utf-8"
            )
            hours, _ = load_market_hours(root, "Cfd", "dukascopy", "XAUUSD")
            self.assertTrue(hours.always_open)
            self.assertTrue(hours.describe()["always_open"])
            self.assertIsNone(hours.merged_calendar_key)
            evaluator = SessionEvaluator(hours)
            self.assertTrue(evaluator.is_open(utc(2014, 5, 3, 12, 0)))
            self.assertTrue(evaluator.is_open(utc(2014, 5, 5, 21, 30)))

    def _always_open_database(self, root, exact_entry, wildcard_entry=None, wildcard_first=False):
        entries = {}
        if wildcard_entry is not None and wildcard_first:
            entries["Cfd-dukascopy-[*]"] = wildcard_entry
        entries["Cfd-dukascopy-XAUUSD"] = exact_entry
        if wildcard_entry is not None and not wildcard_first:
            entries["Cfd-dukascopy-[*]"] = wildcard_entry
        (root / "market-hours").mkdir(parents=True, exist_ok=True)
        (root / "market-hours" / "market-hours-database.json").write_text(
            json.dumps({"entries": entries}), encoding="utf-8"
        )

    @staticmethod
    def _open_days():
        return {
            day: [{"start": "00:00:00", "end": "1.00:00:00", "state": "market"}]
            for day in (
                "sunday",
                "monday",
                "tuesday",
                "wednesday",
                "thursday",
                "friday",
                "saturday",
            )
        }

    def test_always_open_is_false_for_any_calendar_or_segment_narrowing(self):
        base = {
            "dataTimeZone": "UTC",
            "exchangeTimeZone": "UTC",
            **self._open_days(),
        }
        narrowings = {
            "holiday": {**base, "holidays": ["1/1/2024"]},
            "early close": {**base, "earlyCloses": {"5/26/2014": "12:00:00"}},
            "late open": {**base, "lateOpens": {"5/27/2014": "13:00:00"}},
            "closed segment": {
                **base,
                "saturday": [{"start": "00:00:00", "end": "12:00:00", "state": "market"}],
            },
            "non-market state": {
                **base,
                "saturday": [{"start": "00:00:00", "end": "1.00:00:00", "state": "premarket"}],
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, entry in narrowings.items():
                with self.subTest(name=name):
                    self._always_open_database(root, entry)
                    hours, _ = load_market_hours(root, "Cfd", "dukascopy", "XAUUSD")
                    self.assertFalse(hours.always_open)

    def test_wildcard_calendar_is_merged_only_when_it_precedes_the_entry(self):
        exact = {
            "dataTimeZone": "UTC",
            "exchangeTimeZone": "UTC",
            **self._open_days(),
            "earlyCloses": {"7/3/2014": "17:00:00"},
        }
        wildcard = {
            "dataTimeZone": "UTC",
            "exchangeTimeZone": "UTC",
            **self._open_days(),
            "holidays": ["1/1/2024"],
            "earlyCloses": {"7/3/2014": "12:00:00", "12/24/2014": "13:00:00"},
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # The engine processes entries in JSON file order and only sees the
            # wildcard when it was already resolved (the converter's sort key is
            # constant because a null symbol becomes '[*]').
            self._always_open_database(root, exact, wildcard, wildcard_first=True)
            merged, _ = load_market_hours(root, "Cfd", "dukascopy", "XAUUSD")
            self.assertEqual(merged.merged_calendar_key, "Cfd-dukascopy-[*]")
            self.assertIn(date(2024, 1, 1), merged.holidays)
            self.assertFalse(merged.always_open)
            self.assertEqual(merged.early_closes[date(2014, 7, 3)], 17 * 3600)
            self.assertEqual(merged.early_closes[date(2014, 12, 24)], 13 * 3600)

            self._always_open_database(root, exact, wildcard, wildcard_first=False)
            unmerged, _ = load_market_hours(root, "Cfd", "dukascopy", "XAUUSD")
            self.assertIsNone(unmerged.merged_calendar_key)
            self.assertEqual(unmerged.holidays, frozenset())
            self.assertFalse(unmerged.always_open)
            self.assertEqual(unmerged.early_closes, {date(2014, 7, 3): 17 * 3600})

            exact_plain = {
                "dataTimeZone": "UTC",
                "exchangeTimeZone": "UTC",
                **self._open_days(),
            }
            self._always_open_database(root, exact_plain, wildcard, wildcard_first=False)
            unmerged_plain, _ = load_market_hours(root, "Cfd", "dukascopy", "XAUUSD")
            self.assertIsNone(unmerged_plain.merged_calendar_key)
            self.assertEqual(unmerged_plain.holidays, frozenset())
            self.assertEqual(unmerged_plain.early_closes, {})
            self.assertTrue(unmerged_plain.always_open)

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

    def test_checkout_database_calendar_merge_follows_file_order(self):
        data_folder = LEAN_ROOT / "Data"
        database = data_folder / "market-hours" / "market-hours-database.json"
        if not database.is_file():
            self.skipTest("checkout market-hours database is not present")
        entries = json.loads(database.read_text(encoding="utf-8-sig"))["entries"]
        keys = list(entries)
        if "Cfd-oanda-[*]" in keys and "Cfd-oanda-XAUUSD" in keys:
            self.assertLess(keys.index("Cfd-oanda-[*]"), keys.index("Cfd-oanda-XAUUSD"))
            oanda, _ = load_market_hours(data_folder, "Cfd", "oanda", "XAUUSD")
            self.assertEqual(oanda.merged_calendar_key, "Cfd-oanda-[*]")
            self.assertFalse(oanda.always_open)
        if "Index-eurex-DAX" in keys and "Index-eurex-[*]" in keys:
            # The exact entry precedes its wildcard, so the engine does not see
            # the wildcard when it resolves the entry; Python must not merge it.
            self.assertLess(keys.index("Index-eurex-DAX"), keys.index("Index-eurex-[*]"))
            eurex, _ = load_market_hours(data_folder, "Index", "eurex", "DAX")
            self.assertIsNone(eurex.merged_calendar_key)
            self.assertEqual(eurex.holidays, frozenset())


if __name__ == "__main__":
    unittest.main()
