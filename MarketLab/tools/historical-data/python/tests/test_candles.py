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
    COMPOSITION_VERIFICATION_CONTRACT,
    VERIFICATION_CONTRACT,
    _midpoint,
    generate_candles,
    verify_candle_composition,
    verify_candles,
)
from marketlab_historical_data.canonical import canonical_decimal_text  # noqa: E402
from marketlab_historical_data.cli import main  # noqa: E402
from marketlab_historical_data.continuous import COMPOSITION_CONTRACT  # noqa: E402
from marketlab_historical_data.lean_native import (  # noqa: E402
    NativeLeanTickLayout,
    NativeTickWriter,
    build_zip_bytes,
)
from marketlab_historical_data.replay import (  # noqa: E402
    MANIFEST_CONTRACT,
    RECORD_CONTRACT,
)
from marketlab_historical_data.transactions import OutputTransaction  # noqa: E402

UTC = timezone.utc
D = Decimal
JANUARY_FILE = "xauusd-m1-2019-01.csv"
COMPOSITION_RELATIVE = Path("marketlab-qualification") / "continuous-composition.json"
RECORD_RELATIVE = Path("marketlab-qualification") / "continuous-qualification-record.json"


def build_native_tree(data_folder: Path, rows):
    layout = NativeLeanTickLayout("XAUUSD", "dukascopy", "Cfd")
    transaction = OutputTransaction()
    writer = NativeTickWriter(Path(data_folder), layout, UTC, transaction)
    for timestamp, bid, ask in rows:
        writer.add(timestamp, bid, ask)
    artifacts = writer.finish()
    transaction.commit()
    return artifacts


def composition_file(data_folder: Path) -> Path:
    return Path(data_folder) / COMPOSITION_RELATIVE


def qualification_record_file(data_folder: Path) -> Path:
    return Path(data_folder) / RECORD_RELATIVE


def write_composition(data_folder: Path, composition: dict) -> Path:
    path = composition_file(data_folder)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(composition, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return path


def write_qualification_record(
    data_folder: Path, composition_sha256: str, *, overall_qualification: str = "PASS"
) -> Path:
    path = qualification_record_file(data_folder)
    record = {
        "contract": RECORD_CONTRACT,
        "manifest_sha256": composition_sha256,
        "overall_qualification": overall_qualification,
        "continuous": {
            "contract": COMPOSITION_CONTRACT,
            "composition_sha256": composition_sha256,
        },
    }
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def bind_qualification_record(data_folder: Path) -> Path:
    path = composition_file(data_folder)
    return write_qualification_record(
        data_folder, hashlib.sha256(path.read_bytes()).hexdigest()
    )


def build_qualified_tree(data_folder: Path, rows, *, data_time_zone: str = "UTC") -> dict:
    artifacts = build_native_tree(data_folder, rows)
    layout = NativeLeanTickLayout("XAUUSD", "dukascopy", "Cfd")
    total_rows = sum(artifact.row_count for artifact in artifacts)
    semantic_digest = "sha256:" + hashlib.sha256(
        "\n".join(
            f"{artifact.partition.isoformat()}:{artifact.member_sha256}"
            for artifact in artifacts
        ).encode("utf-8")
    ).hexdigest()
    composition = {
        "contract": MANIFEST_CONTRACT,
        "source": {
            "path": str(Path(data_folder) / "fixture-source.csv"),
            "sha256": "0" * 64,
            "size_bytes": 0,
        },
        "lean": {
            "symbol": "XAUUSD",
            "market": "dukascopy",
            "security_type": "Cfd",
            "data_time_zone": data_time_zone,
            "exchange_time_zone": "UTC",
            "market_hours_database": {"database_sha256": "0" * 64},
        },
        "counts": {
            "accepted_row_count": total_rows,
            "converted_row_count": total_rows,
            "raw_row_count": total_rows,
            "rejected_row_count": 0,
        },
        "per_day": {
            "accepted": {
                artifact.partition.isoformat(): artifact.row_count
                for artifact in artifacts
            }
        },
        "semantic": {
            "ordered_source_semantic_digest": semantic_digest,
            "per_partition": {
                artifact.partition.isoformat(): {
                    "accepted_row_count": artifact.row_count,
                    "semantic_digest": "sha256:" + artifact.member_sha256,
                }
                for artifact in artifacts
            },
        },
        "native": {
            "layout": layout.describe(),
            "converted_row_count": total_rows,
            "partitions": [artifact.describe() for artifact in artifacts],
        },
        "qualification": {
            "source_qualification": "PASS",
            "native_lean_timestamp_parity": "PASS",
            "native_price_decimal_parity": "PASS",
            "native_conversion": "PASS",
            "converted_row_count": total_rows,
        },
        "composition": {
            "contract": COMPOSITION_CONTRACT,
            "months_root": "fixture",
            "month_count": len(
                {(artifact.partition.year, artifact.partition.month) for artifact in artifacts}
            ),
            "partition_count": len(artifacts),
            "lean_run_window": {
                "start_date": artifacts[0].partition.isoformat(),
                "end_date": artifacts[-1].partition.isoformat(),
            },
        },
    }
    write_composition(data_folder, composition)
    bind_qualification_record(data_folder)
    return composition


def candle_lines(out: Path, name: str) -> list[str]:
    return (Path(out) / name).read_text(encoding="utf-8").splitlines()


def load_manifest(out: Path) -> dict:
    return json.loads((Path(out) / "manifest.json").read_text(encoding="utf-8"))


THREE_MONTH_ROWS = [
    (datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2")),
    (datetime(2019, 2, 3, 0, 0, 0, tzinfo=UTC), D("3"), D("4")),
    (datetime(2019, 3, 4, 0, 0, 0, tzinfo=UTC), D("5"), D("6")),
]

MONTH_WINDOWS = [
    ("2019-01-01", "2019-01-31"),
    ("2019-02-01", "2019-02-28"),
    ("2019-03-01", "2019-03-31"),
]


def build_three_part_caches(data: Path, base: Path) -> list[Path]:
    build_qualified_tree(data, THREE_MONTH_ROWS)
    parts: list[Path] = []
    for index, (start, end) in enumerate(MONTH_WINDOWS):
        part = base / f"part{index}"
        outcome = generate_candles(
            data, part, start=date.fromisoformat(start), end=date.fromisoformat(end)
        )
        if outcome.exit_code != 0:
            raise AssertionError(f"part {index} generation failed: {outcome.failures}")
        parts.append(part)
    return parts


def merge_candle_caches(part_dirs, out: Path) -> dict:
    manifests = [
        json.loads((Path(part) / "manifest.json").read_text(encoding="utf-8"))
        for part in part_dirs
    ]
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    files: list[dict] = []
    totals = {"partitions": 0, "source_rows": 0, "candle_rows": 0, "candle_bytes": 0}
    for part, manifest in zip(part_dirs, manifests):
        for record in manifest["files"]:
            (out / record["name"]).write_bytes((Path(part) / record["name"]).read_bytes())
            files.append(record)
        for field in totals:
            totals[field] += manifest["totals"][field]
    files.sort(key=lambda record: record["name"])
    digest = hashlib.sha256()
    for record in files:
        digest.update(
            f"{record['name']}\0{record['sha256']}\0{record['bytes']}\n".encode("utf-8")
        )
    final = {
        "contract": manifests[0]["contract"],
        "symbol": manifests[0]["symbol"],
        "market": manifests[0]["market"],
        "resolution": manifests[0]["resolution"],
        "price_basis": manifests[0]["price_basis"],
        "time_basis": manifests[0]["time_basis"],
        "empty_minutes": manifests[0]["empty_minutes"],
        "inputs": manifests[0]["inputs"],
        "start_date": manifests[0]["start_date"],
        "end_date": manifests[-1]["end_date"],
        "totals": totals,
        "files": files,
        "content_sha256": digest.hexdigest(),
    }
    (out / "manifest.json").write_text(
        json.dumps(final, indent=2) + "\n", encoding="utf-8"
    )
    return final


class CandleContractTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.base = Path(self._directory.name)
        self.data = self.base / "data"
        self.out = self.base / "out"

    def tearDown(self):
        self._directory.cleanup()

    def test_exact_mid_ohlc_ticks_and_minute_boundary(self):
        build_qualified_tree(
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
        build_qualified_tree(
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
        build_qualified_tree(
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
        build_qualified_tree(
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
        build_qualified_tree(
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
        build_qualified_tree(
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
        build_qualified_tree(
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
        build_qualified_tree(
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
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        layout = NativeLeanTickLayout("XAUUSD", "dukascopy", "Cfd")
        target = layout.zip_path(self.data, date(2019, 1, 2))
        target.write_bytes(build_zip_bytes(layout.member_name(date(2019, 1, 2)), b""))
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 1)
        self.assertTrue(outcome.failures)
        self.assertFalse((self.out / "manifest.json").exists())

    def test_foreign_manifest_is_refused(self):
        build_qualified_tree(
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
        build_qualified_tree(
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
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("2"), D("1"))],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 1)
        self.assertTrue(any("uncrossed" in failure for failure in outcome.failures))

        negative = self.base / "negative"
        build_qualified_tree(
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
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
            data_time_zone="America/New_York",
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(any("DataTimeZoneNotUtc" in failure for failure in outcome.failures))
        self.assertFalse((self.out / JANUARY_FILE).exists())

    def test_missing_composition_is_refused(self):
        build_native_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(any("QualificationCompositionMissing" in f for f in outcome.failures))
        self.assertFalse((self.out / "manifest.json").exists())

    def test_malformed_composition_is_refused(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        composition_file(self.data).write_text("{not json", encoding="utf-8")
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(
            any("QualificationCompositionUnreadable" in f for f in outcome.failures)
        )

    def test_wrong_composition_contract_is_refused(self):
        composition = build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        composition["contract"] = "not-the-composition-contract"
        write_composition(self.data, composition)
        bind_qualification_record(self.data)
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(any("CompositionStructureUnusable" in f for f in outcome.failures))

    def test_qualification_record_missing_is_refused(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        qualification_record_file(self.data).unlink()
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(any("QualificationRecordMissing" in f for f in outcome.failures))

    def test_qualification_record_not_pass_is_refused(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        composition_sha = hashlib.sha256(composition_file(self.data).read_bytes()).hexdigest()
        write_qualification_record(
            self.data, composition_sha, overall_qualification="FAIL"
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(any("QualificationNotPass" in f for f in outcome.failures))

    def test_qualification_record_wrong_binding_is_refused(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        write_qualification_record(self.data, "0" * 64)
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(
            any("QualificationCompositionBindingMismatch" in f for f in outcome.failures)
        )

    def test_extra_native_partition_is_refused(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        layout = NativeLeanTickLayout("XAUUSD", "dukascopy", "Cfd")
        extra = layout.zip_path(self.data, date(2019, 1, 3))
        extra.write_bytes(build_zip_bytes(layout.member_name(date(2019, 1, 3)), b"0,1,2"))
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(
            any("NativePartitionNotInComposition" in f for f in outcome.failures)
        )

    def test_missing_native_partition_is_refused(self):
        build_qualified_tree(
            self.data,
            [
                (datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2")),
                (datetime(2019, 1, 3, 0, 0, 0, tzinfo=UTC), D("3"), D("4")),
            ],
        )
        layout = NativeLeanTickLayout("XAUUSD", "dukascopy", "Cfd")
        layout.zip_path(self.data, date(2019, 1, 3)).unlink()
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 2)
        self.assertTrue(
            any("CompositionPartitionMissing" in f for f in outcome.failures)
        )

    def test_tampered_zip_container_is_refused(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        layout = NativeLeanTickLayout("XAUUSD", "dukascopy", "Cfd")
        target = layout.zip_path(self.data, date(2019, 1, 2))
        target.write_bytes(build_zip_bytes(layout.member_name(date(2019, 1, 2)), b"1000,1,2"))
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 1)
        self.assertTrue(any("zip SHA-256" in f for f in outcome.failures))
        self.assertFalse((self.out / "manifest.json").exists())

    def test_tampered_manifest_row_count_is_refused(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        composition = json.loads(composition_file(self.data).read_text(encoding="utf-8"))
        composition["native"]["partitions"][0]["row_count"] += 1
        write_composition(self.data, composition)
        bind_qualification_record(self.data)
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 1)
        self.assertTrue(any("rows" in f for f in outcome.failures))
        self.assertFalse((self.out / "manifest.json").exists())

    def test_verify_candles_passes_on_a_fresh_cache(self):
        composition = build_qualified_tree(
            self.data,
            [
                (datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2")),
                (datetime(2019, 1, 2, 0, 1, 0, tzinfo=UTC), D("2"), D("3")),
            ],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        verification = verify_candles(self.data, self.out)
        self.assertEqual(verification.exit_code, 0, verification.failures)
        self.assertEqual(verification.record["contract"], VERIFICATION_CONTRACT)
        self.assertEqual(verification.record["overall_qualification"], "PASS")
        self.assertEqual(
            verification.record["composition"]["partitions_verified"],
            len(composition["native"]["partitions"]),
        )

    def test_verify_candles_fails_on_a_tampered_csv(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        target = self.out / JANUARY_FILE
        target.write_bytes(
            target.read_bytes() + b"2019-01-02T00:01:00.000Z,1,1,1,1,1\n"
        )
        verification = verify_candles(self.data, self.out)
        self.assertEqual(verification.exit_code, 1)
        self.assertFalse(verification.record["checks"]["cache_file_records"])
        self.assertTrue(any("CacheFile" in f for f in verification.failures))

    def test_verify_candles_fails_on_a_manifest_total_mismatch(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        manifest = load_manifest(self.out)
        manifest["totals"]["source_rows"] += 1
        (self.out / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        verification = verify_candles(self.data, self.out)
        self.assertEqual(verification.exit_code, 1)
        self.assertFalse(verification.record["checks"]["cache_totals"])
        self.assertTrue(
            any("CacheSourceRowTotalMismatch" in f for f in verification.failures)
        )

    def test_verify_candles_fails_on_a_tampered_manifest_file_hash(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        manifest = load_manifest(self.out)
        manifest["files"][0]["sha256"] = "0" * 64
        (self.out / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        verification = verify_candles(self.data, self.out)
        self.assertEqual(verification.exit_code, 1)
        self.assertFalse(verification.record["checks"]["cache_file_records"])
        self.assertFalse(verification.record["checks"]["cache_content_sha256"])

    def test_cli_verify_candles_writes_the_record(self):
        build_qualified_tree(
            self.data,
            [(datetime(2019, 1, 2, 0, 0, 0, tzinfo=UTC), D("1"), D("2"))],
        )
        outcome = generate_candles(self.data, self.out)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        output = self.base / "candle-verification.json"
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = main(
                [
                    "verify-candles",
                    "--data-folder",
                    str(self.data),
                    "--cache",
                    str(self.out),
                    "--output",
                    str(output),
                ]
            )
        self.assertEqual(code, 0)
        self.assertIn("verify-candles: PASS", buffer.getvalue())
        record = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(record["contract"], VERIFICATION_CONTRACT)
        self.assertEqual(record["overall_qualification"], "PASS")

    def _merged_three_part_cache(self):
        parts = build_three_part_caches(self.data, self.base)
        final_dir = self.base / "final"
        merge_candle_caches(parts, final_dir)
        return parts, final_dir

    def test_verify_candle_composition_passes_on_a_merged_cache(self):
        parts, final_dir = self._merged_three_part_cache()
        outcome = verify_candle_composition(final_dir, parts)
        self.assertEqual(outcome.exit_code, 0, outcome.failures)
        self.assertEqual(
            outcome.record["contract"], COMPOSITION_VERIFICATION_CONTRACT
        )
        self.assertEqual(outcome.record["overall_qualification"], "PASS")
        self.assertTrue(all(outcome.record["checks"].values()))
        self.assertEqual(
            [entry["folder_name"] for entry in outcome.record["parts"]],
            [part.name for part in parts],
        )
        self.assertEqual(outcome.record["final"]["files"], 3)
        self.assertEqual(outcome.record["expected_totals"]["candle_rows"], 3)
        self.assertNotIn(":\\", json.dumps(outcome.record))

    def test_verify_candle_composition_fails_on_a_month_gap(self):
        parts, final_dir = self._merged_three_part_cache()
        outcome = verify_candle_composition(final_dir, [parts[0], parts[2]])
        self.assertEqual(outcome.exit_code, 1)
        self.assertFalse(outcome.record["checks"]["part_month_ranges"])
        self.assertTrue(any("PartMonthGap" in f for f in outcome.failures))

    def test_verify_candle_composition_fails_on_overlapping_parts(self):
        parts, final_dir = self._merged_three_part_cache()
        overlapping = self.base / "overlapping"
        overlapping.mkdir()
        part_ab = overlapping / "part_ab"
        part_bc = overlapping / "part_bc"
        first = generate_candles(
            self.data, part_ab, start=date(2019, 1, 1), end=date(2019, 2, 28)
        )
        second = generate_candles(
            self.data, part_bc, start=date(2019, 2, 1), end=date(2019, 3, 31)
        )
        self.assertEqual(first.exit_code, 0, first.failures)
        self.assertEqual(second.exit_code, 0, second.failures)
        outcome = verify_candle_composition(final_dir, [part_ab, part_bc])
        self.assertEqual(outcome.exit_code, 1)
        self.assertFalse(outcome.record["checks"]["part_month_ranges"])
        self.assertTrue(any("PartMonthOverlap" in f for f in outcome.failures))

    def test_verify_candle_composition_fails_on_a_renamed_part_file(self):
        parts, final_dir = self._merged_three_part_cache()
        manifest_path = parts[1] / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["files"][0]["name"] = "xauusd-m1-2019-02-renamed.csv"
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        outcome = verify_candle_composition(final_dir, parts)
        self.assertEqual(outcome.exit_code, 1)
        self.assertFalse(outcome.record["checks"]["part_month_ranges"])
        self.assertTrue(
            any("PartFileNameNotMonthAligned" in f for f in outcome.failures)
        )

    def test_verify_candle_composition_fails_on_part_final_file_mismatch(self):
        for field, value in (
            ("sha256", "0" * 64),
            ("bytes", 123456789),
            ("rows", 424242),
        ):
            with self.subTest(field=field):
                data = self.base / f"data-{field}"
                case = self.base / f"case-{field}"
                parts = build_three_part_caches(data, case)
                final_dir = case / "final"
                merge_candle_caches(parts, final_dir)
                manifest_path = parts[1] / "manifest.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                manifest["files"][0][field] = value
                manifest_path.write_text(
                    json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
                )
                outcome = verify_candle_composition(final_dir, parts)
                self.assertEqual(outcome.exit_code, 1)
                self.assertFalse(outcome.record["checks"]["file_record_agreement"])

    def test_verify_candle_composition_fails_on_a_total_mismatch(self):
        parts, final_dir = self._merged_three_part_cache()
        manifest_path = final_dir / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["totals"]["candle_rows"] += 1
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        outcome = verify_candle_composition(final_dir, parts)
        self.assertEqual(outcome.exit_code, 1)
        self.assertFalse(outcome.record["checks"]["total_sums"])
        self.assertTrue(any("TotalMismatch" in f for f in outcome.failures))

    def test_verify_candle_composition_fails_on_differing_part_identities(self):
        parts, final_dir = self._merged_three_part_cache()
        manifest_path = parts[1] / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["inputs"]["composition"]["sha256"] = "0" * 64
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        outcome = verify_candle_composition(final_dir, parts)
        self.assertEqual(outcome.exit_code, 1)
        self.assertFalse(outcome.record["checks"]["part_input_identity"])
        self.assertTrue(any("PartInputIdentityMismatch" in f for f in outcome.failures))

    def test_verify_candle_composition_fails_on_a_tampered_final_csv(self):
        parts, final_dir = self._merged_three_part_cache()
        target = final_dir / "xauusd-m1-2019-02.csv"
        target.write_bytes(
            target.read_bytes() + b"2019-02-03T00:01:00.000Z,1,1,1,1,1\n"
        )
        outcome = verify_candle_composition(final_dir, parts)
        self.assertEqual(outcome.exit_code, 1)
        self.assertFalse(outcome.record["checks"]["final_file_hashes"])

    def test_verify_candle_composition_refuses_missing_directories(self):
        outcome = verify_candle_composition(self.base / "missing-cache", [self.base])
        self.assertEqual(outcome.exit_code, 2)
        self.assertIsNone(outcome.record)
        outcome = verify_candle_composition(self.base, [self.base / "missing-part"])
        self.assertEqual(outcome.exit_code, 2)
        self.assertIsNone(outcome.record)

    def test_cli_verify_candle_composition_writes_the_record(self):
        parts, final_dir = self._merged_three_part_cache()
        output = self.base / "candle-composition-verification.json"
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = main(
                [
                    "verify-candle-composition",
                    "--cache",
                    str(final_dir),
                    "--parts",
                    ",".join(str(part) for part in parts),
                    "--output",
                    str(output),
                ]
            )
        self.assertEqual(code, 0)
        self.assertIn("verify-candle-composition: PASS", buffer.getvalue())
        record = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(record["contract"], COMPOSITION_VERIFICATION_CONTRACT)
        self.assertEqual(record["overall_qualification"], "PASS")


if __name__ == "__main__":
    unittest.main()
