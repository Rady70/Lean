"""Resolved LEAN market-hours semantics for the runtime data folder.

The runtime market-hours database is the actual file the LEAN engine loads:
``<data-folder>/market-hours/market-hours-database.json`` (LEAN resolves it
through ``MarketHoursDatabase.FromDataFolder()``; there is no configuration key
for a different file). This module loads that file, records its SHA-256, and
resolves the XAUUSD/Oanda CFD entry exactly as LEAN does (exact key first, then
the ``[*]`` wildcard).

The session evaluator is a diagnostic view used to explain delivery
differences in the qualification report. It is *not* the authority: the actual
LEAN replay decides what is delivered. ``preview_exact`` is false when the entry
defines early closes or late opens, whose segment adjustment this diagnostic
simplifies.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

__all__ = [
    "MarketHoursDatabaseError",
    "MarketHoursSegment",
    "ResolvedMarketHours",
    "SessionEvaluator",
    "load_market_hours",
    "parse_market_hours_timespan",
]

_WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
_TIMESPAN_PATTERN = re.compile(r"^(?:(\d+)\.)?(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?$")
_SECURITY_TYPE_KEYS = {"cfd": "Cfd", "forex": "Forex"}


class MarketHoursDatabaseError(Exception):
    """The runtime market-hours database or the requested entry is unusable."""


@dataclass(frozen=True)
class MarketHoursSegment:
    """One exchange session segment in exchange-local seconds since midnight."""

    start_seconds: int
    end_seconds: int
    state: str


@dataclass(frozen=True)
class ResolvedMarketHours:
    """The resolved runtime market-hours identity and schedule."""

    database_path: str
    database_sha256: str
    entry_key: str
    entry_source: str
    data_time_zone: str
    exchange_time_zone: str
    weekly_segments: dict
    holidays: frozenset
    early_closes: dict
    late_opens: dict
    preview_exact: bool

    def describe(self) -> dict:
        return {
            "database_path": self.database_path,
            "database_sha256": self.database_sha256,
            "entry_key": self.entry_key,
            "entry_source": self.entry_source,
            "data_time_zone": self.data_time_zone,
            "exchange_time_zone": self.exchange_time_zone,
            "holidays": sorted(day.isoformat() for day in self.holidays),
            "early_closes": {
                day.isoformat(): seconds for day, seconds in sorted(self.early_closes.items())
            },
            "late_opens": {
                day.isoformat(): seconds for day, seconds in sorted(self.late_opens.items())
            },
            "preview_exact": self.preview_exact,
            "weekly_segments": {
                _WEEKDAYS[index]: [
                    {"start_seconds": segment.start_seconds, "end_seconds": segment.end_seconds, "state": segment.state}
                    for segment in self.weekly_segments.get(index, ())
                ]
                for index in range(7)
            },
        }


def parse_market_hours_timespan(text: str, field: str) -> int:
    """Parses a LEAN market-hours timespan (``18:03:00`` or ``1.00:00:00``) to seconds."""
    match = _TIMESPAN_PATTERN.match(text.strip())
    if match is None:
        raise MarketHoursDatabaseError(f"market-hours {field} is not a LEAN timespan: {text!r}")
    days = int(match.group(1) or 0)
    hours = int(match.group(2))
    minutes = int(match.group(3))
    seconds = int(match.group(4))
    fraction = match.group(5) or ""
    ticks_100ns = int(fraction.ljust(7, "0")) if fraction else 0
    if hours > 24 or minutes > 59 or seconds > 59:
        raise MarketHoursDatabaseError(f"market-hours {field} is out of range: {text!r}")
    return days * 86400 + hours * 3600 + minutes * 60 + seconds + ticks_100ns // 10_000_000


def _parse_market_hours_date(text: str, field: str) -> date:
    for pattern in ("%m/%d/%Y", "%Y-%m-%d", "%m/%d/%y"):
        try:
            return datetime.strptime(text.strip(), pattern).date()
        except ValueError:
            continue
    raise MarketHoursDatabaseError(f"market-hours {field} is not a parseable date: {text!r}")


def load_market_hours(
    data_folder: Path, security_type: str, market: str, symbol: str
) -> tuple[ResolvedMarketHours, dict]:
    """Loads and resolves the runtime market-hours entry for one subscription."""
    database_path = Path(data_folder) / "market-hours" / "market-hours-database.json"
    if not database_path.is_file():
        raise MarketHoursDatabaseError(
            f"runtime market-hours database not found: {database_path} (the data folder the "
            "LEAN run uses must contain market-hours/market-hours-database.json)"
        )
    payload = database_path.read_bytes()
    database_sha256 = hashlib.sha256(payload).hexdigest()
    try:
        parsed = json.loads(payload.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MarketHoursDatabaseError(
            f"runtime market-hours database is not readable JSON: {database_path}: {error}"
        ) from error
    entries = parsed.get("entries") if isinstance(parsed, dict) else None
    if not isinstance(entries, dict):
        raise MarketHoursDatabaseError(
            f"runtime market-hours database has no 'entries' object: {database_path}"
        )

    type_key = _SECURITY_TYPE_KEYS.get(security_type.strip().lower(), security_type)
    market_key = market.strip().lower()
    exact_key = f"{type_key}-{market_key}-{symbol}"
    wildcard_key = f"{type_key}-{market_key}-[*]"
    keys_by_lowercase = {str(key).lower(): key for key in entries}
    exact_match = keys_by_lowercase.get(exact_key.lower())
    wildcard_match = keys_by_lowercase.get(wildcard_key.lower())
    entry = None
    entry_source = "exact"
    resolved_key = exact_key
    if exact_match is not None:
        entry = entries[exact_match]
        resolved_key = exact_match
    elif wildcard_match is not None:
        entry = entries[wildcard_match]
        entry_source = "wildcard"
        resolved_key = wildcard_match
    if entry is None:
        raise MarketHoursDatabaseError(
            f"no market-hours entry for {exact_key!r} or {wildcard_key!r} in {database_path}"
        )

    try:
        data_time_zone = entry["dataTimeZone"]
        exchange_time_zone = entry["exchangeTimeZone"]
    except KeyError as error:
        raise MarketHoursDatabaseError(
            f"market-hours entry {resolved_key} is "
            f"missing {error.args[0]!r}"
        ) from error

    weekly_segments: dict[int, tuple[MarketHoursSegment, ...]] = {}
    for index, weekday in enumerate(_WEEKDAYS):
        segments = []
        for segment in entry.get(weekday, []) or []:
            if not isinstance(segment, dict):
                raise MarketHoursDatabaseError(
                    f"market-hours entry {resolved_key} has a malformed {weekday} segment"
                )
            segments.append(
                MarketHoursSegment(
                    start_seconds=parse_market_hours_timespan(segment["start"], f"{weekday}.start"),
                    end_seconds=parse_market_hours_timespan(segment["end"], f"{weekday}.end"),
                    state=str(segment.get("state", "market")),
                )
            )
        weekly_segments[index] = tuple(segments)

    holidays = frozenset(
        _parse_market_hours_date(value, "holiday") for value in entry.get("holidays", []) or []
    )
    early_closes = {
        _parse_market_hours_date(key, "earlyCloses"): parse_market_hours_timespan(value, "earlyCloses")
        for key, value in (entry.get("earlyCloses") or {}).items()
    }
    late_opens = {
        _parse_market_hours_date(key, "lateOpens"): parse_market_hours_timespan(value, "lateOpens")
        for key, value in (entry.get("lateOpens") or {}).items()
    }

    resolved = ResolvedMarketHours(
        database_path=str(database_path),
        database_sha256=database_sha256,
        entry_key=resolved_key,
        entry_source=entry_source,
        data_time_zone=data_time_zone,
        exchange_time_zone=exchange_time_zone,
        weekly_segments=weekly_segments,
        holidays=holidays,
        early_closes=early_closes,
        late_opens=late_opens,
        preview_exact=not early_closes and not late_opens,
    )
    return resolved, entry


def _adjust_segments(
    segments: tuple[MarketHoursSegment, ...], day: date, hours: ResolvedMarketHours
) -> tuple[MarketHoursSegment, ...]:
    adjusted = list(segments)
    late_open = hours.late_opens.get(day)
    if late_open is not None:
        adjusted = [
            MarketHoursSegment(max(segment.start_seconds, late_open), segment.end_seconds, segment.state)
            for segment in adjusted
            if segment.end_seconds > late_open
        ]
    early_close = hours.early_closes.get(day)
    if early_close is not None:
        adjusted = [
            MarketHoursSegment(segment.start_seconds, min(segment.end_seconds, early_close), segment.state)
            for segment in adjusted
            if segment.start_seconds < early_close
        ]
    return tuple(segment for segment in adjusted if segment.start_seconds < segment.end_seconds)


class SessionEvaluator:
    """Diagnostic evaluation of the resolved exchange sessions for one entry."""

    def __init__(self, hours: ResolvedMarketHours) -> None:
        self._hours = hours
        try:
            self._exchange_zone = ZoneInfo(hours.exchange_time_zone)
        except Exception as error:  # noqa: BLE001 - re-raised with context
            raise MarketHoursDatabaseError(
                f"market-hours exchange timezone is unknown: {hours.exchange_time_zone!r}"
            ) from error

    @property
    def preview_exact(self) -> bool:
        return self._hours.preview_exact

    def _local(self, utc_timestamp: datetime) -> datetime:
        return utc_timestamp.astimezone(self._exchange_zone)

    def sessions_for(self, local_date: date) -> tuple[MarketHoursSegment, ...]:
        if local_date in self._hours.holidays:
            return ()
        return _adjust_segments(
            self._hours.weekly_segments.get(local_date.weekday(), ()), local_date, self._hours
        )

    def is_market_day(self, local_date: date) -> bool:
        if local_date in self._hours.holidays:
            return False
        if any(segment.state != "closed" for segment in self.sessions_for(local_date)):
            return True
        previous = local_date - timedelta(days=1)
        return any(
            segment.end_seconds > 86400 for segment in self.sessions_for(previous)
        )

    def is_open(self, utc_timestamp: datetime) -> bool:
        local = self._local(utc_timestamp)
        seconds = local.hour * 3600 + local.minute * 60 + local.second
        for segment in self.sessions_for(local.date()):
            if segment.state == "closed":
                continue
            if segment.start_seconds <= seconds < segment.end_seconds:
                return True
        previous = local.date() - timedelta(days=1)
        wrapped = seconds + 86400
        for segment in self.sessions_for(previous):
            if segment.state == "closed":
                continue
            if segment.end_seconds > 86400 and wrapped < segment.end_seconds:
                return True
        return False
