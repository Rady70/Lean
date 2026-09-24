"""CLI contract tests: explicit audit inputs must not be silently ignored."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
if str(PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_ROOT))

CONTRACT = "marketlab-historical-data-qualification-v1"
FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"


def usable_manifest():
    return {
        "contract": CONTRACT,
        "source": {"path": "source.csv", "sha256": "a" * 64},
        "lean": {
            "symbol": "XAUUSD",
            "market": "oanda",
            "security_type": "Cfd",
            "data_time_zone": "UTC",
            "exchange_time_zone": "America/New_York",
            "market_hours_database": {"database_sha256": "b" * 64},
            "data_folder": ".",
        },
        "counts": {"accepted_row_count": 1, "converted_row_count": 1},
        "per_day": {"accepted": {"2014-05-05": 1}, "converted": {"2014-05-05": 1}},
        "semantic": {
            "ordered_source_semantic_digest": "sha256:" + "c" * 64,
            "per_partition": {
                "2014-05-05": {"accepted_row_count": 1, "semantic_digest": "sha256:" + "c" * 64}
            },
        },
        "native": {
            "layout": {"zip_directory": "cfd/oanda/tick/xauusd"},
            "converted_row_count": 1,
            "partitions": [],
        },
        "qualification": {
            "source_qualification": "PASS",
            "native_lean_timestamp_parity": "PASS",
            "native_price_decimal_parity": "PASS",
            "native_conversion": "PASS",
            "converted_row_count": 1,
        },
    }


class VerifyCliTests(unittest.TestCase):
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

    def write_manifest(self, directory, payload):
        path = Path(directory) / "manifest.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def test_missing_manifest_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_cli(
                ["verify", "--manifest", str(Path(directory) / "missing.json")]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("manifest not found", result.stderr)

    def test_non_object_manifest_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            manifest.write_text("[1, 2, 3]", encoding="utf-8")
            result = self.run_cli(["verify", "--manifest", str(manifest)])
            self.assertEqual(result.returncode, 2)
            self.assertIn("manifest is not a JSON object", result.stderr)

    def test_manifest_without_the_contract_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, {})
            result = self.run_cli(["verify", "--manifest", str(manifest)])
            self.assertEqual(result.returncode, 2)
            self.assertIn("not a usable MarketLab qualification manifest", result.stderr)

    def test_manifest_missing_a_required_section_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, {"contract": CONTRACT})
            result = self.run_cli(["verify", "--manifest", str(manifest)])
            self.assertEqual(result.returncode, 2)
            self.assertIn("manifest section", result.stderr)

    def test_missing_failed_data_requests_file_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, usable_manifest())
            failed = Path(directory) / "missing-failed-requests.txt"
            result = self.run_cli(
                [
                    "verify",
                    "--manifest",
                    str(manifest),
                    "--failed-data-requests",
                    str(failed),
                ]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("failed-data-requests file not found", result.stderr)

    def test_non_object_probe_result_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, usable_manifest())
            probe = Path(directory) / "probe.json"
            probe.write_text("[1, 2, 3]", encoding="utf-8")
            result = self.run_cli(
                ["verify", "--manifest", str(manifest), "--probe-result", str(probe)]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("not a usable replay probe result", result.stderr)

    def test_probe_with_an_unknown_contract_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, usable_manifest())
            probe = Path(directory) / "probe.json"
            probe.write_text(
                json.dumps(
                    {
                        "contract": "wrong",
                        "completed": True,
                        "qualification": "PASS",
                        "failure_reasons": [],
                        "expected": {},
                        "delivered": {"quote_count": 1, "semantic_digest": "sha256:x"},
                        "comparison": {"engine_quotes_match_delivered": True},
                        "runtime": {
                            "engine_quotes_processed": 1,
                            "data_time_zone": "UTC",
                            "exchange_time_zone": "UTC",
                            "market_hours_database_sha256": "b" * 64,
                        },
                    }
                ),
                encoding="utf-8",
            )
            result = self.run_cli(
                ["verify", "--manifest", str(manifest), "--probe-result", str(probe)]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("contract is missing or unknown", result.stderr)

    def test_missing_probe_result_file_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, usable_manifest())
            probe = Path(directory) / "missing-probe.json"
            result = self.run_cli(
                ["verify", "--manifest", str(manifest), "--probe-result", str(probe)]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("probe result not found", result.stderr)

    def test_non_integer_helper_exit_code_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, usable_manifest())
            result = self.run_cli(
                ["verify", "--manifest", str(manifest), "--helper-exit-code", "not-a-number"]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("invalid int value", result.stderr)

    def test_report_must_not_alias_an_evidence_input(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, usable_manifest())
            result = self.run_cli(
                [
                    "verify",
                    "--manifest",
                    str(manifest),
                    "--report",
                    str(manifest),
                    "--force",
                ]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("must not replace an evidence input", result.stderr)

    def test_corrupt_nested_manifest_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest_payload = usable_manifest()
            manifest_payload["lean"]["market_hours_database"] = "corrupt"
            manifest = self.write_manifest(directory, manifest_payload)
            result = self.run_cli(["verify", "--manifest", str(manifest)])
            self.assertEqual(result.returncode, 2)
            self.assertIn("not a usable MarketLab qualification manifest", result.stderr)

    def test_malformed_runtime_binaries_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, usable_manifest())
            runtime = Path(directory) / "runtime-binaries.json"
            runtime.write_text(json.dumps({"files": {"x.dll": "short"}}), encoding="utf-8")
            result = self.run_cli(
                ["verify", "--manifest", str(manifest), "--runtime-binaries", str(runtime)]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("malformed runtime-binaries evidence", result.stderr)

    def test_probe_with_wrong_field_types_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.write_manifest(directory, usable_manifest())
            probe = Path(directory) / "probe.json"
            probe.write_text(
                json.dumps(
                    {
                        "contract": "marketlab-single-anchor-replay-probe-v1",
                        "completed": True,
                        "qualification": "PASS",
                        "failure_reasons": [],
                        "expected": {
                            "contract": "marketlab-single-anchor-replay-expectation-v1",
                            "accepted_row_count": 1,
                            "ordered_source_semantic_digest": "sha256:" + "c" * 64,
                            "source_file_sha256": "a" * 64,
                        },
                        "delivered": {"quote_count": "one", "semantic_digest": "sha256:x"},
                        "comparison": {"engine_quotes_match_delivered": True},
                        "runtime": {
                            "engine_quotes_processed": 1,
                            "data_time_zone": "UTC",
                            "exchange_time_zone": "UTC",
                            "market_hours_database_sha256": "b" * 64,
                        },
                    }
                ),
                encoding="utf-8",
            )
            result = self.run_cli(
                ["verify", "--manifest", str(manifest), "--probe-result", str(probe)]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("not a usable replay probe result", result.stderr)


class PrepareIdentityCliTests(unittest.TestCase):
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

    def make_folders(self, root):
        source = root / "auxiliary"
        (source / "market-hours").mkdir(parents=True)
        (source / "symbol-properties").mkdir()
        shutil.copyfile(
            FIXTURES / "market-hours-fixture.json",
            source / "market-hours" / "market-hours-database.json",
        )
        (source / "symbol-properties" / "symbol-properties-database.csv").write_text(
            "market,symbol,type,description,quote_currency,contract_multiplier,"
            "minimum_price_variation,lot_size\n\noanda,XAUUSD,cfd,Gold,USD,1,0.001,1\n",
            encoding="utf-8",
        )
        data = root / "data"
        data.mkdir()
        return source, data

    def test_prepare_identity_writes_the_derived_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            source, data = self.make_folders(Path(directory))
            result = self.run_cli(
                [
                    "prepare-identity",
                    "--data-folder",
                    str(data),
                    "--source-data-folder",
                    str(source),
                    "--symbol",
                    "XAUUSD",
                    "--market",
                    "dukascopy",
                    "--security-type",
                    "Cfd",
                    "--json",
                ]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Cfd-dukascopy-XAUUSD", result.stdout)
            self.assertIn("always open", result.stdout)
            self.assertIn("marketlab-runtime-identity-v1", result.stdout)
            self.assertTrue((data / "market-hours" / "market-hours-database.json").is_file())
            self.assertTrue(
                (data / "marketlab-qualification" / "runtime-identity.json").is_file()
            )

    def test_prepare_identity_missing_auxiliary_folder_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data"
            data.mkdir()
            result = self.run_cli(
                [
                    "prepare-identity",
                    "--data-folder",
                    str(data),
                    "--source-data-folder",
                    str(root / "nowhere"),
                ]
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("auxiliary data folder not found", result.stderr)

    def test_prepare_identity_conflict_is_a_configuration_error(self):
        with tempfile.TemporaryDirectory() as directory:
            source, data = self.make_folders(Path(directory))
            common = [
                "prepare-identity",
                "--data-folder",
                str(data),
                "--source-data-folder",
                str(source),
            ]
            self.assertEqual(self.run_cli(common).returncode, 0)
            target = data / "market-hours" / "market-hours-database.json"
            target.write_text("{}", encoding="utf-8")
            result = self.run_cli(common)
            self.assertEqual(result.returncode, 2)
            self.assertIn("already exists and differs", result.stderr)


if __name__ == "__main__":
    unittest.main()
