"""Tracked continuous-history evidence: composition, replay and retirement.

The fixture this module validates is the distilled, market-data-free record of
the continuous LEAN-native history: the composition of the 90 already-qualified
monthly native folders into one data tree, the single uninterrupted LEAN replay
of the complete history, and the retirement of the redundant complete 90-folder
native representations. The per-month values are cross-checked against the
original tracked sweep evidence.
"""

from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"

CONTINUOUS_CONTRACT = "marketlab-continuous-history-evidence-v1"
CONTINUOUS_DIGEST = "sha256:231cf63850cd033ea8167ab7d0017bdfbd7744f40412c1a899c2b9d98942886a"
PARTITION_COUNT = 2332
QUALIFIED_ROWS = 413750130
SOURCE_FILE_SET = "8ce98dd27c2df3166a0dc3ec30c6be4756887f323934a6a0ca1c348592c6f1fd"
DIGEST_CHAIN = "9d29c36bcd5ada21cdbf6f8e8a7ea3601efd5bab65e2acf7b4c3ee0f8b41f769"
MARKET_HOURS_SHA = "325a7abc8214216c9107d45bb4e0a7fd291d2a5d771d3ebed6828d02da72518e"
SYMBOL_PROPERTIES_SHA = "7d52262f53fbec169b6e03c7acb220a73ea4ff95f48c198e4977e2280407d5ed"
SESSION_MAP_SHA = "33fa8fa35d8c9ef6d8b1751cced47657e430b238bb454126d77c010d63434949"
FIRST_CANONICAL_UTC = "2019-01-01T23:00:07.151Z"
LAST_CANONICAL_UTC = "2026-06-30T23:59:59.678Z"
SOURCE_ABSENT_DAYS = 406
UNRELATED_FAILED_REQUESTS = 1
RUNTIME_BINARY_SET = "493ecb9b65f39d78ae231ce8efc9b4d4ca8f2f6d5b3f75d4535850b3d5a19b97"
RETIRED_SET_BYTES = 2706616139
COMPOSER_SOURCE_AGGREGATE = (
    "4d5686bf908c8d0f490f9ceeb858202189c2e7e4a4b56027a3bd94fad6807253"
)


class TrackedContinuousHistoryEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(
            (FIXTURES / "continuous-history-evidence.json").read_text(encoding="utf-8")
        )
        self.original = json.loads(
            (FIXTURES / "full-history-sweep-evidence.json").read_text(encoding="utf-8")
        )
        self.relocation = json.loads(
            (FIXTURES / "xauusd-history-relocation-evidence.json").read_text(encoding="utf-8")
        )

    def test_contract_and_identity(self):
        self.assertEqual(self.fixture["contract"], CONTINUOUS_CONTRACT)
        self.assertEqual(self.fixture["identity"], "XAUUSD/dukascopy/Cfd (always open, UTC/UTC)")

    def test_composition_aggregates_are_the_qualified_ones(self):
        composition = self.fixture["composition"]
        self.assertEqual(composition["month_count"], 90)
        self.assertEqual(composition["months_first"], "2019_01")
        self.assertEqual(composition["months_last"], "2026_06")
        self.assertEqual(composition["partition_count"], PARTITION_COUNT)
        self.assertEqual(composition["source_file_set_sha256"], SOURCE_FILE_SET)
        self.assertEqual(composition["ordered_month_digest_chain_sha256"], DIGEST_CHAIN)
        self.assertEqual(composition["ordered_source_semantic_digest"], CONTINUOUS_DIGEST)
        self.assertEqual(composition["first_canonical_utc"], FIRST_CANONICAL_UTC)
        self.assertEqual(composition["last_canonical_utc"], LAST_CANONICAL_UTC)
        self.assertEqual(composition["market_hours_database_sha256"], MARKET_HOURS_SHA)
        self.assertEqual(composition["symbol_properties_database_sha256"], SYMBOL_PROPERTIES_SHA)
        self.assertEqual(composition["session_map_sha256"], SESSION_MAP_SHA)
        self.assertEqual(
            composition["lean_run_window"], {"start_date": "2019-01-01", "end_date": "2026-06-30"}
        )
        totals = composition["totals"]
        self.assertEqual(totals["accepted_row_count"], QUALIFIED_ROWS)
        self.assertEqual(totals["converted_row_count"], QUALIFIED_ROWS)
        self.assertEqual(totals["raw_row_count"], QUALIFIED_ROWS)
        self.assertEqual(totals["rejected_row_count"], 0)
        self.assertEqual(totals["first_canonical_utc"], FIRST_CANONICAL_UTC)
        self.assertEqual(totals["last_canonical_utc"], LAST_CANONICAL_UTC)
        self.assertIn("xauusd-dukascopy", composition["data_folder"])
        self.assertEqual(composition["source_directory"], self.relocation["relocation"]["new_location"])
        composer = composition["composer_source"]
        self.assertEqual(composer["aggregate_sha256"], COMPOSER_SOURCE_AGGREGATE)
        self.assertEqual(composer["file_count"], len(composer["files"]))
        for digest in composer["files"].values():
            self.assertRegex(digest, r"^[0-9a-f]{64}$")
        recomputed = hashlib.sha256(
            "".join(
                f"{name}:{digest}\n" for name, digest in sorted(composer["files"].items())
            ).encode("utf-8")
        ).hexdigest()
        self.assertEqual(recomputed, composer["aggregate_sha256"])
        self.assertEqual(recomputed, COMPOSER_SOURCE_AGGREGATE)

    def test_months_are_contiguous_and_match_the_original_qualified_evidence(self):
        months = self.fixture["months"]
        self.assertEqual(len(months), 90)
        original = {entry["month"]: entry for entry in self.original["months"]}
        relocation = {
            entry["month"]: entry for entry in self.relocation["requalification"]["months"]
        }
        self.assertEqual([entry["month"] for entry in months], list(original))
        indexes = []
        partition_total = 0
        accepted_total = 0
        for entry in months:
            year, number = entry["month"].split("_")
            indexes.append(int(year) * 12 + int(number))
            reference = original[entry["month"]]
            self.assertEqual(entry["source_file_name"], reference["source_file_name"])
            self.assertEqual(entry["source_sha256"], reference["source_sha256"])
            self.assertEqual(entry["source_size_bytes"], reference["source_size_bytes"])
            self.assertEqual(entry["accepted_row_count"], reference["accepted_row_count"])
            self.assertEqual(
                entry["ordered_source_semantic_digest"], reference["source_semantic_digest"]
            )
            self.assertEqual(
                entry["source_sha256"], relocation[entry["month"]]["source_sha256"]
            )
            partition_total += entry["partition_count"]
            accepted_total += entry["accepted_row_count"]
        self.assertEqual(indexes, list(range(indexes[0], indexes[0] + len(indexes))))
        self.assertEqual(partition_total, PARTITION_COUNT)
        self.assertEqual(accepted_total, QUALIFIED_ROWS)

    def test_continuous_replay_reconciles_the_full_history(self):
        replay = self.fixture["replay"]
        self.assertEqual(replay["overall_qualification"], "PASS")
        self.assertEqual(replay["helper_exit_code"], 0)
        self.assertEqual(replay["probe_qualification"], "PASS")
        self.assertEqual(replay["lean_delivered_row_count"], QUALIFIED_ROWS)
        self.assertEqual(replay["probe_processed_row_count"], QUALIFIED_ROWS)
        self.assertEqual(replay["ordered_lean_delivered_semantic_digest"], CONTINUOUS_DIGEST)
        self.assertEqual(replay["first_canonical_utc"], FIRST_CANONICAL_UTC)
        self.assertEqual(replay["last_canonical_utc"], LAST_CANONICAL_UTC)
        self.assertEqual(replay["missing_native_partitions"], 0)
        self.assertEqual(replay["source_coverage_gap_days"], 0)
        self.assertEqual(replay["native_partition_failed_data_requests"], SOURCE_ABSENT_DAYS)
        self.assertEqual(replay["source_absent_days"], SOURCE_ABSENT_DAYS)
        self.assertEqual(replay["unrelated_failed_data_requests"], UNRELATED_FAILED_REQUESTS)
        self.assertEqual(replay["out_of_window_failed_data_requests"], 0)
        self.assertEqual(
            replay["ordered_lean_delivered_semantic_digest"],
            self.fixture["composition"]["ordered_source_semantic_digest"],
        )
        self.assertEqual(replay["runtime_binary_set_sha256"], RUNTIME_BINARY_SET)
        for digest in (replay["record_sha256"], replay["probe_result_sha256"]):
            self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_exactly_one_complete_native_representation_remains(self):
        retirement = self.fixture["retirement"]
        self.assertTrue(retirement["continuous_is_single_complete_native_representation"])
        sets = retirement["sets"]
        self.assertEqual(len(sets), 2)
        labels = {entry["label"] for entry in sets}
        self.assertIn("requalification-work-root (E:)", labels)
        self.assertIn("retired-workspace original sweep (D:)", labels)
        for entry in sets:
            self.assertEqual(entry["partition_count"], PARTITION_COUNT)
            self.assertEqual(entry["total_size_bytes"], RETIRED_SET_BYTES)
            self.assertEqual(entry["missing"], 0)
            self.assertEqual(entry["hash_mismatches"], 0)
            self.assertEqual(entry["unexpected_partitions"], 0)
            self.assertEqual(entry["remaining_partition_zips"], 0)

    def test_no_native_market_data_is_tracked(self):
        self.assertFalse(list(FIXTURES.glob("*_quote.zip")))
        self.assertFalse(list(FIXTURES.glob("XAUUSD_*_DUKASCOPY_JFOREX_FULL.csv")))


if __name__ == "__main__":
    unittest.main()
