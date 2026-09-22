"""Strict qualification of a historical bid/ask CSV source.

The authoritative SingleAnchor input contract is::

    Bid > 0
    Ask > 0
    Ask >= Bid
    timestamp is valid
    timestamps are non-decreasing
    equal timestamps are allowed
    source order is preserved

A zero spread is valid. The qualification path is strict: ``source ->
validate -> PASS or FAIL -> convert only after PASS``. It never discards an
invalid row silently, never sorts, never deduplicates, never interpolates or
fills, never repairs values or timestamps and never alters source order. Any
rejected row fails the dataset qualification; the accepted rows and all
diagnostics are still recorded in the manifest as evidence.

Source order is the authority: a row whose timestamp is earlier than the last
accepted timestamp is rejected (``decreasing_timestamp``), not moved.

Column resolution is deterministic: an explicit configuration always wins;
otherwise normalized header names are matched against a fixed candidate list
(adapted from the retired ``quant_research_app`` market-data module, see
``PROVENANCE.md``). The interpreted contract is recorded in the manifest.

Prices are parsed as exact ``decimal.Decimal`` from the source text. Binary
floating point is never used for converted values or comparisons.
"""

from __future__ import annotations

import csv
import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from zoneinfo import ZoneInfo

from .canonical import (
    CanonicalValueError,
    SemanticStreamDigest,
    canonical_decimal_text,
    canonical_utc_timestamp_text,
    lean_decimal_representable,
    parse_decimal_text,
)

__all__ = [
    "CsvSourceConfig",
    "QualificationFailure",
    "RejectedRow",
    "ResolvedCsvLayout",
    "SessionPreview",
    "SourceQualification",
    "TimestampContract",
    "convert_source",
    "qualify_source",
    "resolve_csv_layout",
]

_TIMESTAMP_CANDIDATES = ("timestamp", "datetime", "date_time")
_DATE_CANDIDATES = ("date",)
_TIME_CANDIDATES = ("time",)
_BID_CANDIDATES = ("bid",)
_ASK_CANDIDATES = ("ask",)

_TIMESTAMP_FORMATS = (
    "%Y-%m-%d %H:%M:%S.%f",
    "%Y-%m-%d %H:%M:%S",
    "%Y.%m.%d %H:%M:%S.%f",
    "%Y.%m.%d %H:%M:%S",
    "%Y-%m-%dT%H:%M:%S.%f",
    "%Y-%m-%dT%H:%M:%S",
)

_OFFSET_SUFFIX = re.compile(r"(?:Z|[+-]\d{2}:\d{2})$")
_FRACTION = re.compile(r"(?<=\d{2}:\d{2}:\d{2})\.(\d+)")

MAX_REJECTION_SAMPLES = 10


class QualificationFailure(Exception):
    """Raised for an unusable source configuration or an internal inconsistency."""


@dataclass(frozen=True)
class CsvSourceConfig:
    """Explicit source contract. Every field overrides deterministic detection."""

    delimiter: str | None = None
    timestamp_column: str | None = None
    date_column: str | None = None
    time_column: str | None = None
    bid_column: str | None = None
    ask_column: str | None = None
    timestamp_format: str | None = None
    source_timezone: str | None = None
    encoding: str = "utf-8-sig"

    def describe(self) -> dict:
        return {
            "delimiter": self.delimiter,
            "timestamp_column": self.timestamp_column,
            "date_column": self.date_column,
            "time_column": self.time_column,
            "bid_column": self.bid_column,
            "ask_column": self.ask_column,
            "timestamp_format": self.timestamp_format,
            "source_timezone": self.source_timezone,
            "encoding": self.encoding,
        }


@dataclass(frozen=True)
class ResolvedCsvLayout:
    """The deterministic column/addressing interpretation of one source file."""

    delimiter: str
    fieldnames: tuple[str, ...]
    timestamp_mode: str
    timestamp_index: int | None
    date_index: int | None
    time_index: int | None
    bid_index: int
    ask_index: int
    timestamp_column: str | None
    date_column: str | None
    time_column: str | None
    bid_column: str
    ask_column: str


@dataclass(frozen=True)
class RejectedRow:
    row_number: int
    reason: str
    message: str


@dataclass(frozen=True)
class SessionPreview:
    """Diagnostic view of the resolved exchange session window (not the authority)."""

    preview_exact: bool
    session_eligible_rows: int
    session_excluded_rows: int


@dataclass
class _Counters:
    raw_row_count: int = 0
    accepted_row_count: int = 0
    rejected_row_count: int = 0
    out_of_order_count: int = 0
    duplicate_timestamp_count: int = 0
    sub_millisecond_row_count: int = 0
    same_lean_millisecond_collision_count: int = 0
    same_lean_millisecond_collision_groups: int = 0
    maximum_rows_per_lean_millisecond: int = 0
    rejection_reasons: Counter = field(default_factory=Counter)
    rejection_samples: list[RejectedRow] = field(default_factory=list)
    per_day_accepted_counts: Counter = field(default_factory=Counter)
    per_partition_counts: Counter = field(default_factory=Counter)
    per_partition_digests: dict = field(default_factory=dict)
    session_eligible_rows: int = 0
    session_excluded_rows: int = 0


@dataclass
class SourceQualification:
    """Everything pass 1 established about the accepted source stream."""

    layout: ResolvedCsvLayout
    config: CsvSourceConfig
    timestamp_contract: "TimestampContract"
    counters: _Counters
    first_canonical_utc: str | None
    last_canonical_utc: str | None
    source_semantic_digest: str | None
    spread_min: str | None
    spread_max: str | None
    spread_mean: str | None
    spread_median: str | None
    spread_statistics_complete: bool
    nonzero_decimal_unrepresentable_count: int
    session_preview: SessionPreview | None

    @property
    def source_qualification_passed(self) -> bool:
        return self.counters.rejected_row_count == 0 and not self.timestamp_contract.mixed

    @property
    def timestamp_precision_passed(self) -> bool:
        return self.counters.sub_millisecond_row_count == 0

    @property
    def decimal_parity_passed(self) -> bool:
        return self.nonzero_decimal_unrepresentable_count == 0


@dataclass
class TimestampContract:
    """The interpreted source timestamp representation, bound file-wide."""

    representation: str | None = None
    source_timezone: str | None = None
    timestamp_format: str | None = None
    max_fraction_digits: int = 0
    mixed: bool = False

    def observe(self, representation: str, fraction_digits: int) -> str | None:
        if self.representation is None:
            self.representation = representation
        elif self.representation != representation:
            self.mixed = True
            return "timestamp_representation_mixed"
        if fraction_digits > self.max_fraction_digits:
            self.max_fraction_digits = fraction_digits
        return None

    def describe(self) -> dict:
        return {
            "representation": self.representation,
            "source_timezone": self.source_timezone,
            "timestamp_format": self.timestamp_format,
            "max_fraction_digits": self.max_fraction_digits,
            "mixed_representations": self.mixed,
        }


def normalize_header(name: str) -> str:
    """Normalizes a header cell: trim, lowercase, unwrap ``<name>``, spaces to ``_``."""
    text = name.strip().lower()
    if text.startswith("<") and text.endswith(">") and len(text) >= 2:
        text = text[1:-1]
    text = re.sub(r"[\s\-]+", "_", text)
    text = re.sub(r"_+", "_", text)
    return text.strip("_")


def _resolve_delimiter(path: Path, encoding: str, explicit: str | None) -> str:
    if explicit is not None:
        if explicit == "":
            raise QualificationFailure("delimiter must not be empty")
        return "\t" if explicit == "\\t" else explicit
    with path.open("r", encoding=encoding, newline="") as handle:
        sample = handle.read(4096)
    try:
        return csv.Sniffer().sniff(sample, delimiters=",;\t").delimiter
    except csv.Error:
        return ","


def _read_header(path: Path, encoding: str, delimiter: str) -> tuple[str, ...]:
    with path.open("r", encoding=encoding, newline="") as handle:
        reader = csv.reader(handle, delimiter=delimiter, skipinitialspace=True)
        try:
            return tuple(next(reader))
        except StopIteration as error:
            raise QualificationFailure(f"source file is empty: {path}") from error


def _build_header_lookup(fieldnames: tuple[str, ...]) -> dict[str, int]:
    lookup: dict[str, int] = {}
    for index, name in enumerate(fieldnames):
        key = normalize_header(name)
        if key not in lookup:
            lookup[key] = index
    return lookup


def _resolve_explicit_column(
    lookup: dict[str, int], fieldnames: tuple[str, ...], requested: str, role: str
) -> int:
    key = normalize_header(requested)
    if key not in lookup:
        raise QualificationFailure(
            f"{role} column {requested!r} not found in the source header {fieldnames!r}"
        )
    return lookup[key]


def resolve_csv_layout(path: Path, config: CsvSourceConfig) -> ResolvedCsvLayout:
    """Resolves the delimiter and column addressing deterministically.

    Explicit configuration always wins; otherwise the fixed candidate lists and
    the date+time pair rule decide. The result is part of the manifest.
    """
    delimiter = _resolve_delimiter(Path(path), config.encoding, config.delimiter)
    fieldnames = _read_header(Path(path), config.encoding, delimiter)
    lookup = _build_header_lookup(fieldnames)

    timestamp_index: int | None = None
    date_index: int | None = None
    time_index: int | None = None
    timestamp_mode = "single"

    if config.timestamp_column is not None:
        timestamp_index = _resolve_explicit_column(
            lookup, fieldnames, config.timestamp_column, "timestamp"
        )
    elif config.date_column is not None or config.time_column is not None:
        timestamp_mode = "date_time"
        if config.date_column is not None:
            date_index = _resolve_explicit_column(lookup, fieldnames, config.date_column, "date")
        if config.time_column is not None:
            time_index = _resolve_explicit_column(lookup, fieldnames, config.time_column, "time")
        if date_index is None:
            date_index = _first_present(lookup, _DATE_CANDIDATES, role="date")
        if time_index is None:
            time_index = _first_present(lookup, _TIME_CANDIDATES, role="time")
    else:
        candidate = _first_present_or_none(lookup, _TIMESTAMP_CANDIDATES)
        date_candidate = _first_present_or_none(lookup, _DATE_CANDIDATES)
        time_candidate = _first_present_or_none(lookup, _TIME_CANDIDATES)
        if candidate is not None:
            timestamp_index = candidate
        elif date_candidate is not None and time_candidate is not None:
            timestamp_mode = "date_time"
            date_index = date_candidate
            time_index = time_candidate
        else:
            raise QualificationFailure(
                "source needs a timestamp column, or deterministic candidates "
                f"(one of {_TIMESTAMP_CANDIDATES!r} or a date+time pair); header was {fieldnames!r}"
            )

    if config.bid_column is not None:
        bid_index = _resolve_explicit_column(lookup, fieldnames, config.bid_column, "bid")
    else:
        bid_index = _first_present(lookup, _BID_CANDIDATES, role="bid")
    if config.ask_column is not None:
        ask_index = _resolve_explicit_column(lookup, fieldnames, config.ask_column, "ask")
    else:
        ask_index = _first_present(lookup, _ASK_CANDIDATES, role="ask")

    return ResolvedCsvLayout(
        delimiter=delimiter,
        fieldnames=fieldnames,
        timestamp_mode=timestamp_mode,
        timestamp_index=timestamp_index,
        date_index=date_index,
        time_index=time_index,
        bid_index=bid_index,
        ask_index=ask_index,
        timestamp_column=fieldnames[timestamp_index] if timestamp_index is not None else None,
        date_column=fieldnames[date_index] if date_index is not None else None,
        time_column=fieldnames[time_index] if time_index is not None else None,
        bid_column=fieldnames[bid_index],
        ask_column=fieldnames[ask_index],
    )


def _first_present(lookup: dict[str, int], candidates: tuple[str, ...], role: str) -> int:
    index = _first_present_or_none(lookup, candidates)
    if index is None:
        raise QualificationFailure(
            f"no {role} column found; expected one of {candidates!r}, header keys {sorted(lookup)!r}"
        )
    return index


def _first_present_or_none(lookup: dict[str, int], candidates: tuple[str, ...]) -> int | None:
    for candidate in candidates:
        if candidate in lookup:
            return lookup[candidate]
    return None


def _truncate_fraction(text: str) -> tuple[str, int, bool]:
    """Returns text with the fractional part limited to microseconds and the digit counts."""
    match = _FRACTION.search(text)
    if match is None:
        return text, 0, False
    digits = match.group(1)
    if len(digits) <= 6:
        return text, len(digits), False
    truncated = text[: match.start(1)] + digits[:6] + text[match.end(1) :]
    lost_sub_microsecond = any(digit != "0" for digit in digits[6:])
    return truncated, len(digits), lost_sub_microsecond


def parse_timestamp_text(
    text: str, timestamp_format: str | None, field: str
) -> tuple[datetime, str, int, bool]:
    """Parses one timestamp text exactly.

    Returns ``(parsed, representation, fraction_digits, sub_millisecond)`` where
    representation is ``naive`` or ``embedded_offset``. Fractional digits
    beyond microseconds are never silently dropped: they set the
    sub-millisecond flag (or fail parsing when the value changes).
    """
    stripped = text.strip()
    if not stripped:
        raise CanonicalValueError(f"{field} is blank")
    truncated, fraction_digits, lost_sub_microsecond = _truncate_fraction(stripped)
    sub_millisecond = lost_sub_microsecond

    if timestamp_format is not None:
        try:
            parsed = datetime.strptime(truncated, timestamp_format)
        except ValueError as error:
            raise CanonicalValueError(
                f"{field} does not match timestamp format {timestamp_format!r}: {text!r}"
            ) from error
    elif _OFFSET_SUFFIX.search(truncated):
        normalized = truncated[:-1] + "+00:00" if truncated.endswith("Z") else truncated
        try:
            parsed = datetime.fromisoformat(normalized)
        except ValueError as error:
            raise CanonicalValueError(f"{field} is not a valid timestamp: {text!r}") from error
    else:
        parsed = None
        for candidate_format in _TIMESTAMP_FORMATS:
            try:
                parsed = datetime.strptime(truncated, candidate_format)
                break
            except ValueError:
                continue
        if parsed is None:
            raise CanonicalValueError(f"{field} is not a valid timestamp: {text!r}")

    if parsed.tzinfo is not None:
        representation = "embedded_offset"
    else:
        representation = "naive"
    if parsed.microsecond % 1000 != 0:
        sub_millisecond = True
    return parsed, representation, fraction_digits, sub_millisecond


def localize_naive(value: datetime, zone: ZoneInfo, field: str) -> datetime:
    """Attaches a declared source timezone, rejecting gaps and ambiguous folds."""
    first = value.replace(tzinfo=zone, fold=0)
    second = value.replace(tzinfo=zone, fold=1)
    first_round_trips = first.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) == value
    second_round_trips = (
        second.astimezone(timezone.utc).astimezone(zone).replace(tzinfo=None) == value
    )
    if not first_round_trips and not second_round_trips:
        raise CanonicalValueError(
            f"{field} {value.isoformat()} does not exist in timezone {zone.key} (DST gap)"
        )
    if first_round_trips and second_round_trips and first.utcoffset() != second.utcoffset():
        raise CanonicalValueError(
            f"{field} {value.isoformat()} is ambiguous in timezone {zone.key} (DST fold)"
        )
    return first if first_round_trips else second


def normalize_source_timestamp(
    parsed: datetime, representation: str, source_zone: ZoneInfo | None, field: str
) -> datetime:
    """Normalizes a parsed timestamp to canonical UTC under the declared contract."""
    if representation == "embedded_offset":
        if source_zone is not None:
            raise CanonicalValueError(
                f"{field} carries an embedded UTC offset; a source timezone must not be declared"
            )
        return parsed.astimezone(timezone.utc)
    if source_zone is None:
        raise CanonicalValueError(
            f"{field} is timezone-naive; declare the source timezone (IANA name)"
        )
    return localize_naive(parsed, source_zone, field).astimezone(timezone.utc)


@dataclass(frozen=True)
class _ParsedRow:
    """One accepted source quote; prices and timestamp are exact values."""

    utc: datetime
    bid: Decimal
    ask: Decimal
    sub_millisecond: bool


def _iter_source_rows(
    source_path: Path,
    layout: ResolvedCsvLayout,
    config: CsvSourceConfig,
    tracker: TimestampContract,
    source_zone: ZoneInfo | None,
):
    """Yields ``(row_number, parsed_row, rejection)`` for every physical CSV data row."""
    with source_path.open("r", encoding=config.encoding, newline="") as handle:
        reader = csv.reader(handle, delimiter=layout.delimiter, skipinitialspace=True)
        next(reader, None)

        for cells in reader:
            row_number = reader.line_num
            if _row_is_empty(cells):
                yield row_number, None, RejectedRow(row_number, "empty_row", "row is empty")
                continue

            if layout.timestamp_mode == "single":
                timestamp_text = _cell(cells, layout.timestamp_index)
            else:
                date_text = _cell(cells, layout.date_index)
                time_text = _cell(cells, layout.time_index)
                timestamp_text = f"{date_text.strip()} {time_text.strip()}".strip()
            bid_text = _cell(cells, layout.bid_index)
            ask_text = _cell(cells, layout.ask_index)

            if len(cells) > len(layout.fieldnames):
                yield (
                    row_number,
                    None,
                    RejectedRow(
                        row_number,
                        "malformed_row",
                        f"{len(cells)} cells for {len(layout.fieldnames)} header columns",
                    ),
                )
                continue

            if not timestamp_text.strip():
                yield row_number, None, RejectedRow(row_number, "blank_timestamp", "timestamp is blank")
                continue
            try:
                parsed, representation, fraction_digits, sub_millisecond = parse_timestamp_text(
                    timestamp_text, config.timestamp_format, "timestamp"
                )
                contract_rejection = tracker.observe(representation, fraction_digits)
                if contract_rejection is not None:
                    yield (
                        row_number,
                        None,
                        RejectedRow(
                            row_number,
                            contract_rejection,
                            f"timestamp representation {representation!r} conflicts with the "
                            f"file-wide {tracker.representation!r} representation",
                        ),
                    )
                    continue
                utc = normalize_source_timestamp(parsed, representation, source_zone, "timestamp")
            except CanonicalValueError as error:
                yield row_number, None, RejectedRow(row_number, "invalid_timestamp", str(error))
                continue

            bid = _parse_price_cell(bid_text, row_number, "bid")
            if isinstance(bid, RejectedRow):
                yield row_number, None, bid
                continue
            ask = _parse_price_cell(ask_text, row_number, "ask")
            if isinstance(ask, RejectedRow):
                yield row_number, None, ask
                continue

            assert isinstance(bid, Decimal) and isinstance(ask, Decimal)
            if ask < bid:
                yield (
                    row_number,
                    None,
                    RejectedRow(
                        row_number,
                        "ask_less_than_bid",
                        f"ask {ask_text!r} is less than bid {bid_text!r}",
                    ),
                )
                continue

            yield (
                row_number,
                _ParsedRow(utc, bid, ask, sub_millisecond),
                None,
            )


def _row_is_empty(cells: list[str]) -> bool:
    return all(cell.strip() == "" for cell in cells)


def _cell(cells: list[str], index: int | None) -> str:
    if index is None or index >= len(cells):
        return ""
    return cells[index]


def _parse_price_cell(text: str, row_number: int, role: str) -> Decimal | RejectedRow:
    if not text.strip():
        return RejectedRow(row_number, f"blank_{role}", f"{role} is blank")
    try:
        value = parse_decimal_text(text, role)
    except CanonicalValueError as error:
        return RejectedRow(row_number, f"invalid_{role}", str(error))
    if value <= 0:
        return RejectedRow(row_number, f"non_positive_{role}", f"{role} {text!r} is not positive")
    return value


def qualify_source(
    source_path: Path,
    layout: ResolvedCsvLayout,
    config: CsvSourceConfig,
    data_zone: ZoneInfo,
    source_zone: ZoneInfo | None,
    session_evaluator=None,
) -> SourceQualification:
    """Pass 1: validates the whole source and records the accepted stream facts.

    Nothing is written and no row is modified; the caller converts only after
    this returns a passing qualification.
    """
    source_path = Path(source_path)
    tracker = TimestampContract(
        source_timezone=config.source_timezone, timestamp_format=config.timestamp_format
    )
    counters = _Counters()
    digest = SemanticStreamDigest()
    digest_valid = True
    prev_utc: datetime | None = None
    prev_slot: tuple[str, int] | None = None
    rows_in_slot = 0
    distinct_in_slot = 0
    first_utc: datetime | None = None
    last_utc: datetime | None = None
    spread_histogram: Counter = Counter()
    spread_sum = Decimal(0)
    spread_min: Decimal | None = None
    spread_max: Decimal | None = None
    unrepresentable_count = 0
    spread_statistics_complete = True

    for row_number, parsed_row, rejection in _iter_source_rows(
        source_path, layout, config, tracker, source_zone
    ):
        counters.raw_row_count += 1
        if rejection is not None:
            _record_rejection(counters, rejection)
            continue

        assert isinstance(parsed_row, _ParsedRow)
        row = parsed_row
        if prev_utc is not None and row.utc < prev_utc:
            counters.out_of_order_count += 1
            _record_rejection(
                counters,
                RejectedRow(
                    row_number,
                    "decreasing_timestamp",
                    f"timestamp {row.utc.isoformat()} is earlier than the previous accepted "
                    f"timestamp {prev_utc.isoformat()}",
                ),
            )
            continue

        is_duplicate = prev_utc is not None and row.utc == prev_utc
        local = row.utc.astimezone(data_zone)
        partition_key = local.date().isoformat()
        slot = (partition_key, local.hour * 3600000 + local.minute * 60000 + local.second * 1000 + local.microsecond // 1000)
        if prev_slot is not None and slot == prev_slot:
            rows_in_slot += 1
            if not is_duplicate:
                counters.same_lean_millisecond_collision_count += 1
                distinct_in_slot += 1
        else:
            if distinct_in_slot > 1:
                counters.same_lean_millisecond_collision_groups += 1
            counters.maximum_rows_per_lean_millisecond = max(
                counters.maximum_rows_per_lean_millisecond, rows_in_slot
            )
            rows_in_slot = 1
            distinct_in_slot = 1
            prev_slot = slot
        if is_duplicate:
            counters.duplicate_timestamp_count += 1

        representable = lean_decimal_representable(row.bid) and lean_decimal_representable(
            row.ask
        )
        if not representable:
            unrepresentable_count += 1
            digest_valid = False
            spread_statistics_complete = False
        else:
            spread = row.ask - row.bid
            spread_histogram[spread] += 1
            spread_sum += spread
            spread_min = spread if spread_min is None else min(spread_min, spread)
            spread_max = spread if spread_max is None else max(spread_max, spread)
        if parsed_row.sub_millisecond:
            counters.sub_millisecond_row_count += 1
            digest_valid = False
        elif representable:
            if digest_valid:
                digest.add(row.utc, row.bid, row.ask)
            counters.per_partition_digests.setdefault(partition_key, SemanticStreamDigest()).add(
                row.utc, row.bid, row.ask
            )

        counters.accepted_row_count += 1
        counters.per_day_accepted_counts[partition_key] += 1
        counters.per_partition_counts[partition_key] += 1
        if session_evaluator is not None:
            if session_evaluator.is_open(row.utc):
                counters.session_eligible_rows += 1
            else:
                counters.session_excluded_rows += 1
        if first_utc is None:
            first_utc = row.utc
        last_utc = row.utc
        prev_utc = row.utc

    if distinct_in_slot > 1:
        counters.same_lean_millisecond_collision_groups += 1
    counters.maximum_rows_per_lean_millisecond = max(
        counters.maximum_rows_per_lean_millisecond, rows_in_slot
    )

    if counters.rejected_row_count > 0:
        digest_valid = False
    if counters.sub_millisecond_row_count > 0:
        digest_valid = False

    session_preview = None
    if session_evaluator is not None:
        session_preview = SessionPreview(
            preview_exact=session_evaluator.preview_exact,
            session_eligible_rows=counters.session_eligible_rows,
            session_excluded_rows=counters.session_excluded_rows,
        )

    spread_min_text = canonical_decimal_text(spread_min) if spread_min is not None else None
    spread_max_text = canonical_decimal_text(spread_max) if spread_max is not None else None
    spread_mean_text = None
    spread_median_text = None
    spread_count = sum(spread_histogram.values())
    if spread_count > 0:
        spread_mean_text = canonical_decimal_text(spread_sum / spread_count)
        spread_median_text = canonical_decimal_text(_median_from_histogram(spread_histogram))

    return SourceQualification(
        layout=layout,
        config=config,
        timestamp_contract=tracker,
        counters=counters,
        first_canonical_utc=_canonical_timestamp_or_iso(first_utc),
        last_canonical_utc=_canonical_timestamp_or_iso(last_utc),
        source_semantic_digest=("sha256:" + digest.hexdigest()) if digest_valid else None,
        spread_min=spread_min_text,
        spread_max=spread_max_text,
        spread_mean=spread_mean_text,
        spread_median=spread_median_text,
        spread_statistics_complete=spread_statistics_complete,
        nonzero_decimal_unrepresentable_count=unrepresentable_count,
        session_preview=session_preview,
    )


def _canonical_timestamp_or_iso(value: datetime | None) -> str | None:
    """Canonical millisecond text when exact, otherwise the full-precision ISO form."""
    if value is None:
        return None
    utc = value.astimezone(timezone.utc)
    if utc.microsecond % 1000 == 0:
        return canonical_utc_timestamp_text(utc)
    return utc.isoformat()


def _median_from_histogram(histogram: Counter) -> Decimal:
    total = sum(histogram.values())
    if total == 0:
        raise QualificationFailure("empty spread histogram")
    keys = sorted(histogram)
    if total % 2 == 1:
        return _value_at_position(keys, histogram, (total + 1) // 2)
    lower = _value_at_position(keys, histogram, total // 2)
    upper = _value_at_position(keys, histogram, total // 2 + 1)
    return (lower + upper) / 2


def _value_at_position(keys, histogram: Counter, position: int) -> Decimal:
    cumulative = 0
    for value in keys:
        cumulative += histogram[value]
        if cumulative >= position:
            return value
    raise QualificationFailure("spread histogram position is out of range")


def _record_rejection(counters: _Counters, rejection: RejectedRow) -> None:
    counters.rejected_row_count += 1
    counters.rejection_reasons[rejection.reason] += 1
    if len(counters.rejection_samples) < MAX_REJECTION_SAMPLES:
        counters.rejection_samples.append(rejection)


def convert_source(
    source_path: Path,
    layout: ResolvedCsvLayout,
    config: CsvSourceConfig,
    source_zone: ZoneInfo | None,
    writer,
    expected_accepted_rows: int,
) -> int:
    """Pass 2: writes accepted rows to native LEAN partitions via ``writer``.

    Runs only after pass 1 passed. It re-runs the same strict row validation and
    refuses to write anything if the acceptance status or the accepted row count
    differs from pass 1 (defensive); full content identity of the written stream
    is established by the replay digest comparison. Returns the number of
    converted rows.
    """
    tracker = TimestampContract(
        source_timezone=config.source_timezone, timestamp_format=config.timestamp_format
    )
    converted = 0
    for row_number, parsed_row, rejection in _iter_source_rows(
        Path(source_path), layout, config, tracker, source_zone
    ):
        if rejection is not None:
            raise QualificationFailure(
                f"conversion pass rejected row {row_number} ({rejection.reason}) after pass 1 "
                "accepted it; the source is not deterministic"
            )
        assert isinstance(parsed_row, _ParsedRow)
        row = parsed_row
        writer.add(row.utc, row.bid, row.ask)
        converted += 1
    if converted != expected_accepted_rows:
        raise QualificationFailure(
            f"conversion pass counted {converted} accepted rows, pass 1 counted "
            f"{expected_accepted_rows}; the source is not deterministic"
        )
    return converted
