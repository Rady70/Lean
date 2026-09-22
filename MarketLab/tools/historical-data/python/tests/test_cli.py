"""CLI contract tests: explicit audit inputs must not be silently ignored."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parents[1]
if str(PACKAGE_ROOT) not in sys.path:
    sys.path.insert(0, str(PACKAGE_ROOT))

CONTRACT = "marketlab-historical-data-qualification-v1"


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
        "per_day": {"accepted": {"2014-05-05": 1}},
        "semantic": {"ordered_source_semantic_digest": "sha256:" + "c" * 64},
        "native": {"layout": {"zip_directory": "cfd/oanda/tick/xauusd"}, "partitions": []},
        "qualification": {
            "source_qualification": "PASS",
            "native_lean_timestamp_parity": "PASS",
            "native_price_decimal_parity": "PASS",
            "native_conversion": "PASS",
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


if __name__ == "__main__":
    unittest.main()
