"""Tracked relocation evidence: the verified move and the re-qualification.

The fixture this module validates is the distilled, market-data-free record of
the Lean-owned relocation of the qualified Dukascopy/JForex XAUUSD history and
of the full-history re-qualification performed from the new canonical location.
It is self-contained: the source file set, the per-month counts and digests,
the totals, the singleton identity and both aggregate hashes are recomputable
from the fixture alone, and the re-qualified months are cross-checked against
the original tracked full-history evidence.
"""

from __future__ import annotations

import hashlib
import json
import re
import unittest
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"

DOCUMENTED_SOURCE_FILE_SET = (
    "8ce98dd27c2df3166a0dc3ec30c6be4756887f323934a6a0ca1c348592c6f1fd"
)
DOCUMENTED_DIGEST_CHAIN = (
    "9d29c36bcd5ada21cdbf6f8e8a7ea3601efd5bab65e2acf7b4c3ee0f8b41f769"
)
DOCUMENTED_MARKET_HOURS_SHA = (
    "325a7abc8214216c9107d45bb4e0a7fd291d2a5d771d3ebed6828d02da72518e"
)
DOCUMENTED_SYMBOL_PROPERTIES_SHA = (
    "7d52262f53fbec169b6e03c7acb220a73ea4ff95f48c198e4977e2280407d5ed"
)
DOCUMENTED_TOTAL_SIZE_BYTES = 23995922711
DOCUMENTED_QUALIFIED_ROWS = 413750130
DOCUMENTED_FIRST = "2019-01-01T23:00:07.151Z"
DOCUMENTED_LAST = "2026-06-30T23:59:59.678Z"
DOCUMENTED_MAP_SHA = "33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949"
DOCUMENTED_CANONICAL_SOURCE = r"E:\MarketLab\data\XAUUSD_raw_history"
DOCUMENTED_REQUALIFICATION_HEAD = "7d424e3d25591646a6a27e5be257f49c21c7486d"
DOCUMENTED_REQUALIFICATION_CONVERTER = (
    "ed64e293d89a03f5cbde1fa0a981055bea2b87db437814dfe9aa93efa3f7f292"
)
DOCUMENTED_REQUALIFICATION_RUNTIME_BINARIES = (
    "493ecb9b65f39d78ae231ce8efc9b4d4ca8f2f6d5b3f75d4535850b3d5a19b97"
)
HEX64 = re.compile(r"^[0-9a-f]{64}$")


class RelocationEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(
            (FIXTURES / "xauusd-history-relocation-evidence.json").read_text(
                encoding="utf-8"
            )
        )
        self.original = json.loads(
            (FIXTURES / "full-history-sweep-evidence.json").read_text(encoding="utf-8")
        )

    def test_contract_and_identity(self):
        self.assertEqual(
            self.fixture["contract"],
            "marketlab-xauusd-history-relocation-evidence-v1",
        )
        self.assertEqual(
            self.fixture["identity"], "XAUUSD/dukascopy/Cfd (always open, UTC/UTC)"
        )

    def test_inventory_covers_the_complete_moved_file_set(self):
        dataset = self.fixture["dataset"]
        inventory = self.fixture["relocation"]["inventory"]
        self.assertEqual(dataset["source_file_count"], 90)
        self.assertEqual(dataset["meta_sidecar_file_count"], 89)
        self.assertEqual(dataset["total_file_count"], 179)
        self.assertEqual(dataset["total_size_bytes"], DOCUMENTED_TOTAL_SIZE_BYTES)
        self.assertEqual(dataset["source_file_set_sha256"], DOCUMENTED_SOURCE_FILE_SET)
        self.assertEqual(
            dataset["ordered_month_digest_chain_sha256"], DOCUMENTED_DIGEST_CHAIN
        )
        self.assertEqual(dataset["first_qualified_timestamp_utc"], DOCUMENTED_FIRST)
        self.assertEqual(dataset["last_qualified_timestamp_utc"], DOCUMENTED_LAST)
        self.assertEqual(len(inventory), 179)
        names = [entry["relative_path"] for entry in inventory]
        self.assertEqual(len(names), len(set(names)))
        sources = [entry for entry in inventory if entry["relative_path"].endswith(".csv")]
        sidecars = [
            entry for entry in inventory if entry["relative_path"].endswith(".meta.txt")
        ]
        self.assertEqual(len(sources), 90)
        self.assertEqual(len(sidecars), 89)
        for entry in inventory:
            self.assertRegex(entry["sha256"], HEX64)
            self.assertGreater(entry["size_bytes"], 0)
            if entry["relative_path"].endswith(".csv"):
                self.assertRegex(
                    entry["relative_path"],
                    r"^XAUUSD_\d{4}_\d{2}_DUKASCOPY_JFOREX_FULL\.csv$",
                )
            else:
                self.assertRegex(
                    entry["relative_path"],
                    r"^XAUUSD_\d{4}_\d{2}_DUKASCOPY_JFOREX_FULL\.csv\.meta\.txt$",
                )
        self.assertEqual(
            sum(entry["size_bytes"] for entry in inventory), DOCUMENTED_TOTAL_SIZE_BYTES
        )
        source_lines = "\n".join(
            f"{entry['relative_path']}:{entry['sha256']}"
            for entry in sorted(sources, key=lambda entry: entry["relative_path"])
        )
        self.assertEqual(
            hashlib.sha256(source_lines.encode("utf-8")).hexdigest(),
            DOCUMENTED_SOURCE_FILE_SET,
        )

    def test_relocation_record_asserts_a_verified_move(self):
        # Filesystem reality (old path absent, one copy present) is re-checked
        # with the PR evidence; this test validates the recorded claims.
        relocation = self.fixture["relocation"]
        self.assertIn("XAUUSD_raw_history", relocation["old_location"])
        self.assertIn("XAUUSD_raw_history", relocation["new_location"])
        self.assertNotEqual(relocation["old_location"], relocation["new_location"])
        self.assertEqual(relocation["pre_move_file_count"], 179)
        self.assertEqual(relocation["post_move_file_count"], 179)
        self.assertEqual(
            relocation["pre_move_total_size_bytes"], DOCUMENTED_TOTAL_SIZE_BYTES
        )
        self.assertEqual(
            relocation["post_move_total_size_bytes"], DOCUMENTED_TOTAL_SIZE_BYTES
        )
        self.assertEqual(relocation["hash_mismatches"], 0)
        self.assertEqual(relocation["missing_files"], 0)
        self.assertEqual(relocation["extra_files"], 0)
        self.assertTrue(relocation["old_location_removed"])

    def test_requalification_reproduces_the_qualified_history(self):
        requalification = self.fixture["requalification"]
        months = requalification["months"]
        self.assertEqual(requalification["month_count"], 90)
        self.assertEqual(requalification["months_pass"], 90)
        self.assertEqual(requalification["months_fail"], 0)
        self.assertEqual(requalification["errors"], [])
        self.assertTrue(requalification["all_counts_equal"])
        self.assertTrue(requalification["all_digests_equal"])
        self.assertTrue(requalification["all_per_partition_equal"])
        self.assertEqual(len(months), 90)
        self.assertEqual(months[0]["month"], "2019_01")
        self.assertEqual(months[-1]["month"], "2026_06")
        indexes = []
        for entry in months:
            year, number = entry["month"].split("_")
            indexes.append(int(year) * 12 + int(number))
            self.assertEqual(
                entry["source_file_name"],
                f"XAUUSD_{entry['month']}_DUKASCOPY_JFOREX_FULL.csv",
            )
            self.assertTrue(entry["first_canonical_utc"].startswith(f"{year}-{number}-"))
            self.assertTrue(entry["last_canonical_utc"].startswith(f"{year}-{number}-"))
            self.assertEqual(entry["rejected_row_count"], 0)
            self.assertEqual(
                (
                    entry["accepted_row_count"],
                    entry["converted_row_count"],
                    entry["lean_delivered_row_count"],
                    entry["probe_processed_row_count"],
                ),
                (entry["accepted_row_count"],) * 4,
            )
            self.assertEqual(entry["session_delivery_difference"], 0)
            self.assertEqual(
                entry["source_semantic_digest"], entry["delivered_semantic_digest"]
            )
        self.assertEqual(indexes, list(range(indexes[0], indexes[0] + len(indexes))))
        for previous, current in zip(months, months[1:]):
            self.assertLess(previous["last_canonical_utc"], current["first_canonical_utc"])
        source_lines = "\n".join(
            f"{entry['source_file_name']}:{entry['source_sha256']}" for entry in months
        )
        self.assertEqual(
            hashlib.sha256(source_lines.encode("utf-8")).hexdigest(),
            DOCUMENTED_SOURCE_FILE_SET,
        )
        chain = "\n".join(entry["source_semantic_digest"] for entry in months)
        self.assertEqual(
            hashlib.sha256(chain.encode("utf-8")).hexdigest(), DOCUMENTED_DIGEST_CHAIN
        )
        totals = requalification["totals"]
        totals_from_months = (
            ("source_size_bytes", "source_size_bytes"),
            ("raw_row_count", "raw_row_count"),
            ("accepted_row_count", "accepted_row_count"),
            ("rejected_row_count", "rejected_row_count"),
            ("converted_row_count", "converted_row_count"),
            ("lean_delivered_row_count", "lean_delivered_row_count"),
            ("probe_processed_row_count", "probe_processed_row_count"),
            ("session_delivery_difference", "session_delivery_difference"),
            ("source_absent_days", "source_absent_day_count"),
            ("source_coverage_gap_days", "source_coverage_gap_day_count"),
            ("missing_native_partitions", "missing_native_partition_count"),
            ("unrelated_failed_data_requests", "unrelated_failed_data_request_count"),
        )
        for total_field, row_field in totals_from_months:
            self.assertEqual(
                totals[total_field], sum(entry[row_field] for entry in months), total_field
            )
        self.assertEqual(totals["accepted_row_count"], DOCUMENTED_QUALIFIED_ROWS)
        self.assertEqual(totals["converted_row_count"], DOCUMENTED_QUALIFIED_ROWS)
        self.assertEqual(totals["lean_delivered_row_count"], DOCUMENTED_QUALIFIED_ROWS)
        self.assertEqual(totals["probe_processed_row_count"], DOCUMENTED_QUALIFIED_ROWS)
        self.assertEqual(totals["rejected_row_count"], 0)
        self.assertEqual(totals["session_delivery_difference"], 0)
        self.assertEqual(totals["missing_native_partitions"], 0)
        self.assertEqual(totals["source_coverage_gap_days"], 0)
        self.assertEqual(requalification["first_delivered_canonical_utc"], DOCUMENTED_FIRST)
        self.assertEqual(requalification["last_delivered_canonical_utc"], DOCUMENTED_LAST)

    def test_requalification_is_bound_to_the_canonical_source(self):
        requalification = self.fixture["requalification"]
        self.assertEqual(requalification["source_directory"], DOCUMENTED_CANONICAL_SOURCE)
        self.assertEqual(self.fixture["relocation"]["new_location"], DOCUMENTED_CANONICAL_SOURCE)
        self.assertEqual(
            self.fixture["session_map_recheck"]["source"], DOCUMENTED_CANONICAL_SOURCE
        )
        months = requalification["months"]
        self.assertEqual(len(months), 90)
        for entry in months:
            source_path = Path(entry["source_path"])
            self.assertEqual(str(source_path.parent), DOCUMENTED_CANONICAL_SOURCE, entry["month"])
            self.assertEqual(source_path.name, entry["source_file_name"], entry["month"])

    def test_requalified_content_matches_the_original_tracked_evidence(self):
        original = {entry["month"]: entry for entry in self.original["months"]}
        requalified = {
            entry["month"]: entry for entry in self.fixture["requalification"]["months"]
        }
        self.assertEqual(list(requalified), list(original))
        compared = (
            "source_file_name",
            "source_sha256",
            "source_size_bytes",
            "raw_row_count",
            "accepted_row_count",
            "rejected_row_count",
            "converted_row_count",
            "lean_delivered_row_count",
            "probe_processed_row_count",
            "session_delivery_difference",
            "source_semantic_digest",
            "delivered_semantic_digest",
            "first_canonical_utc",
            "last_canonical_utc",
        )
        for month, entry in requalified.items():
            reference = original[month]
            for field in compared:
                self.assertEqual(entry[field], reference[field], f"{month} {field}")

    def test_inventory_sources_match_the_requalified_months(self):
        inventory = {
            entry["relative_path"]: entry
            for entry in self.fixture["relocation"]["inventory"]
            if entry["relative_path"].endswith(".csv")
        }
        months = self.fixture["requalification"]["months"]
        self.assertEqual(set(inventory), {entry["source_file_name"] for entry in months})
        for entry in months:
            moved = inventory[entry["source_file_name"]]
            self.assertEqual(moved["sha256"], entry["source_sha256"], entry["month"])
            self.assertEqual(moved["size_bytes"], entry["source_size_bytes"], entry["month"])

    def test_identity_is_singleton_and_measured(self):
        identity = self.fixture["requalification"]["identity"]
        expected = {
            "symbol": "XAUUSD",
            "market": "dukascopy",
            "security_type": "Cfd",
            "native_path": "cfd/dukascopy/tick/xauusd",
            "data_time_zone": "UTC",
            "exchange_time_zone": "UTC",
            "market_hours_entry_key": "Cfd-dukascopy-XAUUSD",
            "market_hours_database_sha256": DOCUMENTED_MARKET_HOURS_SHA,
            "symbol_properties_database_sha256": DOCUMENTED_SYMBOL_PROPERTIES_SHA,
            "runtime_identity_contract": "marketlab-runtime-identity-v1",
            "runtime_identity_derived_market_hours_sha256": DOCUMENTED_MARKET_HOURS_SHA,
            "converter_checkout_head_sha": DOCUMENTED_REQUALIFICATION_HEAD,
            "converter_checkout_dirty": False,
            "converter_source_aggregate_sha256": DOCUMENTED_REQUALIFICATION_CONVERTER,
            "runtime_binary_set_sha256": DOCUMENTED_REQUALIFICATION_RUNTIME_BINARIES,
        }
        for field, value in expected.items():
            self.assertEqual(identity[field], value, field)
        self.assertRegex(identity["converter_source_aggregate_sha256"], HEX64)
        self.assertRegex(identity["runtime_binary_set_sha256"], HEX64)

    def test_session_map_recheck_matches_the_documented_map(self):
        recheck = self.fixture["session_map_recheck"]
        self.assertEqual(recheck["map_sha256"], DOCUMENTED_MAP_SHA)
        stats = recheck["stats"]
        self.assertEqual(stats["contract"], "marketlab-single-anchor-session-map-stats-v1")
        self.assertEqual(stats["sourceRows"], DOCUMENTED_QUALIFIED_ROWS)
        self.assertEqual(stats["sessions"], 1935)
        self.assertEqual(stats["junctions"], 1934)
        self.assertEqual(stats["quoteOnlyRows"], 1347651)
        self.assertEqual(stats["completeSessionQuoteOnlyRows"], 1346849)


if __name__ == "__main__":
    unittest.main()
