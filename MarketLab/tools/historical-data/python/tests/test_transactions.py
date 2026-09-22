"""Transactional publication: staging, overwrite refusal and cleanup."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from marketlab_historical_data import transactions as transactions_module  # noqa: E402
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

    def test_registered_removal_deletes_the_old_file_on_commit(self):
        old = self.root / "old.zip"
        old.write_bytes(b"old")
        new = self.root / "new.json"
        with OutputTransaction() as transaction:
            transaction.register_removal(old)
            transaction.stage_text(new, "new")
            transaction.commit()
        self.assertFalse(old.exists())
        self.assertEqual(new.read_text(encoding="utf-8"), "new")
        self.assertFalse(any(self.root.rglob("*.removed")))

    def test_registered_removal_of_a_missing_file_is_ignored(self):
        old = self.root / "never-existed.zip"
        with OutputTransaction() as transaction:
            transaction.register_removal(old)
            transaction.stage_text(self.root / "new.json", "new")
            transaction.commit()
        self.assertTrue((self.root / "new.json").is_file())

    def test_duplicate_removal_registration_is_refused(self):
        old = self.root / "old.zip"
        old.write_bytes(b"old")
        transaction = OutputTransaction()
        transaction.register_removal(old)
        with self.assertRaises(OutputTransactionError):
            transaction.register_removal(old)

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

    def test_failed_commit_restores_overwritten_and_removed_files(self):
        replaced = self.root / "one.json"
        replaced.write_text("previous", encoding="utf-8")
        removed = self.root / "old.zip"
        removed.write_bytes(b"old-zip")
        real_replace = transactions_module.os.replace

        def failing_replace(source, destination):
            if str(source).endswith(".stage"):
                raise OSError("simulated install failure")
            return real_replace(source, destination)

        with mock.patch.object(transactions_module.os, "replace", side_effect=failing_replace):
            with self.assertRaises(OutputTransactionError) as raised:
                with OutputTransaction(allow_overwrite=True) as transaction:
                    transaction.register_removal(removed)
                    transaction.stage_text(replaced, "new")
                    transaction.commit()
        self.assertIn("was rolled back", str(raised.exception))
        self.assertEqual(replaced.read_text(encoding="utf-8"), "previous")
        self.assertEqual(removed.read_bytes(), b"old-zip")
        self.assertFalse(any(self.root.rglob("*.stage")))
        self.assertFalse(any(self.root.rglob("*.backup")))
        self.assertFalse(any(self.root.rglob("*.removed")))

    def test_incomplete_rollback_is_reported_instead_of_claimed(self):
        removed = self.root / "old.zip"
        removed.write_bytes(b"old-zip")
        real_replace = transactions_module.os.replace

        def failing_install_and_restore(source, destination):
            text = str(source)
            if text.endswith(".stage"):
                raise OSError("simulated install failure")
            if text.endswith(".removed") or text.endswith(".backup"):
                raise OSError("simulated restore failure")
            return real_replace(source, destination)

        with mock.patch.object(
            transactions_module.os, "replace", side_effect=failing_install_and_restore
        ):
            transaction = OutputTransaction()
            transaction.register_removal(removed)
            transaction.stage_text(self.root / "new.json", "new")
            with self.assertRaises(OutputTransactionError) as raised:
                transaction.commit()
        self.assertIn("rollback was incomplete", str(raised.exception))
        transaction._discard()


if __name__ == "__main__":
    unittest.main()
