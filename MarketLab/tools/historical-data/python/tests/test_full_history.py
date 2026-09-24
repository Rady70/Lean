"""Full-history aggregation: contiguous month records and the aggregate summary."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.summary import (  # noqa: E402
    FullHistorySummaryError,
    build_full_history_summary,
)

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
MH_SHA = "a" * 64
SP_SHA = "b" * 64
CONVERTER_SHA = "c" * 64
HEAD_SHA = "d" * 40
PROBE_SHA = "e" * 64


def month_record(
    month: str,
    *,
    first: str | None = None,
    last: str | None = None,
    accepted: int = 10,
    delivered: int | None = None,
    processed: int | None = None,
    digest: str | None = None,
    market: str = "dukascopy",
    dirty: bool = False,
    source_name: str | None = None,
):
    day = f"{month[:4]}-{month[5:7]}-05"
    first = first or f"{day}T00:00:00.000Z"
    last = last or f"{day}T23:59:59.000Z"
    digest = digest or "sha256:" + hashlib.sha256(month.encode("utf-8")).hexdigest()
    delivered = accepted if delivered is None else delivered
    processed = accepted if processed is None else processed
    source_name = source_name or f"XAUUSD_{month}_DUKASCOPY_JFOREX_FULL.csv"
    manifest = {
        "contract": "marketlab-historical-data-qualification-v1",
        "source": {
            "path": rf"D:\source\{source_name}",
            "sha256": hashlib.sha256(month.encode("utf-8")).hexdigest(),
            "size_bytes": 100,
        },
        "lean": {
            "symbol": "XAUUSD",
            "market": market,
            "security_type": "Cfd",
            "data_time_zone": "UTC",
            "exchange_time_zone": "UTC",
            "market_hours_database": {
                "entry_key": f"Cfd-{market}-XAUUSD",
                "database_sha256": MH_SHA,
                "always_open": True,
            },
            "symbol_properties_database": {"sha256": SP_SHA},
            "runtime_identity": {
                "contract": "marketlab-runtime-identity-v1",
                "derived_market_hours_database": {"sha256": MH_SHA},
            },
            "native_layout": {"zip_directory": f"cfd/{market}/tick/xauusd"},
            "converter_source": {"aggregate_sha256": CONVERTER_SHA},
            "converter_checkout": {"head_sha": HEAD_SHA, "dirty": dirty},
        },
        "counts": {
            "raw_row_count": accepted,
            "accepted_row_count": accepted,
            "rejected_row_count": 0,
            "converted_row_count": accepted,
            "first_canonical_utc": first,
            "last_canonical_utc": last,
        },
        "per_day": {"accepted": {day: accepted}},
        "semantic": {
            "ordered_source_semantic_digest": digest,
            "per_partition": {
                day: {"accepted_row_count": accepted, "semantic_digest": digest}
            },
        },
        "native": {
            "layout": {"zip_directory": f"cfd/{market}/tick/xauusd"},
            "converted_row_count": accepted,
            "partitions": [
                {
                    "partition": day,
                    "zip_relative_path": (
                        f"cfd/{market}/tick/xauusd/{day.replace('-', '')}_quote.zip"
                    ),
                    "zip_sha256": "f" * 64,
                    "row_count": accepted,
                }
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
    return {
        "contract": "marketlab-historical-data-qualification-record-v1",
        "overall_qualification": "PASS",
        "failure_reasons": [],
        "helper_exit_code": 0,
        "manifest_sha256": "1" * 64,
        "manifest": manifest,
        "native_replay": {
            "accepted_row_count": accepted,
            "converted_row_count": accepted,
            "lean_delivered_row_count": delivered,
            "ordered_source_semantic_digest": digest,
            "ordered_lean_delivered_semantic_digest": digest,
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
            "sha256": PROBE_SHA,
            "runtime": {"engine_quotes_processed": processed},
            "delivered": {
                "per_partition": {
                    day: {"quote_count": accepted, "semantic_digest": digest}
                }
            },
        },
        "runtime_binaries": {
            "files": {
                "MarketLab.HistoricalDataProbe.dll": "2" * 64,
                "QuantConnect.Common.dll": "3" * 64,
            }
        },
    }


def write_month(root: Path, month: str, record: dict | None = None, **kwargs) -> Path:
    month_dir = Path(root) / month
    record_path = month_dir / "data" / "marketlab-qualification" / "qualification-record.json"
    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.write_text(
        json.dumps(record if record is not None else month_record(month, **kwargs)),
        encoding="utf-8",
    )
    return record_path


class FullHistorySummaryTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name) / "months"
        self.root.mkdir()

    def tearDown(self):
        self._directory.cleanup()

    def test_contiguous_months_aggregate_with_documented_hashes(self):
        write_month(self.root, "2023_01", accepted=10, digest="sha256:" + "1" * 64)
        write_month(self.root, "2023_02", accepted=20, digest="sha256:" + "2" * 64)
        summary = build_full_history_summary(self.root)
        self.assertEqual(summary["errors"], [])
        self.assertEqual(summary["months_pass"], 2)
        self.assertEqual(summary["totals"]["accepted_row_count"], 30)
        self.assertEqual(summary["totals"]["lean_delivered_row_count"], 30)
        source_lines = "\n".join(
            [
                f"XAUUSD_2023_01_DUKASCOPY_JFOREX_FULL.csv:{hashlib.sha256(b'2023_01').hexdigest()}",
                f"XAUUSD_2023_02_DUKASCOPY_JFOREX_FULL.csv:{hashlib.sha256(b'2023_02').hexdigest()}",
            ]
        )
        self.assertEqual(
            summary["source_file_set_sha256"],
            hashlib.sha256(source_lines.encode("utf-8")).hexdigest(),
        )
        chain = hashlib.sha256(("sha256:" + "1" * 64 + "\n" + "sha256:" + "2" * 64).encode("utf-8"))
        self.assertEqual(summary["ordered_month_digest_chain_sha256"], chain.hexdigest())
        self.assertEqual(summary["month_count"], 2)
        self.assertEqual(len(summary["identity"]["market_hours_database_sha256_set"]), 1)

    def test_month_gap_is_an_error(self):
        write_month(self.root, "2023_01")
        write_month(self.root, "2023_03")
        summary = build_full_history_summary(self.root)
        self.assertTrue(any("not contiguous" in error for error in summary["errors"]))

    def test_overlapping_boundaries_are_an_error(self):
        write_month(self.root, "2023_01", last="2023-02-01T00:00:00.000Z")
        write_month(self.root, "2023_02", first="2023-01-31T00:00:00.000Z")
        summary = build_full_history_summary(self.root)
        self.assertTrue(any("overlap" in error for error in summary["errors"]))

    def test_timestamps_outside_the_month_are_an_error(self):
        write_month(self.root, "2023_01")
        write_month(self.root, "2023_02", first="2023-03-01T00:00:00.000Z")
        summary = build_full_history_summary(self.root)
        self.assertTrue(any("outside the month" in error for error in summary["errors"]))

    def test_count_mismatch_is_an_error(self):
        write_month(self.root, "2023_01")
        write_month(self.root, "2023_02", delivered=19)
        summary = build_full_history_summary(self.root)
        self.assertTrue(any("differ" in error for error in summary["errors"]))

    def test_mixed_identity_is_an_error(self):
        write_month(self.root, "2023_01")
        write_month(self.root, "2023_02", market="oanda")
        summary = build_full_history_summary(self.root)
        self.assertTrue(any("not a singleton" in error for error in summary["errors"]))

    def test_dirty_checkout_is_an_error(self):
        write_month(self.root, "2023_01", dirty=True)
        summary = build_full_history_summary(self.root)
        self.assertTrue(any("not clean" in error for error in summary["errors"]))

    def test_source_name_must_match_the_directory_month(self):
        write_month(self.root, "2023_01", source_name="XAUUSD_2023_02_DUKASCOPY_JFOREX_FULL.csv")
        summary = build_full_history_summary(self.root)
        self.assertTrue(any("is month 2023_02" in error for error in summary["errors"]))

    def test_missing_month_record_is_an_explicit_error(self):
        write_month(self.root, "2023_01")
        (self.root / "2023_02").mkdir()
        with self.assertRaises(FullHistorySummaryError):
            build_full_history_summary(self.root)


class SummarizeHistoryCliTests(unittest.TestCase):
    def run_cli(self, arguments):
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(PACKAGE_ROOT)
        return subprocess.run(
            [sys.executable, "-m", "marketlab_historical_data", *arguments],
            capture_output=True,
            text=True,
            env=environment,
            check=False,
        )

    def test_cli_aggregates_a_valid_sequence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "months"
            root.mkdir()
            write_month(root, "2023_01", accepted=10)
            write_month(root, "2023_02", accepted=20)
            result = self.run_cli(["summarize-history", "--months-root", str(root)])
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertIn("summarize-history: PASS", result.stdout)
            output = root / "full-history-summary.json"
            self.assertTrue(output.is_file())
            summary = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(summary["totals"]["accepted_row_count"], 30)

    def test_cli_reports_an_invalid_sequence_as_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "months"
            root.mkdir()
            write_month(root, "2023_01")
            write_month(root, "2023_03")
            result = self.run_cli(["summarize-history", "--months-root", str(root)])
            self.assertEqual(result.returncode, 1)
            self.assertIn("FAIL: ", result.stderr)

    def test_cli_missing_root_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli(
                ["summarize-history", "--months-root", str(Path(directory) / "missing")]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("months root not found", result.stderr)


class TrackedFullHistoryEvidenceTests(unittest.TestCase):
    """Recomputes the documented aggregates from the tracked distilled evidence."""

    FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
    DOCUMENTED_SOURCE_FILE_SET = (
        "8ce98dd27c2df3166a0dc3ec30c6be4756887f323934a6a0ca1c348592c6f1fd"
    )
    DOCUMENTED_DIGEST_CHAIN = (
        "9d29c36bcd5ada21cdbf6f8e8a7ea3601efd5bab65e2acf7b4c3ee0f8b41f769"
    )

    def setUp(self):
        self.fixture = json.loads(
            (self.FIXTURES / "full-history-sweep-evidence.json").read_text(encoding="utf-8")
        )
        self.months = self.fixture["months"]

    def test_evidence_covers_one_contiguous_ordered_month_sequence(self):
        self.assertEqual(self.fixture["contract"], "marketlab-full-history-qualification-evidence-v1")
        self.assertEqual(self.fixture["identity"], "XAUUSD/dukascopy/Cfd (always open, UTC/UTC)")
        self.assertEqual(len(self.months), 90)
        self.assertEqual(self.months[0]["month"], "2019_01")
        self.assertEqual(self.months[-1]["month"], "2026_06")
        indexes = []
        for entry in self.months:
            year, number = entry["month"].split("_")
            indexes.append(int(year) * 12 + int(number))
            self.assertRegex(
                entry["source_file_name"],
                rf"^XAUUSD_{entry['month']}_DUKASCOPY_JFOREX_FULL\.csv$",
            )
            prefix = f"{year}-{number}-"
            self.assertTrue(entry["first_canonical_utc"].startswith(prefix))
            self.assertTrue(entry["last_canonical_utc"].startswith(prefix))
            self.assertEqual(
                entry["source_semantic_digest"], entry["delivered_semantic_digest"]
            )
            self.assertEqual(entry["rejected_row_count"], 0)
        self.assertEqual(indexes, list(range(indexes[0], indexes[0] + len(indexes))))
        for previous, current in zip(self.months, self.months[1:]):
            self.assertLess(previous["last_canonical_utc"], current["first_canonical_utc"])

    def test_documented_aggregates_are_reproducible_from_the_tracked_evidence(self):
        source_lines = "\n".join(
            f"{entry['source_file_name']}:{entry['source_sha256']}" for entry in self.months
        )
        self.assertEqual(
            hashlib.sha256(source_lines.encode("utf-8")).hexdigest(),
            self.DOCUMENTED_SOURCE_FILE_SET,
        )
        self.assertEqual(
            self.fixture["source_file_set_sha256"], self.DOCUMENTED_SOURCE_FILE_SET
        )
        chain = "\n".join(entry["source_semantic_digest"] for entry in self.months)
        self.assertEqual(
            hashlib.sha256(chain.encode("utf-8")).hexdigest(), self.DOCUMENTED_DIGEST_CHAIN
        )
        self.assertEqual(
            self.fixture["ordered_month_digest_chain_sha256"], self.DOCUMENTED_DIGEST_CHAIN
        )

    def test_evidence_totals_match_the_documented_result(self):
        totals = self.fixture["totals"]
        self.assertEqual(totals["accepted_row_count"], 413750130)
        self.assertEqual(totals["rejected_row_count"], 0)
        self.assertEqual(totals["converted_row_count"], 413750130)
        self.assertEqual(totals["lean_delivered_row_count"], 413750130)
        self.assertEqual(totals["probe_processed_row_count"], 413750130)
        self.assertEqual(
            sum(entry["accepted_row_count"] for entry in self.months),
            totals["accepted_row_count"],
        )
        self.assertEqual(self.months[0]["first_canonical_utc"], "2019-01-01T23:00:07.151Z")
        self.assertEqual(self.months[-1]["last_canonical_utc"], "2026-06-30T23:59:59.678Z")


if __name__ == "__main__":
    unittest.main()
