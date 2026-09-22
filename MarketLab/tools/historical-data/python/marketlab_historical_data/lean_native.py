"""Native LEAN quote-tick file layout and writing.

The actual LEAN engine in this checkout reads quote ticks for
``Symbol.Create("XAUUSD", SecurityType.Cfd, Market.Oanda)`` from:

    <data-folder>/cfd/oanda/tick/xauusd/YYYYMMDD_quote.zip
    member: YYYYMMDD_xauusd_tick_quote.csv
    line:   <milliseconds since DataTimeZone-local midnight>,<bid>,<ask>

The partition date and the millisecond value are in the subscription's
``DataTimeZone`` (resolved from the runtime market-hours database), not the
exchange time zone and not necessarily UTC. LEAN's reader converts
``DataTimeZone -> ExchangeTimeZone`` itself when it parses each line
(``Common/Data/Market/Tick.cs``), and only then do its normal session filters
apply.

File and member names follow ``LeanData.GenerateZipFilePath`` /
``GenerateZipFileName`` / ``GenerateZipEntryName`` in the current repository.
This writer adapts the qualified source to that contract; it does not modify
the reader. Prices are written as canonical exact-decimal text; time is an
integer millisecond count, so no rounding ever occurs.
"""

from __future__ import annotations

import hashlib
import io
import zipfile
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from .canonical import canonical_decimal_text, canonical_utc_timestamp_text

__all__ = [
    "NativeConversionError",
    "NativeLeanTickLayout",
    "NativePartitionArtifact",
    "NativeTickWriter",
    "milliseconds_since_local_midnight",
]

ZIP_ENTRY_FIXED_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


class NativeConversionError(Exception):
    """A qualified row cannot be represented in the native LEAN tick contract."""


@dataclass(frozen=True)
class NativeLeanTickLayout:
    """The native file/member naming for one subscription."""

    symbol: str
    market: str
    security_type: str

    @property
    def relative_directory(self) -> str:
        return (
            f"{self.security_type.lower()}/{self.market.lower()}/tick/"
            f"{self.symbol.lower()}"
        )

    @property
    def member_name_pattern(self) -> str:
        return f"YYYYMMDD_{self.symbol.lower()}_tick_quote.csv"

    @property
    def zip_name_pattern(self) -> str:
        return "YYYYMMDD_quote.zip"

    def zip_name(self, partition: date) -> str:
        return f"{partition:%Y%m%d}_quote.zip"

    def member_name(self, partition: date) -> str:
        return f"{partition:%Y%m%d}_{self.symbol.lower()}_tick_quote.csv"

    def zip_path(self, data_root: Path, partition: date) -> Path:
        return Path(data_root) / self.relative_directory / self.zip_name(partition)

    def describe(self) -> dict:
        return {
            "zip_directory": self.relative_directory,
            "zip_name_pattern": self.zip_name_pattern,
            "member_name_pattern": self.member_name_pattern,
            "line_format": "time,bid,ask",
            "time_encoding": "milliseconds_since_data_time_zone_local_midnight",
            "price_encoding": "canonical_exact_decimal_text",
        }


@dataclass(frozen=True)
class NativePartitionArtifact:
    """One generated zip and its deterministic content identity."""

    partition: date
    zip_relative_path: str
    zip_sha256: str
    member_name: str
    member_sha256: str
    member_size_bytes: int
    row_count: int
    first_millisecond: int
    last_millisecond: int

    def describe(self) -> dict:
        return {
            "partition": self.partition.isoformat(),
            "zip_relative_path": self.zip_relative_path,
            "zip_sha256": self.zip_sha256,
            "member_name": self.member_name,
            "member_sha256": self.member_sha256,
            "member_size_bytes": self.member_size_bytes,
            "row_count": self.row_count,
            "first_millisecond": self.first_millisecond,
            "last_millisecond": self.last_millisecond,
        }


def milliseconds_since_local_midnight(local_time: datetime) -> int:
    """Exact milliseconds since local midnight for a millisecond-exact timestamp."""
    if local_time.tzinfo is None:
        raise NativeConversionError("local partition time must be timezone-aware")
    if local_time.microsecond % 1000 != 0:
        raise NativeConversionError(
            f"timestamp {local_time.isoformat()} has sub-millisecond precision and cannot be "
            "written to a native LEAN tick file"
        )
    return (
        ((local_time.hour * 60 + local_time.minute) * 60 + local_time.second) * 1000
        + local_time.microsecond // 1000
    )


def build_zip_bytes(member_name: str, content: bytes) -> bytes:
    """Builds a deterministic zip with one member and no timestamp variance."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        info = zipfile.ZipInfo(member_name, date_time=ZIP_ENTRY_FIXED_TIMESTAMP)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, content)
    return buffer.getvalue()


class NativeTickWriter:
    """Streams qualified rows into staged native LEAN partitions.

    Rows must arrive in non-decreasing canonical UTC order. They are grouped by
    ``DataTimeZone``-local date; each partition's milliseconds must be
    non-decreasing (a repeated or wrapped local clock inside a partition - for
    example a fall-back DST transition in the data time zone - fails explicitly
    instead of writing a file LEAN would read out of order).
    """

    def __init__(
        self,
        data_root: Path,
        layout: NativeLeanTickLayout,
        data_zone: ZoneInfo,
        transaction,
    ) -> None:
        self._data_root = Path(data_root)
        self._layout = layout
        self._data_zone = data_zone
        self._transaction = transaction
        self._partitions: list[NativePartitionArtifact] = []
        self._current_partition: date | None = None
        self._current_lines: list[str] = []
        self._current_first_ms: int | None = None
        self._current_last_ms: int | None = None
        self._last_partition: date | None = None
        self._last_utc: datetime | None = None

    def add(self, utc: datetime, bid, ask) -> None:
        if utc.tzinfo is None:
            raise NativeConversionError("row timestamp must be timezone-aware")
        utc = utc.astimezone(timezone.utc)
        if self._last_utc is not None and utc < self._last_utc:
            raise NativeConversionError(
                f"conversion received an out-of-order row: {canonical_utc_timestamp_text(utc)} "
                f"after {canonical_utc_timestamp_text(self._last_utc)}"
            )
        local = utc.astimezone(self._data_zone)
        partition = local.date()
        millisecond = milliseconds_since_local_midnight(local)
        if self._current_partition != partition:
            self._close_partition()
            if self._last_partition is not None and partition <= self._last_partition:
                raise NativeConversionError(
                    f"data-timezone partition {partition.isoformat()} does not follow "
                    f"{self._last_partition.isoformat()}"
                )
            self._current_partition = partition
            self._current_lines = []
            self._current_first_ms = millisecond
            self._current_last_ms = None
        if self._current_last_ms is not None and millisecond < self._current_last_ms:
            raise NativeConversionError(
                f"data-timezone time-of-day went backwards inside partition "
                f"{partition.isoformat()}: {millisecond} ms after {self._current_last_ms} ms; "
                "the resolved DataTimeZone must be UTC-like for an exact native replay"
            )
        self._current_lines.append(
            f"{millisecond},{canonical_decimal_text(bid)},{canonical_decimal_text(ask)}"
        )
        self._current_last_ms = millisecond
        self._last_utc = utc

    def finish(self) -> tuple[NativePartitionArtifact, ...]:
        self._close_partition()
        return tuple(self._partitions)

    def _close_partition(self) -> None:
        if self._current_partition is None:
            return
        content = "\n".join(self._current_lines).encode("utf-8")
        member_name = self._layout.member_name(self._current_partition)
        zip_bytes = build_zip_bytes(member_name, content)
        final_path = self._layout.zip_path(self._data_root, self._current_partition)
        self._transaction.stage_bytes(final_path, zip_bytes)
        artifact = NativePartitionArtifact(
            partition=self._current_partition,
            zip_relative_path=f"{self._layout.relative_directory}/{self._layout.zip_name(self._current_partition)}",
            zip_sha256=hashlib.sha256(zip_bytes).hexdigest(),
            member_name=member_name,
            member_sha256=hashlib.sha256(content).hexdigest(),
            member_size_bytes=len(content),
            row_count=len(self._current_lines),
            first_millisecond=self._current_first_ms if self._current_first_ms is not None else 0,
            last_millisecond=self._current_last_ms if self._current_last_ms is not None else 0,
        )
        self._partitions.append(artifact)
        self._last_partition = self._current_partition
        self._current_partition = None
        self._current_lines = []
        self._current_first_ms = None
        self._current_last_ms = None
