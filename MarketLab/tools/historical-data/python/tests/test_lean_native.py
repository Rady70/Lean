"""Native LEAN quote-tick layout, partitioning and deterministic zips."""

from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from datetime import date, datetime, timezone
from decimal import Decimal
from io import BytesIO
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.lean_native import (  # noqa: E402
    NativeConversionError,
    NativeLeanTickLayout,
    NativeTickWriter,
    build_zip_bytes,
    milliseconds_since_local_midnight,
)
from marketlab_historical_data.transactions import OutputTransaction  # noqa: E402

UTC = ZoneInfo("UTC")
NEW_YORK = ZoneInfo("America/New_York")


class MillisecondsTests(unittest.TestCase):
    def test_exact_milliseconds(self):
        self.assertEqual(
            milliseconds_since_local_midnight(
                datetime(2014, 5, 5, 8, 0, 0, 250000, tzinfo=timezone.utc)
            ),
            28800250,
        )
        self.assertEqual(
            milliseconds_since_local_midnight(
                datetime(2014, 5, 5, 23, 59, 59, 999000, tzinfo=timezone.utc)
            ),
            86399999,
        )

    def test_sub_millisecond_is_refused(self):
        with self.assertRaises(NativeConversionError):
            milliseconds_since_local_midnight(
                datetime(2014, 5, 5, 8, 0, 0, 250500, tzinfo=timezone.utc)
            )


class LayoutTests(unittest.TestCase):
    def test_names_follow_the_repository_format(self):
        layout = NativeLeanTickLayout("XAUUSD", "oanda", "Cfd")
        self.assertEqual(layout.relative_directory, "cfd/oanda/tick/xauusd")
        self.assertEqual(layout.zip_name(date(2014, 5, 5)), "20140505_quote.zip")
        self.assertEqual(
            layout.member_name(date(2014, 5, 5)), "20140505_xauusd_tick_quote.csv"
        )
        self.assertEqual(
            str(layout.zip_path(Path("root"), date(2014, 5, 5))),
            str(Path("root") / "cfd/oanda/tick/xauusd/20140505_quote.zip"),
        )


class ZipTests(unittest.TestCase):
    def test_zip_is_deterministic_and_readable(self):
        content = b"0,1.1,1.2\n100,1.2,1.3"
        first = build_zip_bytes("20140505_xauusd_tick_quote.csv", content)
        second = build_zip_bytes("20140505_xauusd_tick_quote.csv", content)
        self.assertEqual(first, second)
        with zipfile.ZipFile(BytesIO(first)) as archive:
            self.assertEqual(
                archive.namelist(), ["20140505_xauusd_tick_quote.csv"]
            )
            self.assertEqual(archive.read(archive.namelist()[0]), content)


class WriterTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)

    def tearDown(self):
        self._directory.cleanup()

    def _write(self, layout, data_zone, rows, allow_overwrite=False):
        transaction = OutputTransaction(allow_overwrite=allow_overwrite)
        writer = NativeTickWriter(self.root, layout, data_zone, transaction)
        for timestamp, bid, ask in rows:
            writer.add(timestamp, bid, ask)
        artifacts = writer.finish()
        transaction.commit()
        return artifacts

    def test_partitions_use_the_data_timezone_date_and_milliseconds(self):
        layout = NativeLeanTickLayout("XAUUSD", "oanda", "Cfd")
        artifacts = self._write(
            layout,
            NEW_YORK,
            [
                (datetime(2014, 5, 5, 2, 0, 0, tzinfo=timezone.utc), Decimal("1.0"), Decimal("1.1")),
                (datetime(2014, 5, 5, 2, 30, 0, tzinfo=timezone.utc), Decimal("1.0"), Decimal("1.1")),
            ],
        )
        self.assertEqual(len(artifacts), 1)
        self.assertEqual(artifacts[0].partition, date(2014, 5, 4))
        self.assertEqual(artifacts[0].first_millisecond, 79200000)
        content = (
            self.root / "cfd/oanda/tick/xauusd/20140504_quote.zip"
        ).read_bytes()
        with zipfile.ZipFile(BytesIO(content)) as archive:
            lines = archive.read(archive.namelist()[0]).decode("utf-8").split("\n")
        self.assertEqual(lines[0], "79200000,1,1.1")
        self.assertEqual(lines[1], "81000000,1,1.1")

    def test_day_boundary_rollover_creates_two_partitions(self):
        layout = NativeLeanTickLayout("XAUUSD", "oanda", "Cfd")
        artifacts = self._write(
            layout,
            UTC,
            [
                (datetime(2014, 5, 5, 23, 59, 59, 999000, tzinfo=timezone.utc), Decimal("1"), Decimal("2")),
                (datetime(2014, 5, 6, 0, 0, 0, tzinfo=timezone.utc), Decimal("1"), Decimal("2")),
            ],
        )
        self.assertEqual([artifact.partition for artifact in artifacts], [date(2014, 5, 5), date(2014, 5, 6)])
        self.assertEqual(artifacts[0].last_millisecond, 86399999)
        self.assertEqual(artifacts[1].first_millisecond, 0)

    def test_output_is_deterministic(self):
        layout = NativeLeanTickLayout("XAUUSD", "oanda", "Cfd")
        rows = [
            (datetime(2014, 5, 5, 8, 0, 0, tzinfo=timezone.utc), Decimal("1.10"), Decimal("1.20")),
            (datetime(2014, 5, 5, 8, 0, 0, 1000, tzinfo=timezone.utc), Decimal("1.10"), Decimal("1.20")),
        ]
        first = self._write(layout, UTC, rows)
        second = self._write(layout, UTC, rows, allow_overwrite=True)
        self.assertEqual(first[0].zip_sha256, second[0].zip_sha256)
        self.assertEqual(first[0].member_sha256, second[0].member_sha256)

    def test_decreasing_utc_rows_are_refused(self):
        layout = NativeLeanTickLayout("XAUUSD", "oanda", "Cfd")
        transaction = OutputTransaction()
        writer = NativeTickWriter(self.root, layout, UTC, transaction)
        writer.add(datetime(2014, 5, 5, 8, 0, 1, tzinfo=timezone.utc), Decimal("1"), Decimal("2"))
        with self.assertRaises(NativeConversionError):
            writer.add(datetime(2014, 5, 5, 8, 0, 0, tzinfo=timezone.utc), Decimal("1"), Decimal("2"))

    def test_data_timezone_backwards_clock_is_refused(self):
        layout = NativeLeanTickLayout("XAUUSD", "oanda", "Cfd")
        transaction = OutputTransaction()
        writer = NativeTickWriter(self.root, layout, NEW_YORK, transaction)
        writer.add(datetime(2014, 11, 2, 5, 30, tzinfo=timezone.utc), Decimal("1"), Decimal("2"))
        with self.assertRaises(NativeConversionError):
            writer.add(datetime(2014, 11, 2, 6, 15, tzinfo=timezone.utc), Decimal("1"), Decimal("2"))


if __name__ == "__main__":
    unittest.main()
