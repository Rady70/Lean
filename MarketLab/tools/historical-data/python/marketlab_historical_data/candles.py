"""Deterministic derived M1 candle cache from the qualified native quote history.

The qualified Dukascopy identity stores one UTC day per native partition at
``cfd/dukascopy/tick/xauusd/YYYYMMDD_quote.zip`` (one member
``YYYYMMDD_xauusd_tick_quote.csv`` with lines ``<milliseconds since UTC
midnight>,<bid>,<ask>``). This module derives a monthly M1 candle cache that is
explicitly **derived visualization data**: it is not an authority over the
native partitions, and executions, events and account snapshots remain the
authoritative LEAN output.

The source tree must carry the qualified continuous composition and its PASS
qualification record (the artifacts ``compose-history`` and
``verify-continuous`` publish under ``marketlab-qualification``). Generation
fails closed before publishing anything unless both parse, the composition
declares the expected contracts and ``lean.data_time_zone: UTC``, the record
binds the actual composition SHA-256 and is PASS, the on-disk ``*_quote.zip``
set equals the composition's partition set exactly, and every partition
selected by ``--start``/``--end`` matches its qualified ``zip_sha256`` before
derivation plus its ``member_name``, ``member_size_bytes``, ``row_count`` and
member SHA-256 while streaming.

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
  Range independence only holds for month-aligned bounds: a mid-month bound
  produces a partial-month CSV, because each monthly file contains only the
  selected partitions of that month.

``manifest.json`` is deterministic: no wall clock, no output path, files sorted
by name ascending, and ``content_sha256`` is the SHA-256 over the concatenated
ordered ``name\\0sha256\\0bytes\\n`` rows (one UTF-8 row per file, in the same
ascending order). The composition, qualification-record and session-map entries
in ``inputs`` are the verified source identity evidence; the composition and
record are required preconditions, while a missing session map is recorded as
absent.

The generator never writes into the source data folder; it reads one native zip
at a time and builds each month's CSV in memory (about 2 MB per month).
``verify-candles`` re-runs the source preflight over every partition and checks
the cache manifest, every monthly CSV and the source totals without deriving
candles.
"""

from __future__ import annotations

import hashlib
import json
import re
import zipfile
from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal, localcontext
from pathlib import Path

from .canonical import canonical_decimal_text, parse_decimal_text, sha256_file
from .continuous import (
    _require_composition_structure,
    composition_path,
    continuous_record_path,
)
from .lean_native import NativeLeanTickLayout
from .replay import RECORD_CONTRACT
from .transactions import OutputTransaction, OutputTransactionError

__all__ = [
    "CANDLE_CONTRACT",
    "VERIFICATION_CONTRACT",
    "CandleCacheError",
    "CandleCacheOutcome",
    "CandleVerificationOutcome",
    "generate_candles",
    "verify_candles",
]

CANDLE_CONTRACT = "marketlab-xauusd-m1-candle-cache-v1"
VERIFICATION_CONTRACT = "marketlab-xauusd-m1-candle-verification-v1"
SYMBOL = "XAUUSD"
MARKET = "dukascopy"
SECURITY_TYPE = "Cfd"
RESOLUTION = "M1"
MANIFEST_NAME = "manifest.json"
CSV_HEADER = "time,open,high,low,close,ticks"
CANDLE_FILE_PREFIX = "xauusd-m1-"
CANDLE_FILE_SUFFIX = ".csv"
SESSION_MAP_RELATIVE = Path("marketlab-sessions") / "xauusd-sessions.json"

_PARTITION_NAME = re.compile(r"^(\d{8})_quote\.zip$")
_CANDLE_NAME = re.compile(r"^xauusd-m1-(\d{4})-(\d{2})\.csv$")
_SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
_DAY_MILLISECONDS = 86_400_000
_CANDLE_TIME_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"


class CandleCacheError(Exception):
    """The native history cannot be read or a candle output cannot be written."""


class SourceIdentityError(Exception):
    """The source tree does not carry the required qualified identity."""


class CandleCacheOutcome:
    """Result of one candle-cache generation attempt."""

    def __init__(self, exit_code: int, failures, manifest, manifest_path):
        self.exit_code = exit_code
        self.failures = list(failures)
        self.manifest = manifest
        self.manifest_path = manifest_path


class CandleVerificationOutcome:
    """Result of one candle-cache verification attempt."""

    def __init__(self, exit_code: int, failures, record):
        self.exit_code = exit_code
        self.failures = list(failures)
        self.record = record


@dataclass
class QualifiedSource:
    """The preflight-verified qualified identity of one native source tree."""

    data_folder: Path
    composition: dict
    composition_sha256: str
    record: dict
    record_sha256: str
    partitions: list
    partitions_by_path: dict


@dataclass
class CacheScan:
    """What the cache manifest declared and what the cache bytes actually show."""

    files: int = 0
    rows: int = 0
    bytes: int = 0
    content_sha256: str = ""
    months: list = field(default_factory=list)
    first_candle_month: int | None = None
    last_candle_month: int | None = None


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


def _iter_partition_lines(path: Path, expected: dict | None = None):
    label = path.name
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if len(names) != 1:
                raise CandleCacheError(
                    f"{label}: the native partition must contain exactly one member: {names}"
                )
            if expected is not None and names[0] != expected["member_name"]:
                raise CandleCacheError(
                    f"{label}: the native partition member is {names[0]!r} but the qualified "
                    f"composition names {expected['member_name']!r}"
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


def _iter_verified_partition_lines(path: Path, artifact: dict):
    label = f"{artifact['partition']}/{path.name}"
    digest = hashlib.sha256()
    size = 0
    rows = 0
    for line in _iter_partition_lines(path, artifact):
        if rows:
            digest.update(b"\n")
            size += 1
        digest.update(line)
        size += len(line)
        rows += 1
        yield line
    if rows != artifact["row_count"]:
        raise CandleCacheError(
            f"{label}: the native partition has {rows} rows but the qualified composition "
            f"records {artifact['row_count']}"
        )
    if size != artifact["member_size_bytes"]:
        raise CandleCacheError(
            f"{label}: the canonical member is {size} bytes but the qualified composition "
            f"records {artifact['member_size_bytes']}"
        )
    actual = digest.hexdigest()
    if actual != artifact["member_sha256"]:
        raise CandleCacheError(
            f"{label}: the native member SHA-256 {actual} does not match the qualified "
            f"composition {artifact['member_sha256']}"
        )


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


def _read_json_object(path: Path, label: str) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SourceIdentityError(f"{label}Unreadable: {path}: {error}") from error
    if not isinstance(payload, dict):
        raise SourceIdentityError(f"{label}NotAnObject: {path}")
    return payload


def _require_digest(value, label: str) -> str:
    if not isinstance(value, str) or _SHA256_HEX.match(value) is None:
        raise SourceIdentityError(f"{label}: not a lowercase SHA-256 hex digest: {value!r}")
    return value


def _require_posix_relative(value, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise SourceIdentityError(f"{label}: not a non-empty string")
    parts = Path(value.replace("\\", "/")).parts
    if (
        "\\" in value
        or value.startswith("/")
        or Path(value).as_posix() != value
        or ".." in parts
        or "." in parts
    ):
        raise SourceIdentityError(
            f"{label}: not a normalized posix path relative to the data folder: {value!r}"
        )
    return value


def _load_qualified_source(data_folder: Path) -> QualifiedSource:
    composition_file = composition_path(data_folder)
    if not composition_file.is_file():
        raise SourceIdentityError(f"QualificationCompositionMissing: {composition_file}")
    composition = _read_json_object(composition_file, "QualificationComposition")
    try:
        _require_composition_structure(composition)
    except ValueError as error:
        raise SourceIdentityError(f"CompositionStructureUnusable: {error}") from error

    lean = composition["lean"]
    data_time_zone = lean.get("data_time_zone")
    if data_time_zone != "UTC":
        raise SourceIdentityError(
            "DataTimeZoneNotUtc: the native timestamps are milliseconds since local "
            f"midnight and the qualified composition names data_time_zone "
            f"'{data_time_zone}'; this UTC-minute bucket contract only supports UTC"
        )

    relative_directory = _layout().relative_directory
    by_path: dict[str, dict] = {}
    for index, artifact in enumerate(composition["native"]["partitions"]):
        label = f"CompositionPartition[{index}]"
        relative = _require_posix_relative(
            artifact["zip_relative_path"], f"{label}.zip_relative_path"
        )
        member_name = artifact.get("member_name")
        if not isinstance(member_name, str) or not member_name:
            raise SourceIdentityError(f"{label}.member_name: missing or not a non-empty string")
        size = artifact.get("member_size_bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise SourceIdentityError(
                f"{label}.member_size_bytes: not a non-negative integer: {size!r}"
            )
        _require_digest(artifact.get("member_sha256"), f"{label}.member_sha256")
        _require_digest(artifact.get("zip_sha256"), f"{label}.zip_sha256")
        partition_text = artifact["partition"]
        try:
            partition = date.fromisoformat(partition_text)
        except ValueError as error:
            raise SourceIdentityError(
                f"{label}.partition: not an ISO date: {partition_text!r}"
            ) from error
        if Path(relative).name != f"{partition:%Y%m%d}_quote.zip" or relative != (
            f"{relative_directory}/{partition:%Y%m%d}_quote.zip"
        ):
            raise SourceIdentityError(
                f"{label}: {relative!r} does not name the {partition.isoformat()} partition "
                f"under {relative_directory}"
            )
        if relative in by_path:
            raise SourceIdentityError(f"{label}: duplicate zip_relative_path {relative!r}")
        by_path[relative] = artifact

    directory = Path(data_folder) / relative_directory
    if not directory.is_dir():
        raise CandleCacheError(f"the native partition directory does not exist: {directory}")
    on_disk = {
        f"{relative_directory}/{candidate.name}"
        for candidate in directory.glob("*_quote.zip")
        if candidate.is_file()
    }
    extra = sorted(on_disk - set(by_path))
    if extra:
        summary = ", ".join(extra[:3]) + (" ..." if len(extra) > 3 else "")
        raise SourceIdentityError(
            f"NativePartitionNotInComposition: {len(extra)} on-disk partition(s) are not "
            f"listed in the qualified composition ({summary})"
        )
    missing = sorted(set(by_path) - on_disk)
    if missing:
        summary = ", ".join(missing[:3]) + (" ..." if len(missing) > 3 else "")
        raise SourceIdentityError(
            f"CompositionPartitionMissing: {len(missing)} qualified partition(s) are not on "
            f"disk ({summary})"
        )

    partitions = _discover_partitions(data_folder)
    record_file = continuous_record_path(data_folder)
    if not record_file.is_file():
        raise SourceIdentityError(f"QualificationRecordMissing: {record_file}")
    record = _read_json_object(record_file, "QualificationRecord")
    if record.get("contract") != RECORD_CONTRACT:
        raise SourceIdentityError(
            f"QualificationRecordContractMismatch: expected {RECORD_CONTRACT}, found "
            f"{record.get('contract')!r}"
        )
    if record.get("overall_qualification") != "PASS":
        raise SourceIdentityError(
            "QualificationNotPass: overall_qualification is "
            f"{record.get('overall_qualification')!r}"
        )

    try:
        composition_sha256 = sha256_file(composition_file)
        record_sha256 = sha256_file(record_file)
    except OSError as error:
        raise SourceIdentityError(f"QualificationIdentityUnreadable: {error}") from error
    bound = record.get("manifest_sha256")
    if bound != composition_sha256:
        raise SourceIdentityError(
            "QualificationCompositionBindingMismatch: record.manifest_sha256 is "
            f"{bound!r} but the composition SHA-256 is {composition_sha256!r}"
        )
    continuous = record.get("continuous")
    if isinstance(continuous, dict) and continuous.get("composition_sha256") is not None:
        nested = continuous.get("composition_sha256")
        if nested != composition_sha256:
            raise SourceIdentityError(
                "QualificationCompositionBindingMismatch: "
                f"record.continuous.composition_sha256 is {nested!r} but the composition "
                f"SHA-256 is {composition_sha256!r}"
            )

    return QualifiedSource(
        data_folder=Path(data_folder),
        composition=composition,
        composition_sha256=composition_sha256,
        record=record,
        record_sha256=record_sha256,
        partitions=partitions,
        partitions_by_path=by_path,
    )


def _session_map_evidence(path: Path) -> dict:
    entry: dict = {"relative_path": SESSION_MAP_RELATIVE.as_posix()}
    _sha256_or_error(path, entry)
    return entry


def _input_evidence(data_folder: Path, source: QualifiedSource) -> dict:
    data_folder = Path(data_folder)
    composition = source.composition
    session_file = data_folder / SESSION_MAP_RELATIVE
    return {
        "data_folder_name": data_folder.name,
        "native_directory": _layout().relative_directory,
        "composition": {
            "relative_path": composition_path(data_folder)
            .relative_to(data_folder)
            .as_posix(),
            "sha256": source.composition_sha256,
            "contract": composition["contract"],
            "composition_contract": composition["composition"]["contract"],
            "data_time_zone": composition["lean"]["data_time_zone"],
            "ordered_source_semantic_digest": composition["semantic"][
                "ordered_source_semantic_digest"
            ],
            "accepted_row_count": composition["counts"]["accepted_row_count"],
            "partition_count": len(composition["native"]["partitions"]),
        },
        "qualification_record": {
            "relative_path": continuous_record_path(data_folder)
            .relative_to(data_folder)
            .as_posix(),
            "sha256": source.record_sha256,
            "overall_qualification": source.record["overall_qualification"],
        },
        "session_map": (
            _session_map_evidence(session_file) if session_file.is_file() else None
        ),
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
        source = _load_qualified_source(data_folder)
    except CandleCacheError as error:
        return CandleCacheOutcome(2, [f"NativeDataUnusable: {error}"], None, None)
    except SourceIdentityError as error:
        return CandleCacheOutcome(2, [f"QualificationIdentityRefused: {error}"], None, None)

    partitions = source.partitions
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

    inputs = _input_evidence(data_folder, source)
    relative_directory = _layout().relative_directory
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
                artifact = source.partitions_by_path.get(
                    f"{relative_directory}/{path.name}"
                )
                if artifact is None:
                    raise CandleCacheError(
                        f"{label}: the native partition is not listed in the qualified composition"
                    )
                try:
                    actual_zip_sha256 = sha256_file(path)
                except OSError as error:
                    raise CandleCacheError(
                        f"{label}: the native partition cannot be hashed: {error}"
                    ) from error
                if actual_zip_sha256 != artifact["zip_sha256"]:
                    raise CandleCacheError(
                        f"{label}: the native partition zip SHA-256 {actual_zip_sha256} does "
                        f"not match the qualified composition {artifact['zip_sha256']}"
                    )
                for line in _iter_verified_partition_lines(path, artifact):
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


def _month_index(value: date) -> int:
    return value.year * 12 + value.month


def _month_text(index: int) -> str:
    year, month = divmod(index - 1, 12)
    return f"{year:04d}-{month + 1:02d}"


def _candle_month(value, label: str, failures: list) -> int | None:
    if not isinstance(value, str):
        failures.append(f"{label}: candle time is missing or not a string: {value!r}")
        return None
    try:
        parsed = datetime.strptime(value, _CANDLE_TIME_FORMAT)
    except ValueError:
        failures.append(f"{label}: candle time is not canonical UTC text: {value!r}")
        return None
    return parsed.year * 12 + parsed.month


def _verify_cache_files(
    cache: Path, manifest: dict, checks: dict, failures: list
) -> CacheScan:
    scan = CacheScan()
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        checks["cache_file_records"] = False
        failures.append("CacheFileRecordsMissing: manifest.files is not a non-empty array")
        files = []
    digest = hashlib.sha256()
    seen_names: set[str] = set()
    previous_name = None
    for index, record in enumerate(files):
        label = f"CacheFile[{index}]"
        if not isinstance(record, dict):
            checks["cache_file_records"] = False
            failures.append(f"{label}: not an object")
            continue
        name = record.get("name")
        month = None
        match = _CANDLE_NAME.match(name) if isinstance(name, str) else None
        month_number = int(match.group(2)) if match is not None else 0
        if match is None or not 1 <= month_number <= 12:
            checks["cache_file_records"] = False
            failures.append(
                f"{label}: name is not a month-aligned xauusd-m1-YYYY-MM.csv file: {name!r}"
            )
        else:
            month = int(match.group(1)) * 12 + month_number
            scan.months.append(month)
            if name in seen_names:
                checks["cache_file_records"] = False
                failures.append(f"CacheFileDuplicate: {name}")
            if previous_name is not None and name <= previous_name:
                checks["cache_file_records"] = False
                failures.append(
                    f"CacheFileOrderMismatch: {name} does not follow {previous_name}"
                )
            previous_name = name
            seen_names.add(name)

        recorded_sha = record.get("sha256")
        recorded_bytes = record.get("bytes")
        recorded_rows = record.get("rows")
        if (
            isinstance(recorded_sha, str)
            and isinstance(recorded_bytes, int)
            and not isinstance(recorded_bytes, bool)
            and isinstance(name, str)
        ):
            digest.update(f"{name}\0{recorded_sha}\0{recorded_bytes}\n".encode("utf-8"))
        else:
            checks["cache_file_records"] = False
            failures.append(f"{label}: name/sha256/bytes are not usable")
        if (
            isinstance(recorded_rows, int)
            and not isinstance(recorded_rows, bool)
            and recorded_rows >= 0
        ):
            scan.rows += recorded_rows
        else:
            checks["cache_file_records"] = False
            failures.append(f"{label}: rows is not a non-negative integer")
        if (
            isinstance(recorded_bytes, int)
            and not isinstance(recorded_bytes, bool)
            and recorded_bytes >= 0
        ):
            scan.bytes += recorded_bytes

        if not isinstance(name, str):
            continue
        path = cache / name
        if not path.is_file():
            checks["cache_file_records"] = False
            failures.append(f"{label}: cache file is missing: {name}")
            continue
        try:
            payload = path.read_bytes()
        except OSError as error:
            checks["cache_file_records"] = False
            failures.append(f"{label}: cache file is not readable: {name}: {error}")
            continue
        actual_sha = hashlib.sha256(payload).hexdigest()
        if recorded_bytes != len(payload):
            checks["cache_file_records"] = False
            failures.append(
                f"CacheFileBytesMismatch: {name}: manifest {recorded_bytes!r} != actual "
                f"{len(payload)}"
            )
        if recorded_sha != actual_sha:
            checks["cache_file_records"] = False
            failures.append(
                f"CacheFileSha256Mismatch: {name}: manifest {recorded_sha!r} != actual "
                f"{actual_sha}"
            )
        first = _candle_month(record.get("first_candle_utc"), f"{label}.first_candle_utc", failures)
        last = _candle_month(record.get("last_candle_utc"), f"{label}.last_candle_utc", failures)
        if first is None or last is None:
            checks["cache_file_records"] = False
        else:
            if scan.first_candle_month is None:
                scan.first_candle_month = first
            scan.last_candle_month = last
            if month is not None and first != month:
                checks["cache_file_records"] = False
                failures.append(
                    f"CacheFirstCandleMonthMismatch: {name}: first candle month is "
                    f"{_month_text(first)}"
                )
            if month is not None and last != month:
                checks["cache_file_records"] = False
                failures.append(
                    f"CacheLastCandleMonthMismatch: {name}: last candle month is "
                    f"{_month_text(last)}"
                )
    scan.files = len(files)
    scan.content_sha256 = digest.hexdigest()
    if manifest.get("content_sha256") != scan.content_sha256:
        checks["cache_content_sha256"] = False
        failures.append(
            f"CacheContentSha256Mismatch: manifest {manifest.get('content_sha256')!r} != "
            f"recomputed {scan.content_sha256}"
        )
    return scan


def _verify_cache_totals(
    manifest: dict, scan: CacheScan, source: QualifiedSource, checks: dict, failures: list
) -> None:
    totals = manifest.get("totals")
    if not isinstance(totals, dict):
        checks["cache_totals"] = False
        failures.append("CacheTotalsMissing: manifest.totals is not an object")
        return
    if totals.get("candle_rows") != scan.rows or totals.get("candle_bytes") != scan.bytes:
        checks["cache_totals"] = False
        failures.append(
            f"CacheTotalsMismatch: manifest candle_rows/candle_bytes "
            f"{totals.get('candle_rows')!r}/{totals.get('candle_bytes')!r} != recomputed "
            f"{scan.rows}/{scan.bytes}"
        )
    accepted = source.composition["counts"]["accepted_row_count"]
    if totals.get("source_rows") != accepted:
        checks["cache_totals"] = False
        failures.append(
            f"CacheSourceRowTotalMismatch: manifest totals.source_rows "
            f"{totals.get('source_rows')!r} != composition counts.accepted_row_count "
            f"{accepted!r}"
        )
    partition_count = len(source.composition["native"]["partitions"])
    if totals.get("partitions") != partition_count:
        checks["cache_totals"] = False
        failures.append(
            f"CachePartitionTotalMismatch: manifest totals.partitions "
            f"{totals.get('partitions')!r} != composition partition count {partition_count!r}"
        )


def _verify_cache_window(
    manifest: dict, scan: CacheScan, checks: dict, failures: list
) -> None:
    try:
        start = date.fromisoformat(manifest.get("start_date"))
        end = date.fromisoformat(manifest.get("end_date"))
    except (TypeError, ValueError) as error:
        checks["cache_month_coverage"] = False
        checks["cache_window_alignment"] = False
        failures.append(f"CacheWindowUnusable: --start/--end window is not two ISO dates: {error}")
        return
    if start > end:
        checks["cache_month_coverage"] = False
        checks["cache_window_alignment"] = False
        failures.append(
            f"CacheWindowUnusable: start_date {start.isoformat()} is after end_date "
            f"{end.isoformat()}"
        )
        return
    expected = list(range(_month_index(start), _month_index(end) + 1))
    if scan.months != expected:
        checks["cache_month_coverage"] = False
        failures.append(
            f"CacheMonthCoverageMismatch: manifest months {scan.months!r} != declared window "
            f"{start.isoformat()}..{end.isoformat()} ({expected!r})"
        )
    if scan.first_candle_month != _month_index(start):
        checks["cache_window_alignment"] = False
        failures.append(
            f"CacheWindowAlignmentMismatch: first candle month does not match start_date "
            f"{start.isoformat()}"
        )
    if scan.last_candle_month != _month_index(end):
        checks["cache_window_alignment"] = False
        failures.append(
            f"CacheWindowAlignmentMismatch: last candle month does not match end_date "
            f"{end.isoformat()}"
        )


def _verify_cache_source_identity(
    manifest: dict, source: QualifiedSource, checks: dict, failures: list
) -> None:
    inputs = manifest.get("inputs")
    recorded = inputs.get("composition") if isinstance(inputs, dict) else None
    if not isinstance(recorded, dict):
        checks["cache_source_identity"] = False
        failures.append(
            "CacheSourceIdentityMissing: manifest.inputs.composition is not an object"
        )
        return
    composition = source.composition
    if recorded.get("sha256") != source.composition_sha256:
        checks["cache_source_identity"] = False
        failures.append(
            f"CacheSourceIdentityMismatch: composition sha256 {recorded.get('sha256')!r} != "
            f"{source.composition_sha256!r}"
        )
    if recorded.get("ordered_source_semantic_digest") != composition["semantic"][
        "ordered_source_semantic_digest"
    ]:
        checks["cache_source_identity"] = False
        failures.append(
            "CacheSourceIdentityMismatch: ordered_source_semantic_digest does not match the "
            "qualified composition"
        )
    if recorded.get("accepted_row_count") != composition["counts"]["accepted_row_count"]:
        checks["cache_source_identity"] = False
        failures.append(
            "CacheSourceIdentityMismatch: accepted_row_count does not match the qualified "
            "composition"
        )
    if recorded.get("data_time_zone") != "UTC":
        checks["cache_source_identity"] = False
        failures.append(
            "CacheSourceIdentityMismatch: data_time_zone is not the qualified UTC"
        )


def verify_candles(data_folder: Path, cache: Path) -> CandleVerificationOutcome:
    """Re-verifies the qualified source and a generated cache without deriving candles."""
    data_folder = Path(data_folder)
    cache = Path(cache)
    if not data_folder.is_dir():
        return CandleVerificationOutcome(2, [f"DataFolderNotFound: {data_folder}"], None)
    if not cache.is_dir():
        return CandleVerificationOutcome(2, [f"CacheFolderNotFound: {cache}"], None)
    try:
        source = _load_qualified_source(data_folder)
    except CandleCacheError as error:
        return CandleVerificationOutcome(2, [f"NativeDataUnusable: {error}"], None)
    except SourceIdentityError as error:
        return CandleVerificationOutcome(
            2, [f"QualificationIdentityRefused: {error}"], None
        )

    checks = {
        "source_partition_set": True,
        "source_zip_hashes": True,
        "cache_manifest": True,
        "cache_file_records": True,
        "cache_content_sha256": True,
        "cache_totals": True,
        "cache_month_coverage": True,
        "cache_window_alignment": True,
        "cache_source_identity": True,
    }
    failures: list[str] = []
    partitions_verified = 0
    unreadable: list[str] = []
    mismatched: list[str] = []
    for relative, artifact in sorted(source.partitions_by_path.items()):
        path = data_folder.joinpath(*relative.split("/"))
        try:
            actual = sha256_file(path)
        except OSError as error:
            unreadable.append(f"{relative} ({error})")
            continue
        if actual != artifact["zip_sha256"]:
            mismatched.append(relative)
            continue
        partitions_verified += 1
    if unreadable:
        checks["source_zip_hashes"] = False
        failures.append(
            f"SourcePartitionsUnreadable: {len(unreadable)} partition(s): "
            + ", ".join(unreadable[:3])
        )
    if mismatched:
        checks["source_zip_hashes"] = False
        failures.append(
            f"SourcePartitionHashMismatch: {len(mismatched)} partition(s): "
            + ", ".join(mismatched[:3])
        )

    manifest_file = cache / MANIFEST_NAME
    manifest = None
    manifest_sha256 = None
    if not manifest_file.is_file():
        checks["cache_manifest"] = False
        failures.append(f"CacheManifestMissing: {manifest_file}")
    else:
        try:
            manifest_sha256 = sha256_file(manifest_file)
            payload = json.loads(manifest_file.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            checks["cache_manifest"] = False
            failures.append(f"CacheManifestUnreadable: {manifest_file}: {error}")
        else:
            if not isinstance(payload, dict):
                checks["cache_manifest"] = False
                failures.append(f"CacheManifestNotAnObject: {manifest_file}")
            elif payload.get("contract") != CANDLE_CONTRACT:
                checks["cache_manifest"] = False
                failures.append(
                    f"CacheManifestContractMismatch: expected {CANDLE_CONTRACT}, found "
                    f"{payload.get('contract')!r}"
                )
            else:
                manifest = payload

    scan = CacheScan()
    if manifest is None:
        for name in (
            "cache_file_records",
            "cache_content_sha256",
            "cache_totals",
            "cache_month_coverage",
            "cache_window_alignment",
            "cache_source_identity",
        ):
            checks[name] = False
    else:
        scan = _verify_cache_files(cache, manifest, checks, failures)
        _verify_cache_totals(manifest, scan, source, checks, failures)
        _verify_cache_window(manifest, scan, checks, failures)
        _verify_cache_source_identity(manifest, source, checks, failures)

    record = {
        "contract": VERIFICATION_CONTRACT,
        "data_folder_name": data_folder.name,
        "cache_folder_name": cache.name,
        "composition": {
            "relative_path": composition_path(data_folder)
            .relative_to(data_folder)
            .as_posix(),
            "sha256": source.composition_sha256,
            "accepted_row_count": source.composition["counts"]["accepted_row_count"],
            "partition_count": len(source.composition["native"]["partitions"]),
            "partitions_verified": partitions_verified,
        },
        "qualification_record": {
            "relative_path": continuous_record_path(data_folder)
            .relative_to(data_folder)
            .as_posix(),
            "sha256": source.record_sha256,
            "overall_qualification": source.record["overall_qualification"],
        },
        "cache": {
            "manifest": MANIFEST_NAME,
            "manifest_sha256": manifest_sha256,
            "start_date": manifest.get("start_date") if manifest else None,
            "end_date": manifest.get("end_date") if manifest else None,
            "files": scan.files if manifest else None,
            "candle_rows": scan.rows if manifest else None,
            "candle_bytes": scan.bytes if manifest else None,
            "content_sha256": scan.content_sha256 if manifest else None,
        },
        "checks": checks,
        "failure_reasons": failures,
        "overall_qualification": "PASS" if not failures else "FAIL",
    }
    exit_code = 0 if not failures else 1
    return CandleVerificationOutcome(exit_code, failures, record)
