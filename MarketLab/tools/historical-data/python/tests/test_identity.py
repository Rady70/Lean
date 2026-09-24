"""Runtime identity preparation: derived always-open databases and provenance."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.identity import (  # noqa: E402
    RUNTIME_IDENTITY_CONTRACT,
    RuntimeIdentityError,
    always_open_entry,
    derive_symbol_properties_text,
    entry_key,
    load_runtime_identity,
    prepare_runtime_identity,
    runtime_identity_path,
    symbol_properties_row,
)
from marketlab_historical_data.market_hours import load_market_hours  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
LEAN_ROOT = Path(__file__).resolve().parents[5]

SPDB_HEADER = (
    "market,symbol,type,description,quote_currency,contract_multiplier,"
    "minimum_price_variation,lot_size,market_ticker,minimum_order_size,"
    "price_magnifier,strike_multiplier"
)
SPDB_SAMPLE = (
    SPDB_HEADER
    + "\n\n#\noanda,XAUUSD,cfd,Gold,USD,1,0.001,1\n"
)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class IdentityValueTests(unittest.TestCase):
    def test_entry_key_normalizes_the_security_type(self):
        self.assertEqual(entry_key("XAUUSD", "dukascopy", "cfd"), "Cfd-dukascopy-XAUUSD")
        self.assertEqual(entry_key("XAUUSD", "dukascopy", "Cfd"), "Cfd-dukascopy-XAUUSD")

    def test_always_open_entry_has_no_closed_time(self):
        entry = always_open_entry()
        self.assertEqual(entry["dataTimeZone"], "UTC")
        self.assertEqual(entry["exchangeTimeZone"], "UTC")
        for day in (
            "sunday",
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "saturday",
        ):
            self.assertEqual(
                entry[day], [{"start": "00:00:00", "end": "1.00:00:00", "state": "market"}]
            )
        self.assertNotIn("holidays", entry)

    def test_symbol_properties_row_matches_the_oanda_shape(self):
        self.assertEqual(
            symbol_properties_row("XAUUSD", "dukascopy", "cfd"),
            "dukascopy,XAUUSD,cfd,Gold,USD,1,0.001,1",
        )

    def test_derive_symbol_properties_appends_and_is_idempotent(self):
        row = symbol_properties_row("XAUUSD", "dukascopy", "cfd")
        derived = derive_symbol_properties_text(SPDB_SAMPLE, row)
        self.assertTrue(derived.endswith(row + "\n"))
        self.assertEqual(derive_symbol_properties_text(derived, row), derived)

    def test_derive_symbol_properties_refuses_a_conflicting_row(self):
        conflicting = SPDB_SAMPLE + "dukascopy,XAUUSD,cfd,Silver,USD,1,0.01,1\n"
        with self.assertRaises(RuntimeIdentityError):
            derive_symbol_properties_text(
                conflicting, symbol_properties_row("XAUUSD", "dukascopy", "cfd")
            )

    def test_derive_symbol_properties_requires_a_lean_header(self):
        headerless = "oanda,XAUUSD,cfd,Gold,USD,1,0.001,1\n"
        with self.assertRaises(RuntimeIdentityError):
            derive_symbol_properties_text(
                headerless, symbol_properties_row("XAUUSD", "dukascopy", "cfd")
            )

    def test_derive_symbol_properties_treats_padded_keys_as_lean_does(self):
        padded = SPDB_SAMPLE + " dukascopy,XAUUSD,cfd,Gold,USD,1,0.001,1\n"
        derived = derive_symbol_properties_text(
            padded, symbol_properties_row("XAUUSD", "dukascopy", "cfd")
        )
        # LEAN does not trim market/symbol fields, so the padded row is a
        # different key and the correct row must still be appended.
        self.assertTrue(derived.endswith("dukascopy,XAUUSD,cfd,Gold,USD,1,0.001,1\n"))


class PrepareRuntimeIdentityTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)
        self.source = self.root / "auxiliary"
        (self.source / "market-hours").mkdir(parents=True)
        (self.source / "symbol-properties").mkdir(parents=True)
        shutil.copyfile(
            FIXTURES / "market-hours-fixture.json",
            self.source / "market-hours" / "market-hours-database.json",
        )
        (self.source / "symbol-properties" / "symbol-properties-database.csv").write_text(
            SPDB_SAMPLE, encoding="utf-8"
        )
        self.data = self.root / "data"
        self.data.mkdir()

    def tearDown(self):
        self._directory.cleanup()

    def prepare(self, **overrides):
        arguments = {
            "data_folder": self.data,
            "source_data_folder": self.source,
            "symbol": "XAUUSD",
            "market": "dukascopy",
            "security_type": "Cfd",
            "force": False,
        }
        arguments.update(overrides)
        return prepare_runtime_identity(**arguments)

    def test_prepare_writes_derived_databases_and_provenance(self):
        source_mhdb = self.source / "market-hours" / "market-hours-database.json"
        source_spdb = self.source / "symbol-properties" / "symbol-properties-database.csv"
        source_mhdb_sha = sha256_file(source_mhdb)
        source_spdb_sha = sha256_file(source_spdb)

        payload = self.prepare()

        self.assertEqual(payload["contract"], RUNTIME_IDENTITY_CONTRACT)
        self.assertEqual(payload["entry_key"], "Cfd-dukascopy-XAUUSD")
        self.assertTrue(payload["always_open"])
        self.assertEqual(
            payload["source_market_hours_database"]["sha256"], source_mhdb_sha
        )
        self.assertEqual(
            payload["source_symbol_properties_database"]["sha256"], source_spdb_sha
        )

        derived_mhdb = self.data / "market-hours" / "market-hours-database.json"
        derived_spdb = self.data / "symbol-properties" / "symbol-properties-database.csv"
        self.assertTrue(derived_mhdb.is_file())
        self.assertTrue(derived_spdb.is_file())
        self.assertEqual(
            payload["derived_market_hours_database"]["sha256"], sha256_file(derived_mhdb)
        )
        self.assertEqual(
            payload["derived_symbol_properties_database"]["sha256"], sha256_file(derived_spdb)
        )

        hours, _ = load_market_hours(self.data, "Cfd", "dukascopy", "XAUUSD")
        self.assertTrue(hours.always_open)
        self.assertEqual(hours.data_time_zone, "UTC")
        self.assertEqual(hours.exchange_time_zone, "UTC")
        self.assertEqual(hours.holidays, frozenset())

        self.assertIn(
            "dukascopy,XAUUSD,cfd,Gold,USD,1,0.001,1",
            derived_spdb.read_text(encoding="utf-8"),
        )

        recorded = load_runtime_identity(self.data, "XAUUSD", "dukascopy", "Cfd")
        self.assertEqual(recorded, payload)
        self.assertEqual(
            json.loads(runtime_identity_path(self.data).read_text(encoding="utf-8"))["rule"],
            payload["rule"],
        )
        self.assertEqual(sha256_file(source_mhdb), source_mhdb_sha)
        self.assertEqual(sha256_file(source_spdb), source_spdb_sha)

    def test_prepare_is_idempotent(self):
        self.prepare()
        before = {
            path: sha256_file(path)
            for path in (
                self.data / "market-hours" / "market-hours-database.json",
                self.data / "symbol-properties" / "symbol-properties-database.csv",
                runtime_identity_path(self.data),
            )
        }
        self.prepare()
        after = {path: sha256_file(path) for path in before}
        self.assertEqual(before, after)

    def test_prepare_refuses_a_differing_existing_database_without_force(self):
        self.prepare()
        shutil.copyfile(
            self.source / "market-hours" / "market-hours-database.json",
            self.data / "market-hours" / "market-hours-database.json",
        )
        with self.assertRaises(RuntimeIdentityError):
            self.prepare()
        self.prepare(force=True)
        hours, _ = load_market_hours(self.data, "Cfd", "dukascopy", "XAUUSD")
        self.assertTrue(hours.always_open)

    def test_prepare_requires_the_auxiliary_databases(self):
        (self.source / "market-hours" / "market-hours-database.json").unlink()
        with self.assertRaises(RuntimeIdentityError):
            self.prepare()

    @unittest.skipUnless(sys.platform == "win32", "junction guard is Windows-specific")
    def test_prepare_refuses_a_junctioned_identity_database(self):
        target = self.data / "market-hours"
        source = self.source / "market-hours"
        result = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(target), str(source)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            self.skipTest(f"could not create a junction: {result.stderr.strip()}")
        with self.assertRaises(RuntimeIdentityError):
            self.prepare()

    def test_prepare_refuses_the_checkout_as_the_data_folder(self):
        with self.assertRaises(RuntimeIdentityError):
            self.prepare(data_folder=LEAN_ROOT)


class RecordedIdentityTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.data = Path(self._directory.name) / "data"
        self.data.mkdir()

    def tearDown(self):
        self._directory.cleanup()

    def test_missing_sidecar_returns_none(self):
        self.assertIsNone(load_runtime_identity(self.data, "XAUUSD", "oanda", "Cfd"))

    def test_unreadable_sidecar_is_an_explicit_error(self):
        path = runtime_identity_path(self.data)
        path.parent.mkdir(parents=True)
        path.write_text("not json", encoding="utf-8")
        with self.assertRaises(RuntimeIdentityError):
            load_runtime_identity(self.data, "XAUUSD", "dukascopy", "Cfd")

    def test_sidecar_for_another_identity_returns_none(self):
        path = runtime_identity_path(self.data)
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(
                {
                    "contract": RUNTIME_IDENTITY_CONTRACT,
                    "symbol": "XAUUSD",
                    "market": "fxcm",
                    "security_type": "Cfd",
                }
            ),
            encoding="utf-8",
        )
        self.assertIsNone(load_runtime_identity(self.data, "XAUUSD", "dukascopy", "Cfd"))

    def test_malformed_matching_sidecar_is_an_explicit_error(self):
        path = runtime_identity_path(self.data)
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps(
                {
                    "contract": RUNTIME_IDENTITY_CONTRACT,
                    "symbol": "XAUUSD",
                    "market": "dukascopy",
                    "security_type": "Cfd",
                    "derived_market_hours_database": "not-an-object",
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaises(RuntimeIdentityError):
            load_runtime_identity(self.data, "XAUUSD", "dukascopy", "Cfd")


if __name__ == "__main__":
    unittest.main()
