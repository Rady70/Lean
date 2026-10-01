"""Deterministic derived M1 candle cache from the qualified native quote history.

The qualified Dukascopy identity stores one UTC day per native partition at
``cfd/dukascopy/tick/xauusd/YYYYMMDD_quote.zip`` (one member
``YYYYMMDD_xauusd_tick_quote.csv`` with lines ``<milliseconds since UTC
midnight>,<bid>,<ask>``). This module derives a monthly M1 candle cache that is
explicitly **derived visualization data**: it is not an authority over the
native partitions, and executions, events and account snapshots remain the
authoritative LEAN output.

Contract (``marketlab-xauusd-m1-candle-cache-v1``):

- price: ``mid = (bid + ask) / 2`` computed exactly with ``decimal.Decimal``
  and rendered by :func:`~marketlab_historical_data.canonical.canonical_decimal_text`
  (fixed point, no exponent, no trailing zeros, ``-0`` rendered ``0``);
- bucket: UTC minute; the candle time is the minute start rendered as
  ``YYYY-MM-DDTHH:MM:00.000Z``;
- OHLC: open/high/low/close are the first/max/min/last mid of the minute in
  source order (equal timestamps keep source order); ``ticks`` counts the quote
  rows of the minute;
- only minutes with at least one quote are emitted; absent minutes are never
  filled, interpolated or zero-valued, and the manifest records
  ``empty_minutes: absent``;
- one UTF-8 (no BOM) CSV per UTC calendar month named
  ``xauusd-m1-YYYY-MM.csv`` with header ``time,open,high,low,close,ticks`` and
  LF line endings;
- the optional ``--start``/``--end`` bounds are inclusive native partition
  dates: only partitions whose file date falls inside the bounds are read, so a
  source row outside the requested partition-date window is never counted.

``manifest.json`` is deterministic: no wall clock, no output path, files sorted
by name ascending, and ``content_sha256`` is the SHA-256 over the concatenated
ordered ``name\\0sha256\\0bytes\\n`` rows (one UTF-8 row per file, in the same
ascending order). The composition and session-map entries in ``inputs`` are
identity evidence only: when the composition exists but cannot be parsed as
identity evidence, its error is recorded as ``identity_error`` and generation
still proceeds, because the cache is derived only from the native partitions.

The generator never writes into the source data folder; it reads one native zip
at a time and builds each month's CSV in memory (about 2 MB per month).
"""

from __future__ import annotations

import hashlib
import json
import re
import zipfile
from datetime import date
from decimal import Decimal, localcontext
from pathlib import Path

from .canonical import canonical_decimal_text, parse_decimal_text, sha256_file
from .lean_native import NativeLeanTickLayout
from .transactions import OutputTransaction, OutputTransactionError

__all__ = [
    "CANDLE_CONTRACT",
    "CandleCacheError",
    "CandleCacheOutcome",
    "generate_candles",
]

CANDLE_CONTRACT = "marketlab-xauusd-m1-candle-cache-v1"
SYMBOL = "XAUUSD"
MARKET = "dukascopy"
SECURITY_TYPE = "Cfd"
RESOLUTION = "M1"
MANIFEST_NAME = "manifest.json"
CSV_HEADER = "time,open,high,low,close,ticks"
CANDLE_FILE_PREFIX = "xauusd-m1-"
CANDLE_FILE_SUFFIX = ".csv"
COMPOSITION_RELATIVE = Path("marketlab-qualification") / "continuous-composition.json"
SESSION_MAP_RELATIVE = Path("marketlab-sessions") / "xauusd-sessions.json"

_PARTITION_NAME = re.compile(r"^(\d{8})_quote\.zip$")
_DAY_MILLISECONDS = 86_400_000


class CandleCacheError(Exception):
    """The native history cannot be read or a candle output cannot be written."""


class CandleCacheOutcome:
    """Result of one candle-cache generation attempt."""

    def __init__(self, exit_code: int, failures, manifest, manifest_path):
        self.exit_code = exit_code
        self.failures = list(failures)
        self.manifest = manifest
        self.manifest_path = manifest_path


def _layout() -> NativeLeanTickLayout:
    return NativeLeanTickLayout(SYMBOL, MARKET, SECURITY_TYPE)


def _is_within(path: Path, root: Path) -> bool:
    try:
        Path(path).resolve().relative_to(Path(root).resolve())
    except ValueError:
        return False
    return True


def _partition_date(path: Path) -> date | None:
    match = _PARTITION_NAME.match(path.name)
    if match is None:
        return None
    text = match.group(1)
    try:
        return date(int(text[0:4]), int(text[4:6]), int(text[6:8]))
    except ValueError:
        return None


def _discover_partitions(data_folder: Path) -> list[tuple[date, Path]]:
    directory = Path(data_folder) / _layout().relative_directory
    if not directory.is_dir():
        raise CandleCacheError(f"the native partition directory does not exist: {directory}")
    partitions: list[tuple[date, Path]] = []
    for path in directory.iterdir():
        if not path.is_file():
            continue
        partition = _partition_date(path)
        if partition is not None:
            partitions.append((partition, path))
    partitions.sort(key=lambda item: (item[0], item[1].name))
    return partitions


def _iter_partition_lines(path: Path):
    label = path.name
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if len(names) != 1:
                raise CandleCacheError(
                    f"{label}: the native partition must contain exactly one member: {names}"
                )
            if archive.getinfo(names[0]).file_size == 0:
                raise CandleCacheError(f"{label}: the native partition is empty")
            with archive.open(names[0]) as member:
                for raw in member:
                    line = raw.rstrip(b"\r\n")
                    if not line:
                        raise CandleCacheError(
                            f"{label}: the native partition contains an empty row"
                        )
                    yield line
    except (zipfile.BadZipFile, OSError) as error:
        raise CandleCacheError(f"{label}: the native partition is not a usable zip: {error}") from error


def _parse_row(line: bytes, label: str):
    parts = line.split(b",")
    if len(parts) != 3:
        raise CandleCacheError(f"{label}: malformed quote row: {line[:80]!r}")
    try:
        millisecond = int(parts[0])
        bid = parse_decimal_text(parts[1].decode("ascii"), "bid")
        ask = parse_decimal_text(parts[2].decode("ascii"), "ask")
    except (ValueError, UnicodeDecodeError) as error:
        raise CandleCacheError(f"{label}: malformed quote row: {line[:80]!r}") from error
    if not 0 <= millisecond < _DAY_MILLISECONDS:
        raise CandleCacheError(
            f"{label}: quote millisecond is outside the UTC day: {millisecond}"
        )
    if bid <= 0 or ask <= 0 or ask < bid:
        raise CandleCacheError(
            f"{label}: quote is not a positive uncrossed bid/ask: {line[:80]!r}"
        )
    return millisecond, bid, ask


def _digit_shape(value: Decimal) -> tuple[int, int]:
    """Integer digit count and fractional scale of a finite Decimal."""
    exponent = value.as_tuple().exponent
    scale = -exponent if exponent < 0 else 0
    return max(len(value.as_tuple().digits) - scale, 0), scale


def _midpoint(bid: Decimal, ask: Decimal) -> Decimal:
    """Exact ``(bid + ask) / 2`` without binary float and without rounding.

    The precision bound covers the worst case for arbitrarily scaled finite decimals:
    ``max(integer digits) + max(scale)`` significant digits for the sum, plus one carry
    digit, plus one digit for the division by two.
    """
    bid_integer, bid_scale = _digit_shape(bid)
    ask_integer, ask_scale = _digit_shape(ask)
    with localcontext() as context:
        context.prec = max(bid_integer, ask_integer) + max(bid_scale, ask_scale) + 2
        return (bid + ask) / Decimal(2)


def _minute_text(partition: date, millisecond: int) -> str:
    minute_start = (millisecond // 60_000) * 60_000
    hour, remainder = divmod(minute_start, 3_600_000)
    minute = remainder // 60_000
    return f"{partition.isoformat()}T{hour:02d}:{minute:02d}:00.000Z"


def _render_month(minutes: dict[str, list]) -> tuple[bytes, str, str]:
    lines = [CSV_HEADER]
    first_candle = None
    last_candle = None
    for minute_text, candle in minutes.items():
        open_mid, high_mid, low_mid, close_mid, ticks = candle
        lines.append(
            f"{minute_text},{canonical_decimal_text(open_mid)},{canonical_decimal_text(high_mid)},"
            f"{canonical_decimal_text(low_mid)},{canonical_decimal_text(close_mid)},{ticks}"
        )
        if first_candle is None:
            first_candle = minute_text
        last_candle = minute_text
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    return payload, first_candle, last_candle


def _content_sha256(files: list[dict]) -> str:
    digest = hashlib.sha256()
    for record in files:
        digest.update(
            f"{record['name']}\0{record['sha256']}\0{record['bytes']}\n".encode("utf-8")
        )
    return digest.hexdigest()


def _sha256_or_error(path: Path, entry: dict) -> bool:
    try:
        entry["sha256"] = sha256_file(path)
        return True
    except OSError as error:
        entry["sha256"] = None
        entry["identity_error"] = f"the file cannot be hashed: {error}"
        return False


def _composition_evidence(path: Path) -> dict:
    entry: dict = {"relative_path": COMPOSITION_RELATIVE.as_posix()}
    if not _sha256_or_error(path, entry):
        return entry
    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        entry["identity_error"] = f"the composition cannot be parsed: {error}"
        return entry
    semantic_digest = None
    accepted_rows = None
    data_time_zone = None
    if isinstance(payload, dict):
        semantic = payload.get("semantic")
        if isinstance(semantic, dict):
            value = semantic.get("ordered_source_semantic_digest")
            if isinstance(value, str) and value:
                semantic_digest = value
        counts = payload.get("counts")
        if isinstance(counts, dict):
            value = counts.get("accepted_row_count")
            if isinstance(value, int) and not isinstance(value, bool):
                accepted_rows = value
        lean = payload.get("lean")
        if isinstance(lean, dict):
            value = lean.get("data_time_zone")
            if isinstance(value, str) and value:
                data_time_zone = value
    if data_time_zone is not None:
        entry["data_time_zone"] = data_time_zone
    if semantic_digest is None or accepted_rows is None:
        entry["identity_error"] = (
            "the composition does not carry semantic.ordered_source_semantic_digest "
            "and counts.accepted_row_count"
        )
        return entry
    entry["ordered_source_semantic_digest"] = semantic_digest
    entry["accepted_row_count"] = accepted_rows
    return entry


def _session_map_evidence(path: Path) -> dict:
    entry: dict = {"relative_path": SESSION_MAP_RELATIVE.as_posix()}
    _sha256_or_error(path, entry)
    return entry


def _input_evidence(data_folder: Path) -> dict:
    composition_file = Path(data_folder) / COMPOSITION_RELATIVE
    composition = _composition_evidence(composition_file) if composition_file.is_file() else None
    session_file = Path(data_folder) / SESSION_MAP_RELATIVE
    session_map = _session_map_evidence(session_file) if session_file.is_file() else None
    return {
        "data_folder_name": Path(data_folder).name,
        "native_directory": _layout().relative_directory,
        "composition": composition,
        "session_map": session_map,
    }


def _manifest_text(payload: dict) -> str:
    return json.dumps(payload, indent=2, sort_keys=False, ensure_ascii=False) + "\n"


def generate_candles(
    data_folder: Path,
    out: Path,
    *,
    start: date | None = None,
    end: date | None = None,
) -> CandleCacheOutcome:
    """Derives the monthly M1 candle cache for one inclusive partition-date window."""
    data_folder = Path(data_folder)
    out = Path(out)
    if start is not None and end is not None and start > end:
        return CandleCacheOutcome(
            2,
            [f"InvalidWindow: --start {start.isoformat()} is after --end {end.isoformat()}"],
            None,
            None,
        )
    if not data_folder.is_dir():
        return CandleCacheOutcome(2, [f"DataFolderNotFound: {data_folder}"], None, None)
    if out.resolve() == data_folder.resolve() or _is_within(out, data_folder):
        return CandleCacheOutcome(
            2,
            [
                f"OutputInsideSourceData: the output directory {out} must not be the source "
                f"data folder or inside it ({data_folder})"
            ],
            None,
            None,
        )
    try:
        partitions = _discover_partitions(data_folder)
    except CandleCacheError as error:
        return CandleCacheOutcome(2, [f"NativeDataUnusable: {error}"], None, None)
    selected = [
        (partition, path)
        for partition, path in partitions
        if (start is None or partition >= start) and (end is None or partition <= end)
    ]
    if not selected:
        window = (
            f"{start.isoformat() if start else 'open'}..{end.isoformat() if end else 'open'}"
        )
        return CandleCacheOutcome(
            1, [f"NoPartitionsInWindow: no native partition falls inside {window}"], None, None
        )
    if out.exists() and not out.is_dir():
        return CandleCacheOutcome(2, [f"OutputUnusable: {out} is not a directory"], None, None)
    manifest_file = out / MANIFEST_NAME
    if manifest_file.is_file():
        try:
            existing = json.loads(manifest_file.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            return CandleCacheOutcome(
                1,
                [
                    f"ForeignManifest: {manifest_file} is not readable as this cache's "
                    f"manifest: {error}"
                ],
                None,
                None,
            )
        if not isinstance(existing, dict) or existing.get("contract") != CANDLE_CONTRACT:
            return CandleCacheOutcome(
                1,
                [f"ForeignManifest: {manifest_file} is not a {CANDLE_CONTRACT} manifest"],
                None,
                None,
            )

    inputs = _input_evidence(data_folder)
    composition = inputs.get("composition")
    if isinstance(composition, dict):
        data_time_zone = composition.get("data_time_zone")
        if data_time_zone is not None and data_time_zone != "UTC":
            return CandleCacheOutcome(
                2,
                [
                    "DataTimeZoneNotUtc: the native timestamps are milliseconds since local "
                    f"midnight and the qualified composition names data_time_zone "
                    f"'{data_time_zone}'; this UTC-minute bucket contract only supports UTC"
                ],
                None,
                None,
            )

    effective_start = start if start is not None else selected[0][0]
    effective_end = end if end is not None else selected[-1][0]
    source_rows = 0
    candle_rows = 0
    candle_bytes = 0
    files: list[dict] = []
    generated_names: set[str] = set()
    current_month = None
    minutes: dict[str, list] = {}
    try:
        with OutputTransaction(allow_overwrite=True) as transaction:
            for partition, path in selected:
                month = f"{partition.year:04d}-{partition.month:02d}"
                if current_month is not None and month != current_month:
                    payload, first_candle, last_candle = _render_month(minutes)
                    name = f"{CANDLE_FILE_PREFIX}{current_month}{CANDLE_FILE_SUFFIX}"
                    transaction.stage_bytes(out / name, payload)
                    files.append(
                        {
                            "name": name,
                            "rows": len(minutes),
                            "bytes": len(payload),
                            "sha256": hashlib.sha256(payload).hexdigest(),
                            "first_candle_utc": first_candle,
                            "last_candle_utc": last_candle,
                        }
                    )
                    generated_names.add(name)
                    candle_rows += len(minutes)
                    candle_bytes += len(payload)
                    minutes = {}
                current_month = month
                label = f"{partition.isoformat()}/{path.name}"
                for line in _iter_partition_lines(path):
                    millisecond, bid, ask = _parse_row(line, label)
                    source_rows += 1
                    minute_text = _minute_text(partition, millisecond)
                    mid = _midpoint(bid, ask)
                    candle = minutes.get(minute_text)
                    if candle is None:
                        minutes[minute_text] = [mid, mid, mid, mid, 1]
                    else:
                        if mid > candle[1]:
                            candle[1] = mid
                        if mid < candle[2]:
                            candle[2] = mid
                        candle[3] = mid
                        candle[4] += 1
            if minutes:
                payload, first_candle, last_candle = _render_month(minutes)
                name = f"{CANDLE_FILE_PREFIX}{current_month}{CANDLE_FILE_SUFFIX}"
                transaction.stage_bytes(out / name, payload)
                files.append(
                    {
                        "name": name,
                        "rows": len(minutes),
                        "bytes": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "first_candle_utc": first_candle,
                        "last_candle_utc": last_candle,
                    }
                )
                generated_names.add(name)
                candle_rows += len(minutes)
                candle_bytes += len(payload)
            files.sort(key=lambda record: record["name"])
            if out.is_dir():
                for candidate in out.glob(f"{CANDLE_FILE_PREFIX}*{CANDLE_FILE_SUFFIX}"):
                    if candidate.is_file() and candidate.name not in generated_names:
                        transaction.register_removal(candidate)
            manifest = {
                "contract": CANDLE_CONTRACT,
                "symbol": SYMBOL,
                "market": MARKET,
                "resolution": RESOLUTION,
                "price_basis": "mid_of_best_bid_ask",
                "time_basis": "UTC",
                "empty_minutes": "absent",
                "inputs": inputs,
                "start_date": effective_start.isoformat(),
                "end_date": effective_end.isoformat(),
                "totals": {
                    "partitions": len(selected),
                    "source_rows": source_rows,
                    "candle_rows": candle_rows,
                    "candle_bytes": candle_bytes,
                },
                "files": files,
                "content_sha256": _content_sha256(files),
            }
            transaction.stage_text(out / MANIFEST_NAME, _manifest_text(manifest))
            transaction.commit()
    except (CandleCacheError, OutputTransactionError, OSError) as error:
        return CandleCacheOutcome(1, [f"CandleGenerationFailed: {error}"], None, None)
    return CandleCacheOutcome(0, [], manifest, out / MANIFEST_NAME)
