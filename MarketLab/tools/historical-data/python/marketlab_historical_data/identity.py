"""Reproducible runtime identity for a historical replay subscription.

PR 1 replays a source through LEAN's native data path. That path resolves the
subscription's data time zone and exchange sessions from
``<data-folder>/market-hours/market-hours-database.json``. The Dukascopy/JForex
XAUUSD source is a 24-hour quote stream whose own gaps are the only session
truth; replaying it under a brokerage calendar (the Oanda XAUUSD entry opens
00:00-16:58 and 18:03-24:00 New York and closes Saturdays) silently removes
legitimate source quotes at the session edges and on the brokerage's holidays.

This module prepares the source-appropriate runtime identity for that replay:
a MarketLab-owned derived market-hours database whose ``Cfd-<market>-<symbol>``
entry is open ``00:00:00``-``24:00:00`` every day with no holidays, early
closes or late opens, plus a matching symbol-properties row. The derivation is
deterministic and recorded in ``marketlab-qualification/runtime-identity.json``
(source database SHA-256, derived database SHA-256, the inserted entry and the
rule), so a qualification run never depends on an undocumented manual edit.

The derived databases are written into the runtime data folder the unchanged
LEAN engine loads. The auxiliary databases they derive from (the engine
fixtures) are never modified.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
from pathlib import Path

from .market_hours import MarketHoursDatabaseError, load_market_hours
from .transactions import OutputTransaction, OutputTransactionError

__all__ = [
    "RUNTIME_IDENTITY_CONTRACT",
    "RUNTIME_IDENTITY_NAME",
    "RuntimeIdentityError",
    "always_open_entry",
    "derive_market_hours_payload",
    "derive_symbol_properties_text",
    "load_runtime_identity",
    "prepare_runtime_identity",
    "runtime_identity_path",
]

RUNTIME_IDENTITY_CONTRACT = "marketlab-runtime-identity-v1"
RUNTIME_IDENTITY_NAME = "runtime-identity.json"

MARKET_HOURS_DIRECTORY = "market-hours"
MARKET_HOURS_DATABASE_NAME = "market-hours-database.json"
SYMBOL_PROPERTIES_DIRECTORY = "symbol-properties"
SYMBOL_PROPERTIES_DATABASE_NAME = "symbol-properties-database.csv"
ARTIFACTS_DIRECTORY = "marketlab-qualification"

ALWAYS_OPEN_DATA_TIME_ZONE = "UTC"
ALWAYS_OPEN_EXCHANGE_TIME_ZONE = "UTC"
_WEEKDAYS = ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")
_DERIVATION_RULE = (
    "copy the auxiliary market-hours database and insert/replace the "
    "{entry_key} entry with an always-open (00:00:00-24:00:00 every day), "
    "holiday-free UTC entry, and append the {market},{symbol},{type} "
    "symbol-properties row when absent; the source databases are never modified"
)


class RuntimeIdentityError(Exception):
    """The runtime identity cannot be prepared, verified or trusted."""


def runtime_identity_path(data_folder: Path) -> Path:
    return Path(data_folder) / ARTIFACTS_DIRECTORY / RUNTIME_IDENTITY_NAME


def always_open_entry() -> dict:
    """The source-appropriate entry: no instant is outside the session."""
    return {
        "dataTimeZone": ALWAYS_OPEN_DATA_TIME_ZONE,
        "exchangeTimeZone": ALWAYS_OPEN_EXCHANGE_TIME_ZONE,
        **{day: [{"start": "00:00:00", "end": "1.00:00:00", "state": "market"}] for day in _WEEKDAYS},
    }


def entry_key(symbol: str, market: str, security_type: str) -> str:
    normalized_type = {"cfd": "Cfd", "forex": "Forex"}.get(
        security_type.strip().lower(), security_type
    )
    return f"{normalized_type}-{market.strip().lower()}-{symbol}"


def symbol_properties_row(symbol: str, market: str, security_type: str) -> str:
    description = "Gold" if symbol.strip().upper() == "XAUUSD" else symbol
    return (
        f"{market.strip().lower()},{symbol},{security_type.strip().lower()},"
        f"{description},USD,1,0.001,1"
    )


def derive_market_hours_payload(source_payload: dict, key: str) -> dict:
    """Deep-copies an engine market-hours database and replaces one entry."""
    if not isinstance(source_payload, dict):
        raise RuntimeIdentityError("the auxiliary market-hours database is not a JSON object")
    entries = source_payload.get("entries")
    if not isinstance(entries, dict):
        raise RuntimeIdentityError("the auxiliary market-hours database has no 'entries' object")
    derived = json.loads(json.dumps(source_payload))
    derived["entries"][key] = always_open_entry()
    return derived


def dump_market_hours_payload(payload: dict) -> bytes:
    return (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def lean_symbol_properties_rows(text: str) -> list[list[str]]:
    """Parses a symbol-properties CSV the way LEAN reads it.

    ``SymbolPropertiesDatabase.FromCsvFile`` drops comment lines (starting
    ``#``) and blank lines, skips the first remaining line as the header, and
    splits the rest on commas without trimming. Keeping the raw fields here
    keeps the derived-row checks honest: a space-padded market or symbol is a
    different LEAN key, not an existing row.
    """
    lines = [
        line for line in text.splitlines() if line.strip() and not line.startswith("#")
    ]
    return [line.split(",") for line in lines[1:]]


def _same_symbol_key(fields: list[str], required: list[str]) -> bool:
    """LEAN key equality for a parsed row: market/symbol as written, type parsed."""
    if len(fields) < 3:
        return False
    return (
        fields[0].lower() == required[0].strip().lower()
        and fields[1] == required[1].strip()
        and fields[2].strip().lower() == required[2].strip().lower()
    )


def derive_symbol_properties_text(source_text: str, row: str) -> str:
    """Appends a symbol-properties row unless an equal row already exists.

    A conflicting row for the same market/symbol/type is refused instead of
    being silently replaced; a source without the LEAN header row is refused
    because LEAN would skip the first data line.
    """
    required = row.split(",")
    header_lines = [
        line for line in source_text.splitlines() if line.strip() and not line.startswith("#")
    ]
    if not header_lines or [
        field.strip().lower() for field in header_lines[0].split(",")[:3]
    ] != ["market", "symbol", "type"]:
        raise RuntimeIdentityError(
            "the auxiliary symbol-properties database has no LEAN header row "
            "(market,symbol,type,...); its first data line would be skipped by LEAN"
        )
    for fields in lean_symbol_properties_rows(source_text):
        if _same_symbol_key(fields, required):
            if fields == required:
                return source_text if source_text.endswith("\n") else source_text + "\n"
            raise RuntimeIdentityError(
                "the auxiliary symbol-properties database already defines "
                f"{fields[0]}/{fields[1]}/{fields[2]} as {','.join(fields)!r}, which conflicts with "
                f"the required row {row!r}; use a clean data folder or resolve the conflict explicitly"
            )
    text = source_text if not source_text or source_text.endswith("\n") else source_text + "\n"
    return text + row + "\n"


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _repository_root(start: Path) -> Path | None:
    current = Path(start).resolve()
    for candidate in (current, *current.parents):
        if (candidate / ".git").exists():
            return candidate
    return None


def _is_reparse_point(path: Path) -> bool:
    try:
        metadata = os.lstat(path)
    except OSError:
        return False
    if os.path.islink(path):
        return True
    attributes = getattr(metadata, "st_file_attributes", 0)
    return bool(attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def _guard_target(data_folder: Path, target: Path) -> None:
    for candidate in (target.parent, target):
        if candidate.exists() and _is_reparse_point(candidate):
            raise RuntimeIdentityError(
                f"the runtime identity path {candidate} is a link/junction; refusing to write "
                "through it into another folder. Use a clean/dedicated research data folder"
            )


def load_runtime_identity(
    data_folder: Path, symbol: str, market: str, security_type: str
) -> dict | None:
    """Returns the recorded identity preparation for this subscription, if any.

    A missing sidecar returns ``None`` (for example the fixture-backed Oanda
    identity). A sidecar that exists but cannot be read is an explicit error: a
    qualification must not silently run without its recorded provenance.
    """
    path = runtime_identity_path(data_folder)
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeIdentityError(
            f"the recorded runtime identity is not readable JSON: {path}: {error}"
        ) from error
    if not isinstance(payload, dict) or payload.get("contract") != RUNTIME_IDENTITY_CONTRACT:
        return None
    if (
        str(payload.get("symbol", "")).upper() != symbol.strip().upper()
        or str(payload.get("market", "")).lower() != market.strip().lower()
        or str(payload.get("security_type", "")).lower() != security_type.strip().lower()
    ):
        return None
    for section in (
        "source_market_hours_database",
        "source_symbol_properties_database",
        "derived_market_hours_database",
        "derived_symbol_properties_database",
    ):
        recorded = payload.get(section)
        if not isinstance(recorded, dict) or not isinstance(recorded.get("sha256"), str) or not recorded["sha256"]:
            raise RuntimeIdentityError(
                f"the recorded runtime identity {path} has a malformed {section!r} section"
            )
    return payload


def prepare_runtime_identity(
    data_folder: Path,
    source_data_folder: Path,
    symbol: str,
    market: str,
    security_type: str,
    force: bool = False,
) -> dict:
    """Derives and publishes the always-open runtime identity for one subscription.

    The auxiliary ``source_data_folder`` provides the unchanged engine fixtures.
    The derived databases are written into ``data_folder`` atomically and only
    when their bytes differ; a differing existing database is refused unless
    ``force`` is given. Returns the recorded provenance payload.
    """
    data_folder = Path(data_folder).resolve()
    source_data_folder = Path(source_data_folder).resolve()
    if not data_folder.is_dir():
        raise RuntimeIdentityError(f"data folder not found: {data_folder}")
    if not source_data_folder.is_dir():
        raise RuntimeIdentityError(f"auxiliary data folder not found: {source_data_folder}")
    worktree_root = _repository_root(Path(__file__))
    if worktree_root is not None:
        try:
            data_folder.relative_to(worktree_root)
        except ValueError:
            pass
        else:
            raise RuntimeIdentityError(
                f"the data folder {data_folder} is inside the Git worktree {worktree_root}; "
                "runtime identity databases and native partitions must stay outside the repository"
            )

    source_market_hours = (
        source_data_folder / MARKET_HOURS_DIRECTORY / MARKET_HOURS_DATABASE_NAME
    )
    source_symbol_properties = (
        source_data_folder / SYMBOL_PROPERTIES_DIRECTORY / SYMBOL_PROPERTIES_DATABASE_NAME
    )
    for path, label in (
        (source_market_hours, "auxiliary market-hours database"),
        (source_symbol_properties, "auxiliary symbol-properties database"),
    ):
        if not path.is_file():
            raise RuntimeIdentityError(f"{label} not found: {path}")

    try:
        source_market_hours_bytes = source_market_hours.read_bytes()
        source_market_hours_payload = json.loads(source_market_hours_bytes.decode("utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeIdentityError(
            f"auxiliary market-hours database is not readable JSON: {source_market_hours}: {error}"
        ) from error
    try:
        source_symbol_properties_text = source_symbol_properties.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as error:
        raise RuntimeIdentityError(
            f"auxiliary symbol-properties database is not readable: {source_symbol_properties}: {error}"
        ) from error

    key = entry_key(symbol, market, security_type)
    derived_market_hours = derive_market_hours_payload(source_market_hours_payload, key)
    market_hours_bytes = dump_market_hours_payload(derived_market_hours)
    row = symbol_properties_row(symbol, market, security_type)
    symbol_properties_text = derive_symbol_properties_text(source_symbol_properties_text, row)
    symbol_properties_bytes = symbol_properties_text.encode("utf-8")

    market_hours_target = data_folder / MARKET_HOURS_DIRECTORY / MARKET_HOURS_DATABASE_NAME
    symbol_properties_target = (
        data_folder / SYMBOL_PROPERTIES_DIRECTORY / SYMBOL_PROPERTIES_DATABASE_NAME
    )
    sidecar_target = runtime_identity_path(data_folder)

    writes: dict[Path, bytes] = {}
    _guard_target(data_folder, sidecar_target)
    for target, desired in (
        (market_hours_target, market_hours_bytes),
        (symbol_properties_target, symbol_properties_bytes),
    ):
        _guard_target(data_folder, target)
        existing = target.read_bytes() if target.is_file() else None
        if existing == desired:
            continue
        if existing is not None and not force:
            raise RuntimeIdentityError(
                f"the runtime identity database {target} already exists and differs from the "
                "required derived identity; pass --force to replace it (it is derived data, not "
                "source data)"
            )
        writes[target] = desired

    required_row = row.split(",")
    exposed_rows = lean_symbol_properties_rows(symbol_properties_text)
    if not any(_same_symbol_key(fields, required_row) for fields in exposed_rows):
        raise RuntimeIdentityError(
            f"the derived symbol-properties database does not expose {required_row[:3]!r} under "
            "LEAN's parser; the auxiliary database shape is not usable"
        )

    payload = {
        "contract": RUNTIME_IDENTITY_CONTRACT,
        "symbol": symbol,
        "market": market.strip().lower(),
        "security_type": security_type,
        "entry_key": key,
        "entry": always_open_entry(),
        "data_time_zone": ALWAYS_OPEN_DATA_TIME_ZONE,
        "exchange_time_zone": ALWAYS_OPEN_EXCHANGE_TIME_ZONE,
        "always_open": True,
        "source_market_hours_database": {
            "path": str(source_market_hours),
            "sha256": _sha256_bytes(source_market_hours_bytes),
        },
        "source_symbol_properties_database": {
            "path": str(source_symbol_properties),
            "sha256": _sha256_file(source_symbol_properties),
        },
        "derived_market_hours_database": {
            "path": str(market_hours_target),
            "sha256": _sha256_bytes(market_hours_bytes),
        },
        "derived_symbol_properties_database": {
            "path": str(symbol_properties_target),
            "sha256": _sha256_bytes(symbol_properties_bytes),
        },
        "rule": _DERIVATION_RULE.format(
            entry_key=key,
            market=market.strip().lower(),
            symbol=symbol,
            type=security_type.strip().lower(),
        ),
    }
    sidecar_bytes = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False).encode("utf-8")
    sidecar_bytes += b"\n"

    try:
        with OutputTransaction(allow_overwrite=True) as transaction:
            for target, desired in sorted(writes.items(), key=lambda item: str(item[0])):
                transaction.stage_bytes(target, desired)
            transaction.stage_bytes(sidecar_target, sidecar_bytes)
            transaction.commit()
    except (OutputTransactionError, OSError) as error:
        raise RuntimeIdentityError(f"the runtime identity could not be published: {error}") from error

    try:
        hours, _ = load_market_hours(data_folder, security_type, market, symbol)
    except MarketHoursDatabaseError as error:
        raise RuntimeIdentityError(
            f"the published runtime identity cannot be resolved by LEAN: {error}"
        ) from error
    if not hours.always_open:
        raise RuntimeIdentityError(
            f"the published runtime identity entry {hours.entry_key} is not always open"
        )
    if (
        hours.data_time_zone != ALWAYS_OPEN_DATA_TIME_ZONE
        or hours.exchange_time_zone != ALWAYS_OPEN_EXCHANGE_TIME_ZONE
    ):
        raise RuntimeIdentityError(
            f"the published runtime identity entry {hours.entry_key} has unexpected time zones "
            f"({hours.data_time_zone}/{hours.exchange_time_zone})"
        )
    return payload
