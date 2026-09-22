"""Transactional publication: staging, overwrite refusal and cleanup."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data.transactions import (  # noqa: E402
    OutputTransaction,
    OutputTransactionError,
)


class OutputTransactionTests(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)

    def tearDown(self):
        self._directory.cleanup()

    def test_commit_publishes_every_staged_file(self):
        first = self.root / "a" / "one.json"
        second = self.root / "two.zip"
        with OutputTransaction() as transaction:
            transaction.stage_text(first, "one")
            transaction.stage_bytes(second, b"two")
            transaction.commit()
        self.assertEqual(first.read_text(encoding="utf-8"), "one")
        self.assertEqual(second.read_bytes(), b"two")
        self.assertFalse(any(self.root.rglob("*.stage")))

    def test_existing_output_is_refused_without_overwrite(self):
        target = self.root / "one.json"
        target.write_text("old", encoding="utf-8")
        transaction = OutputTransaction()
        with self.assertRaises(OutputTransactionError):
            transaction.stage_text(target, "new")
        self.assertEqual(target.read_text(encoding="utf-8"), "old")

    def test_overwrite_replaces_the_previous_content(self):
        target = self.root / "one.json"
        target.write_text("old", encoding="utf-8")
        with OutputTransaction(allow_overwrite=True) as transaction:
            transaction.stage_text(target, "new")
            transaction.commit()
        self.assertEqual(target.read_text(encoding="utf-8"), "new")

    def test_uncommitted_transaction_leaves_nothing_behind(self):
        target = self.root / "nested" / "one.json"
        with OutputTransaction() as transaction:
            transaction.stage_text(target, "one")
            self.assertTrue(list(self.root.rglob("*.stage")))
        self.assertFalse(target.exists())
        self.assertFalse(any(self.root.rglob("*.stage")))
        self.assertFalse((self.root / "nested").exists())

    def test_missing_stage_fails_the_commit_and_leaves_no_output(self):
        target = self.root / "one.json"
        transaction = OutputTransaction()
        stage = transaction.stage_text(target, "one")
        stage.unlink()
        with self.assertRaises(OutputTransactionError):
            transaction.commit()
        transaction._discard()
        self.assertFalse(target.exists())

    def test_duplicate_registration_is_refused(self):
        target = self.root / "one.json"
        transaction = OutputTransaction()
        transaction.stage_text(target, "one")
        with self.assertRaises(OutputTransactionError):
            transaction.stage_text(target, "two")


if __name__ == "__main__":
    unittest.main()
