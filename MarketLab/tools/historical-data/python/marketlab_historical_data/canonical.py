"""Canonical exact-value representations and the semantic stream digest.

The semantic parity tuple for one accepted quote is::

    source ordinal | canonical UTC timestamp | canonical exact-decimal Bid | canonical exact-decimal Ask

serialized as one UTF-8 line per quote::

    {ordinal}|{yyyy-MM-ddTHH:mm:ss.fffZ}|{bid}|{ask}\n

``ordinal`` is 1-based in stream order. The digest is the SHA-256 of the
concatenated lines, recorded as ``sha256:<lowercase hex>``. The same
serialization is implemented by the C# replay probe
(``MarketLab/tools/historical-data/probe/SemanticStream.cs``) so the qualified
source stream and the LEAN-delivered stream can be compared exactly.

Canonical decimal text is fixed-point, invariant, without exponent, without a
leading ``+``, without trailing fractional zeros, and ``-0`` is rendered ``0``.
Numerically equal values therefore serialize identically regardless of their
source textual scale (``1.2``, ``1.20`` and ``1.200`` are one value).

The converter never uses binary floating point as an authority for converted
prices or timestamps, and the manifest's spread statistics are exact decimal
values too; Python ``float`` is not used anywhere on the qualification path.
"""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timezone
from decimal import Decimal

__all__ = [
    "CanonicalValueError",
    "DECIMAL_TEXT_PATTERN",
    "LEAN_DECIMAL_MAX_COEFFICIENT",
    "LEAN_DECIMAL_MAX_SCALE",
    "SemanticStreamDigest",
    "canonical_decimal_text",
    "canonical_utc_timestamp_text",
    "lean_decimal_representable",
    "parse_decimal_text",
    "sha256_hex",
    "utc_is_millisecond_exact",
]

DECIMAL_TEXT_PATTERN = re.compile(r"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$")

# The native LEAN Cfd/Forex quote reader (Common/Util/StreamReaderExtensions.cs,
# GetDecimal) accumulates the coefficient into a signed 64-bit integer and
# constructs the decimal with a zeroed high word and a byte scale. A price that
# does not fit that accumulator and scale cannot round-trip through the reader.
LEAN_DECIMAL_MAX_COEFFICIENT = (1 << 63) - 1
LEAN_DECIMAL_MAX_SCALE = 28

_DIGEST_LINE_FORMAT = "{0}|{1}|{2}|{3}\n"


class CanonicalValueError(ValueError):
    """A value cannot be represented under the canonical contract."""


def parse_decimal_text(text: str, field: str) -> Decimal:
    """Parses exact decimal source text without passing through binary float.

    Accepted: an optional sign and plain digits with an optional decimal point
    (``1``, ``1.25``, ``.5``, ``1.``). Rejected explicitly: blank text,
    ``nan``/``inf`` spellings, exponent notation, underscores, thousands
    separators and any other non-decimal spelling.
    """
    if text is None:
        raise CanonicalValueError(f"{field} is missing")
    stripped = text.strip()
    if not stripped:
        raise CanonicalValueError(f"{field} is blank")
    if not DECIMAL_TEXT_PATTERN.match(stripped):
        raise CanonicalValueError(f"{field} is not a plain decimal value: {text!r}")
    return Decimal(stripped)


def canonical_decimal_text(value: Decimal) -> str:
    """Renders a Decimal in the canonical fixed-point form shared with the probe."""
    if not isinstance(value, Decimal):
        raise CanonicalValueError("value must be a decimal.Decimal")
    if value.is_nan() or value.is_infinite():
        raise CanonicalValueError("a non-finite Decimal has no canonical text")
    if value == 0:
        return "0"
    sign, digits, exponent = value.as_tuple()
    digit_text = "".join(str(digit) for digit in digits).lstrip("0") or "0"
    while len(digit_text) > 1 and digit_text.endswith("0"):
        digit_text = digit_text[:-1]
        exponent += 1
    if exponent >= 0:
        text = digit_text + "0" * exponent
    else:
        scale = -exponent
        if len(digit_text) > scale:
            text = digit_text[:-scale] + "." + digit_text[-scale:]
        else:
            text = "0." + "0" * (scale - len(digit_text)) + digit_text
    return ("-" if sign else "") + text


def lean_decimal_representable(value: Decimal) -> bool:
    """True when the exact value round-trips through the native LEAN reader.

    The reader (`StreamReaderExtensions.GetDecimal`) accumulates into a signed
    64-bit integer with a zeroed high word and a byte scale, so the canonical
    coefficient must not exceed ``long.MaxValue`` and the scale must not exceed
    28. Trailing fractional zeros carry no value and are not counted against
    the scale (``1.000...`` with 30 zeros is the integer ``1``).
    """
    if value.is_nan() or value.is_infinite():
        return False
    if value == 0:
        return True
    _, digits, exponent = value.as_tuple()
    digit_list = list(digits)
    while digit_list and digit_list[-1] == 0:
        digit_list.pop()
        exponent += 1
    if not digit_list:
        return True
    coefficient = int("".join(str(digit) for digit in digit_list))
    scale = -exponent
    return (
        coefficient <= LEAN_DECIMAL_MAX_COEFFICIENT
        and 0 <= scale <= LEAN_DECIMAL_MAX_SCALE
    )


def utc_is_millisecond_exact(value: datetime) -> bool:
    """True when the UTC timestamp is exactly representable at millisecond precision."""
    if value.tzinfo is None:
        raise CanonicalValueError("timestamp must be timezone-aware")
    utc = value.astimezone(timezone.utc)
    return utc.microsecond % 1000 == 0


def canonical_utc_timestamp_text(value: datetime) -> str:
    """Renders a UTC timestamp as ``yyyy-MM-ddTHH:mm:ss.fffZ`` (exactly millisecond precision).

    Requires an exact millisecond value: the native LEAN tick format cannot
    represent sub-millisecond time, and this function never truncates silently.
    """
    if value.tzinfo is None:
        raise CanonicalValueError("timestamp must be timezone-aware")
    utc = value.astimezone(timezone.utc)
    if utc.microsecond % 1000 != 0:
        raise CanonicalValueError("timestamp has sub-millisecond precision: " f"{value!r}")
    return (
        f"{utc.year:04d}-{utc.month:02d}-{utc.day:02d}"
        f"T{utc.hour:02d}:{utc.minute:02d}:{utc.second:02d}"
        f".{utc.microsecond // 1000:03d}Z"
    )


def sha256_hex(payload: bytes) -> str:
    """Returns the lowercase hexadecimal SHA-256 of the payload."""
    return hashlib.sha256(payload).hexdigest()


class SemanticStreamDigest:
    """Incremental SHA-256 over the canonical semantic tuple stream.

    Rows are added in stream order; the digest is closed by :meth:`hexdigest`.
    Memory use is constant in the number of rows.
    """

    def __init__(self) -> None:
        self._hash = hashlib.sha256()
        self.count = 0
        self.first_timestamp: str | None = None
        self.last_timestamp: str | None = None

    def add(self, utc_timestamp: datetime, bid: Decimal, ask: Decimal) -> None:
        timestamp_text = canonical_utc_timestamp_text(utc_timestamp)
        line = _digest_line_from_text(
            self.count + 1, timestamp_text, canonical_decimal_text(bid), canonical_decimal_text(ask)
        )
        self._hash.update(line.encode("utf-8"))
        self.count += 1
        if self.first_timestamp is None:
            self.first_timestamp = timestamp_text
        self.last_timestamp = timestamp_text

    def hexdigest(self) -> str:
        return self._hash.hexdigest()

    def digest(self) -> str:
        return "sha256:" + self.hexdigest()


def _digest_line_from_text(ordinal: int, timestamp_text: str, bid_text: str, ask_text: str) -> str:
    if ordinal < 1:
        raise CanonicalValueError("ordinal must be at least 1")
    return _DIGEST_LINE_FORMAT.format(ordinal, timestamp_text, bid_text, ask_text)


def format_semantic_line(ordinal: int, utc_timestamp: datetime, bid: Decimal, ask: Decimal) -> str:
    """Returns one canonical semantic tuple line, newline-terminated."""
    return _digest_line_from_text(
        ordinal,
        canonical_utc_timestamp_text(utc_timestamp),
        canonical_decimal_text(bid),
        canonical_decimal_text(ask),
    )
