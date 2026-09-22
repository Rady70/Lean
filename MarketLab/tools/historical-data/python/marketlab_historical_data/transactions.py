"""Transactional publication for qualification outputs.

Adapted and simplified from the retired ``quant_research_app``
``market_data/file_transaction.py`` (source commit recorded in
``PROVENANCE.md``): outputs are written to hidden staging files next to their
final paths, then installed with atomic ``os.replace``. On a failure during
commit, already-installed files are removed and replaced backups are restored,
so a failed conversion does not leave a mixed half-written dataset. Existing
outputs are refused unless overwrite was explicitly requested.
"""

from __future__ import annotations

import os
import uuid
from pathlib import Path

__all__ = ["OutputTransaction", "OutputTransactionError"]


class OutputTransactionError(Exception):
    """An output set cannot be staged, installed or overwritten safely."""


class OutputTransaction:
    """Stages a set of files and publishes them together."""

    def __init__(self, allow_overwrite: bool = False) -> None:
        self._allow_overwrite = allow_overwrite
        self._token = uuid.uuid4().hex
        self._stages: dict[Path, Path] = {}
        self._removals: list[Path] = []
        self._created_directories: list[Path] = []
        self._committed = False

    @property
    def token(self) -> str:
        return self._token

    def register(self, final_path: Path) -> Path:
        """Validates and registers a final output path."""
        final_path = Path(final_path)
        if final_path in self._stages:
            raise OutputTransactionError(f"output is registered twice: {final_path}")
        if final_path.is_dir():
            raise OutputTransactionError(f"output path is a directory: {final_path}")
        if final_path.exists() and not self._allow_overwrite:
            raise OutputTransactionError(
                f"output already exists and overwrite was not requested: {final_path}"
            )
        self._stages[final_path] = final_path.with_name(
            f".{final_path.name}.{self._token}.stage"
        )
        return self._stages[final_path]

    def stage_bytes(self, final_path: Path, payload: bytes) -> Path:
        stage = self.register(final_path)
        self._ensure_parent(stage.parent)
        stage.write_bytes(payload)
        return stage

    def stage_text(self, final_path: Path, text: str, encoding: str = "utf-8") -> Path:
        return self.stage_bytes(final_path, text.encode(encoding))

    def register_removal(self, final_path: Path) -> None:
        """Registers an existing file to be removed when the transaction commits.

        The file is moved to a hidden backup during commit and restored if the
        commit fails, so a failed transaction never removes an old output.
        """
        final_path = Path(final_path)
        if final_path in self._stages:
            raise OutputTransactionError(f"output is staged and removed in one transaction: {final_path}")
        if final_path in self._removals:
            raise OutputTransactionError(f"removal is registered twice: {final_path}")
        if final_path.is_dir():
            raise OutputTransactionError(f"removal path is a directory: {final_path}")
        self._removals.append(final_path)

    def commit(self) -> None:
        """Installs every staged file, rolling back on the first failure."""
        if self._committed:
            raise OutputTransactionError("transaction was already committed")
        for final_path, stage in self._stages.items():
            if not stage.is_file():
                raise OutputTransactionError(f"staged output was not written: {stage}")
            self._ensure_parent(final_path.parent)
        installed: list[Path] = []
        backups: list[tuple[Path, Path]] = []
        removals: list[tuple[Path, Path]] = []
        try:
            for final_path in self._removals:
                if not final_path.exists():
                    continue
                backup = final_path.with_name(f".{final_path.name}.{self._token}.removed")
                os.replace(final_path, backup)
                removals.append((final_path, backup))
            for final_path, stage in self._stages.items():
                if final_path.exists():
                    backup = final_path.with_name(f".{final_path.name}.{self._token}.backup")
                    os.replace(final_path, backup)
                    backups.append((final_path, backup))
                os.replace(stage, final_path)
                installed.append(final_path)
        except OSError as error:
            rollback_errors: list[str] = []
            for final_path in installed:
                try:
                    final_path.unlink()
                except OSError as cleanup_error:
                    rollback_errors.append(f"could not remove {final_path}: {cleanup_error}")
            for final_path, backup in backups:
                try:
                    os.replace(backup, final_path)
                except OSError as cleanup_error:
                    rollback_errors.append(f"could not restore {final_path}: {cleanup_error}")
            for final_path, backup in removals:
                try:
                    os.replace(backup, final_path)
                except OSError as cleanup_error:
                    rollback_errors.append(f"could not restore {final_path}: {cleanup_error}")
            if rollback_errors:
                raise OutputTransactionError(
                    "output publication failed and rollback was incomplete; the outputs may be "
                    "mixed: " + "; ".join(rollback_errors) + f" (original failure: {error})"
                ) from error
            raise OutputTransactionError(f"output publication failed and was rolled back: {error}") from error
        for _, backup in backups + removals:
            try:
                backup.unlink()
            except OSError:
                pass
        self._committed = True

    def _ensure_parent(self, directory: Path) -> None:
        if directory.is_dir():
            return
        missing: list[Path] = []
        current = directory
        while not current.exists():
            missing.append(current)
            if current.parent == current:
                break
            current = current.parent
        directory.mkdir(parents=True, exist_ok=True)
        self._created_directories.extend(missing)

    def _discard(self) -> None:
        for stage in self._stages.values():
            try:
                if stage.exists():
                    stage.unlink()
            except OSError:
                pass
        for directory in sorted(self._created_directories, key=lambda path: len(path.parts), reverse=True):
            try:
                if directory.is_dir() and not any(directory.iterdir()):
                    directory.rmdir()
            except OSError:
                pass

    def __enter__(self) -> "OutputTransaction":
        return self

    def __exit__(self, exc_type, exc, traceback) -> None:
        if not self._committed:
            self._discard()
