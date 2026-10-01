"""Deterministic derived M1 candle cache contract and CLI."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import sys
import tempfile
import unittest
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.candles import (  # noqa: E402
    CANDLE_CONTRACT,
    _midpoint,
    generate_candles,
)
from marketlab_historical_data.canonical import canonical_decimal_text  # noqa: E402
from marketlab_historical_data.cli import main  # noqa: E402
from marketlab_historical_data.lean_native import (  # noqa: E402
    NativeLeanTickLayout,
    NativeTickWriter,
    build_zip_bytes,
)
from marketlab_historical_data.transactions import OutputTransaction  # noqa: E402

UTC = timezone.utc
D = Decimal
JANUARY_FILE = "xauusd-m1-2019-01.csv"


def build_native_tree(data_folder: Path, rows) -> None:
    layout = NativeLeanTickLayout("XAUUSD", "dukascopy", "Cfd")
    transaction = OutputTransaction()
    writer = NativeTickWriter(Path(data_folder), layout, UTC, transaction)
    for timestamp, bid, ask in rows:
        writer.add(timestamp, bid, ask)
    writer.finish()
    transaction.commit()


def candle_lines(out: Path, name: str) -> list[str]:
    return (Path(out) / name).read_text(encoding="utf-8").splitlines()


def load_manifest(out: Path) -> dict:
    return json.loads((Path(out) / "manifest.json").read_text(encoding="utf-8"))


class CandleContractTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.base = Path(self._directory.name)
        self.data = self.base / "data"
        self.out = self.base / "out"

    def tearDown(self):
        self._directory.cleanup()

    def test_exact_mid_ohlc_ticks_and_minute_boundary(self):
        build_native_tree(
            self.data,
            [
                (datetime(2019, 1, 2, 0, 0, 0, 100000, tzinfo=UTC), D("100"), D("101")),
                (datetime(2019, 1, 2, 0, 0, 0, 200000, tzinfo=UTC), D("99.9"), D("100.1")),
                (datetime(2019, 1, 2, 0, 0, 0, 300000, tzinfo=UTC), D("101"), D("102")),
                (datetime(2019, 1, 2, 0, 0, 0, 300000, tzinfo=UTC), D("99"), D("100")),
                (datetime(2019, 1, 2, 0, 1, 0, tzinfo=UTC), D("98"), D("100")),
            ],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        self.assertEqual(
            candle_lines(self.out, JANUARY_FILE),
            [
                "time,open,high,low,close,ticks",
                "2019-01-02T00:00:00.000Z,100.5,101.5,99.5,99.5,4",
                "2019-01-02T00:01:00.000Z,99,99,99,99,1",
            ],
        )
        manifest = load_manifest(self.out)
        self.assertEqual(manifest["totals"]["source_rows"], 5)
        self.assertEqual(manifest["totals"]["candle_rows"], 2)

    def test_only_non_empty_minutes_are_emitted(self):
        build_native_tree(
            self.data,
            [
                (datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2")),
                (datetime(2019, 1, 2, 0, 5, 0, tzinfo=UTC), D("3"), D("4")),
            ],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        lines = candle_lines(self.out, JANUARY_FILE)
        self.assertEqual(
            lines,
            [
                "time,open,high,low,close,ticks",
                "2019-01-02T00:00:00.000Z,1.5,1.5,1.5,1.5,1",
                "2019-01-02T00:05:00.000Z,3.5,3.5,3.5,3.5,1",
            ],
        )
        manifest = load_manifest(self.out)
        self.assertEqual(manifest["files"][0]["rows"], 2)
        self.assertEqual(manifest["empty_minutes"], "absent")
        self.assertEqual(manifest["totals"]["candle_rows"], 2)

    def test_month_splitting_and_manifest_file_hashes_match_the_bytes(self):
        build_native_tree(
            self.data,
            [
                (datetime(2019, 1, 31, 23, 59, 0, tzinfo=UTC), D("1"), D("2")),
                (datetime(2019, 2, 1, 0, 0, 0, tzinfo=UTC), D("3"), D("4")),
            ],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        manifest = load_manifest(self.out)
        self.assertEqual(
            [record["name"] for record in manifest["files"]],
            ["xauusd-m1-2019-01.csv", "xauusd-m1-2019-02.csv"],
        )
        self.assertEqual(manifest["files"][0]["first_candle_utc"], "2019-01-31T23:59:00.000Z")
        self.assertEqual(manifest["files"][0]["last_candle_utc"], "2019-01-31T23:59:00.000Z")
        self.assertEqual(manifest["files"][1]["first_candle_utc"], "2019-02-01T00:00:00.000Z")
        digest = hashlib.sha256()
        for record in manifest["files"]:
            payload = (self.out / record["name"]).read_bytes()
            self.assertEqual(record["bytes"], len(payload))
            self.assertEqual(record["sha256"], hashlib.sha256(payload).hexdigest())
            digest.update(
                f"{record['name']}\0{record['sha256']}\0{record['bytes']}\n".encode("utf-8")
            )
        self.assertEqual(manifest["content_sha256"], digest.hexdigest())
        self.assertEqual(manifest["totals"]["candle_bytes"], sum(r["bytes"] for r in manifest["files"]))

    def test_partition_window_is_inclusive(self):
        build_native_tree(
            self.data,
            [
                (datetime(2019, 1, 1, 0, 0, 0, tzinfo=UTC), D("1"), D("2")),
                (datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("2"), D("3")),
                (datetime(2019, 1, 3, 0, 0, 0, tzinfo=UTC), D("3"), D("4")),
            ],
        )
        outcome = generate_candles(
            self.data, self.out, start=date(2019, 1, 1), end=date(2019, 1, 2)
        )
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        manifest = load_manifest(self.out)
        self.assertEqual(manifest["start_date"], "2019-01-01")
        self.assertEqual(manifest["end_date"], "2019-01-02")
        self.assertEqual(manifest["totals"]["partitions"], 2)
        self.assertNotIn("2019-01-03", "\n".join(candle_lines(self.out, JANUARY_FILE)))

        single = self.base / "single"
        outcome = generate_candles(
            self.data, single, start=date(2019, 1, 2), end=date(2019, 1, 2)
        )
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        manifest = load_manifest(single)
        self.assertEqual(manifest["totals"]["partitions"], 1)
        self.assertEqual([record["rows"] for record in manifest["files"]], [1])

    def test_generation_is_deterministic(self):
        build_native_tree(
            self.data,
            [
                (datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1.10"), D("1.30")),
                (datetime(2019, 1, 2, 0, 0, 1, tzinfo=UTC), D("1.20"), D("1.40")),
            ],
        )
        first = self.base / "first"
        second = self.base / "second"
        first_outcome = generate_candles(self.data, first)
        second_outcome = generate_candles(self.data, second)
        self.assertEqual(first_outcome.exit_code, 0, first_outcome.failures)
        self.assertEqual(second_outcome.exit_code, 0, second_outcome.failures)
        self.assertEqual(
            first_outcome.manifest["content_sha256"],
            second_outcome.manifest["content_sha256"],
        )
        self.assertEqual(
            (first / "manifest.json").read_bytes(), (second / "manifest.json").read_bytes()
        )
        self.assertEqual(
            (first / JANUARY_FILE).read_bytes(), (second / JANUARY_FILE).read_bytes()
        )

    def test_row_outside_the_window_is_not_counted(self):
        build_native_tree(
            self.data,
            [
                (datetime(2019, 1, 1, 0, 0, 0, tzinfo=UTC), D("1"), D("2")),
                (datetime(2019, 1, 1, 0, 1, 0, tzinfo=UTC), D("2"), D("3")),
                (datetime(2019, 1, 3, 0, 0, 0, tzinfo=UTC), D("50"), D("52")),
                (datetime(2019, 1, 3, 0, 1, 0, tzinfo=UTC), D("51"), D("53")),
            ],
        )
        outcome = generate_candles(
            self.data, self.out, start=date(2019, 1, 1), end=date(2019, 1, 2)
        )
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        manifest = load_manifest(self.out)
        self.assertEqual(manifest["totals"]["partitions"], 1)
        self.assertEqual(manifest["totals"]["source_rows"], 2)
        self.assertEqual(
            candle_lines(self.out, JANUARY_FILE),
            [
                "time,open,high,low,close,ticks",
                "2019-01-01T00:00:00.000Z,1.5,1.5,1.5,1.5,1",
                "2019-01-01T00:01:00.000Z,2.5,2.5,2.5,2.5,1",
            ],
        )

    def test_no_partition_in_window_is_refused(self):
        build_native_tree(
            self.data,
            [(datetime(2019, 1, 3, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        outcome = generate_candles(
            self.data, self.out, start=date(2019, 1, 1), end=date(2019, 1, 2)
        )
        self.assertEqual(outcome.exit_code, 1)
        self.assertTrue(outcome.failures)
        self.assertFalse((self.out / "manifest.json").exists())

    def test_stale_candle_file_is_removed_on_a_bounded_rerun(self):
        build_native_tree(
            self.data,
            [
                (datetime(2019, 1, 31, 23, 59, 0, tzinfo=UTC), D("1"), D("2")),
                (datetime(2019, 2, 1, 0, 0, 0, tzinfo=UTC), D("3"), D("4")),
            ],
        )
        first = generate_candles(self.data, self.out)
        self.assertEqual(first.exit_code, 0, first.failures)
        self.assertTrue((self.out / "xauusd-m1-2019-02.csv").is_file())
        second = generate_candles(
            self.data, self.out, start=date(2019, 1, 1), end=date(2019, 1, 31)
        )
        self.assertEqual(second.exit_code, 0, second.failures)
        self.assertFalse((self.out / "xauusd-m1-2019-02.csv").exists())
        self.assertEqual(
            [record["name"] for record in load_manifest(self.out)["files"]],
            [JANUARY_FILE],
        )

    def test_empty_native_partition_is_refused(self):
        layout = NativeLeanTickLayout("XAUUSD", "dukascopy", "Cfd")
        target = layout.zip_path(self.data, date(2019, 1, 2))
        target.parent.mkdir(parents=True)
        target.write_bytes(build_zip_bytes(layout.member_name(date(2019, 1, 2)), b""))
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 1)
        self.assertTrue(outcome.failures)
        self.assertFalse((self.out / "manifest.json").exists())

    def test_foreign_manifest_is_refused(self):
        build_native_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        self.out.mkdir()
        (self.out / "manifest.json").write_text(
            json.dumps({"contract": "not-this-cache"}), encoding="utf-8"
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 1)
        self.assertFalse((self.out / JANUARY_FILE).exists())

    def test_cli_main_returns_zero_and_writes_the_manifest(self):
        build_native_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = main(
                ["candles", "--data-folder", str(self.data), "--out", str(self.out)]
            )
        self.assertEqual(code, 0)
        self.assertIn("content_sha256:", buffer.getvalue())
        manifest = load_manifest(self.out)
        self.assertEqual(manifest["contract"], CANDLE_CONTRACT)
        self.assertTrue((self.out / "manifest.json").is_file())

    def test_invalid_quote_prices_are_refused(self):
        build_native_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("2"), D("1"))],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 1)
        self.assertTrue(any("uncrossed" in failure for failure in outcome.failures))

        negative = self.base / "negative"
        build_native_tree(
            negative,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("0"), D("1"))],
        )
        outcome = generate_candles(negative, self.base / "out-negative")
        self.assertEqual(outcome.exit_code, 1)

    def test_mixed_scale_midpoint_is_exact(self):
        # The helper must stay exact even when the operands have very different scales; the
        # qualified XAUUSD tree is uniform-scale, so this is tested directly rather than through
        # an artificial (and LEAN-decimal-unrepresentable) native partition.
        self.assertEqual(
            canonical_decimal_text(_midpoint(D("1"), D("0.0000000000000000000000000001"))),
            "0.50000000000000000000000000005",
        )
        self.assertEqual(
            canonical_decimal_text(_midpoint(D("0.1"), D("0.2"))),
            "0.15",
        )

    def test_non_utc_composition_is_refused(self):
        build_native_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        qualification = self.data / "marketlab-qualification"
        qualification.mkdir(parents=True)
        (qualification / "continuous-composition.json").write_text(
            json.dumps(
                {
                    "semantic": {
                        "ordered_source_semantic_digest": "sha256:" + "0" * 64
                    },
                    "counts": {"accepted_row_count": 1},
                    "lean": {"data_time_zone": "America/New_York"},
                }
            ),
            encoding="utf-8",
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(any("DataTimeZoneNotUtc" in failure for failure in outcome.failures))
        self.assertFalse((self.out / JANUARY_FILE).exists())


if __name__ == "__main__":
    unittest.main()
