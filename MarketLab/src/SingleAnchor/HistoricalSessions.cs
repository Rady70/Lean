using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json;
using NodaTime;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// One source-derived historical session: the maximal run of observed quotes between two
    /// session junctions (<see cref="SessionJunctionRule"/>). <see cref="Start"/> is the exact
    /// timestamp of the first observed quote of the run and <see cref="End"/> the exact timestamp
    /// of the last one, in the clock the session set was loaded in (UTC for a session-map file,
    /// the subscription's exchange time zone once converted for a run). A null <see cref="End"/>
    /// means the natural end of the session is not observable in the source (the dataset ends
    /// mid-session); it is never fabricated.
    /// </summary>
    public sealed record HistoricalSession(DateTime Start, DateTime? End);

    /// <summary>
    /// One contiguous run of consecutive observed quotes as produced by a source scan. Adjacent
    /// segments either belong to the same session or are separated by a junction; only the
    /// boundary quotes are needed to decide which.
    /// </summary>
    public readonly record struct HistoricalSegment(DateTime First, DateTime Last);

    /// <summary>
    /// The agreed source-derived session junction rule: a gap between consecutive quote runs is a
    /// session junction when it fully contains the New York local settlement interval
    /// <c>17:00:00 &lt;= t &lt; 18:00:00</c> (<c>America/New_York</c>). The last-tick side is
    /// strict and the next-tick side inclusive: a run ending exactly at 17:00:00 does not itself
    /// start the settlement interval, and a run resuming exactly at 18:00:00 completes it. The
    /// rule follows every daylight-saving transition through the named zone; it is never a fixed
    /// UTC time and never a fixed gap duration.
    /// </summary>
    public static class SessionJunctionRule
    {
        /// <summary>The IANA zone the settlement interval is expressed in.</summary>
        public const string TimeZoneId = "America/New_York";

        /// <summary>The start of the New York local settlement interval (17:00:00).</summary>
        public static readonly LocalTime SettlementStart = new LocalTime(17, 0);

        /// <summary>The end of the New York local settlement interval (18:00:00, exclusive).</summary>
        public static readonly LocalTime SettlementEnd = new LocalTime(18, 0);

        private static readonly DateTimeZone Zone = DateTimeZoneProviders.Tzdb[TimeZoneId];

        /// <summary>
        /// True when the gap between two consecutive quote runs fully contains the New York local
        /// settlement interval of some local date, i.e. when the runs belong to different sessions.
        /// Both timestamps are UTC instants (the <see cref="DateTime.Kind"/> is not inspected).
        /// </summary>
        public static bool IsJunction(DateTime previousQuoteUtc, DateTime nextQuoteUtc)
        {
            if (nextQuoteUtc <= previousQuoteUtc)
            {
                return false;
            }

            var previousLocal = Utc(previousQuoteUtc).InZone(Zone).LocalDateTime;
            var day = previousLocal.TimeOfDay < SettlementStart
                ? previousLocal.Date
                : previousLocal.Date.PlusDays(1);
            // Both endpoints are mapped through the named zone, so the interval follows every
            // daylight-saving transition instead of any fixed UTC offset.
            var settlementStart = Zone.AtStrictly(day + SettlementStart);
            var settlementEnd = Zone.AtStrictly(day + SettlementEnd);
            return Utc(nextQuoteUtc) >= settlementEnd.ToInstant();
        }

        private static Instant Utc(DateTime value)
        {
            return Instant.FromDateTimeUtc(DateTime.SpecifyKind(value, DateTimeKind.Utc));
        }
    }

    /// <summary>
    /// Provenance of the immutable source a session map was derived from. Recorded for the
    /// research record; the replay itself only consumes <see cref="HistoricalSessionMap.Sessions"/>.
    /// </summary>
    public sealed record HistoricalSessionMapSource(
        string Directory,
        int FileCount,
        long RowCount,
        string Sha256Aggregate,
        DateTime FirstQuoteUtc,
        DateTime LastQuoteUtc);

    /// <summary>
    /// The source-derived session map: the ordered sessions of one instrument's quote history,
    /// each bounded by the first and last observed quote of the run between junctions. The file
    /// contract is <c>marketlab-single-anchor-session-map-v1</c>; timestamps are UTC instants with
    /// exactly millisecond precision. The map carries no buffer policy: the five-minute
    /// quote-only windows are the strategy-side rule in <see cref="HistoricalTradingAvailability"/>.
    /// </summary>
    public sealed class HistoricalSessionMap
    {
        /// <summary>The session-map file contract identifier.</summary>
        public const string Contract = "marketlab-single-anchor-session-map-v1";

        /// <summary>Human-readable statement of the rule the sessions were derived with.</summary>
        public const string JunctionRuleText =
            "A gap between consecutive quote runs is a session junction when it fully contains the " +
            "New York local settlement interval 17:00:00 <= t < 18:00:00 (America/New_York).";

        private const string TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'";

        /// <summary>Creates a map from validated sessions (UTC instants, sorted, non-overlapping).</summary>
        public HistoricalSessionMap(
            string symbol,
            string exchangeTimeZone,
            IReadOnlyList<HistoricalSession> sessions,
            HistoricalSessionMapSource? source = null)
        {
            if (string.IsNullOrWhiteSpace(symbol))
            {
                throw new ArgumentException("a session map needs a symbol", nameof(symbol));
            }
            if (string.IsNullOrWhiteSpace(exchangeTimeZone))
            {
                throw new ArgumentException("a session map needs an exchange time zone", nameof(exchangeTimeZone));
            }
            if (sessions == null || sessions.Count == 0)
            {
                throw new ArgumentException("a session map needs at least one session", nameof(sessions));
            }

            for (var i = 0; i < sessions.Count; i++)
            {
                var session = sessions[i] ?? throw new ArgumentException("a session map cannot contain a null session", nameof(sessions));
                if (session.Start.Kind != DateTimeKind.Utc)
                {
                    throw new ArgumentException("session map timestamps must be UTC instants", nameof(sessions));
                }
                if (session.End.HasValue)
                {
                    if (session.End.Value.Kind != DateTimeKind.Utc)
                    {
                        throw new ArgumentException("session map timestamps must be UTC instants", nameof(sessions));
                    }
                    if (session.End.Value <= session.Start)
                    {
                        throw new ArgumentException($"session {i} ends at or before it starts", nameof(sessions));
                    }
                }
                else if (i != sessions.Count - 1)
                {
                    throw new ArgumentException(
                        "only the final session may have no observable end (a later session exists)", nameof(sessions));
                }
                if (i > 0)
                {
                    var previous = sessions[i - 1]!;
                    if (!previous.End.HasValue)
                    {
                        throw new ArgumentException("only the final session may have no observable end", nameof(sessions));
                    }
                    if (session.Start <= previous.End.Value)
                    {
                        throw new ArgumentException($"session {i} overlaps or precedes session {i - 1}", nameof(sessions));
                    }
                }
            }

            Symbol = symbol;
            ExchangeTimeZone = exchangeTimeZone;
            Sessions = sessions.ToArray();
            Source = source;
        }

        /// <summary>The instrument the sessions were derived for.</summary>
        public string Symbol { get; }

        /// <summary>The exchange time zone the session boundaries are meaningful in.</summary>
        public string ExchangeTimeZone { get; }

        /// <summary>The source provenance recorded at derivation, when available.</summary>
        public HistoricalSessionMapSource? Source { get; }

        /// <summary>The ordered sessions (UTC). The final session may have no observable end.</summary>
        public IReadOnlyList<HistoricalSession> Sessions { get; }

        /// <summary>
        /// Derives the map from source segments in order. Adjacent segments are merged into one
        /// session unless <see cref="SessionJunctionRule.IsJunction"/> separates them. The final
        /// session of the dataset is always given no end: the source cannot prove that the last
        /// observed quote was a natural close, so no <c>T1</c> is fabricated for it.
        /// </summary>
        public static HistoricalSessionMap Derive(
            IEnumerable<HistoricalSegment> segments,
            string symbol = "XAUUSD",
            string exchangeTimeZone = SessionJunctionRule.TimeZoneId,
            HistoricalSessionMapSource? source = null)
        {
            if (segments == null)
            {
                throw new ArgumentNullException(nameof(segments));
            }

            var sessions = new List<HistoricalSession>();
            var hasSegment = false;
            var currentFirst = default(DateTime);
            var currentLast = default(DateTime);
            DateTime? sessionStart = null;
            foreach (var segment in segments)
            {
                if (segment.Last < segment.First)
                {
                    throw new ArgumentException("a segment ends before it starts", nameof(segments));
                }
                if (!hasSegment)
                {
                    currentFirst = segment.First;
                    currentLast = segment.Last;
                    hasSegment = true;
                    continue;
                }
                if (SessionJunctionRule.IsJunction(currentLast, segment.First))
                {
                    sessions.Add(new HistoricalSession(sessionStart ?? currentFirst, currentLast));
                    sessionStart = segment.First;
                }
                currentLast = segment.Last;
            }
            if (!hasSegment)
            {
                throw new ArgumentException("a session map needs at least one segment", nameof(segments));
            }
            sessions.Add(new HistoricalSession(sessionStart ?? currentFirst, null));
            return new HistoricalSessionMap(symbol, exchangeTimeZone, sessions, source);
        }

        /// <summary>
        /// Converts the UTC session boundaries into the given exchange time zone and returns the
        /// runtime classifier over the converted sessions. The conversion is unavoidable: LEAN
        /// hands the strategy exchange-local quote times, and a session boundary must be compared
        /// in the same clock as the quotes it bounds.
        /// </summary>
        public HistoricalTradingAvailability ToAvailability(DateTimeZone exchangeZone)
        {
            if (exchangeZone == null)
            {
                throw new ArgumentNullException(nameof(exchangeZone));
            }

            var local = new HistoricalSession[Sessions.Count];
            for (var i = 0; i < Sessions.Count; i++)
            {
                var session = Sessions[i]!;
                var start = ToLocal(session.Start, exchangeZone);
                var end = session.End.HasValue ? ToLocal(session.End.Value, exchangeZone) : (DateTime?)null;
                local[i] = new HistoricalSession(start, end);
            }
            return new HistoricalTradingAvailability(local);
        }

        /// <summary>Writes the map as the contract JSON document.</summary>
        public void Save(string path)
        {
            if (path == null)
            {
                throw new ArgumentNullException(nameof(path));
            }

            var dto = new MapDto
            {
                Contract = Contract,
                Symbol = Symbol,
                ExchangeTimeZone = ExchangeTimeZone,
                JunctionRule = JunctionRuleText,
                Source = Source == null ? null : new SourceDto
                {
                    Directory = Source.Directory,
                    FileCount = Source.FileCount,
                    RowCount = Source.RowCount,
                    Sha256Aggregate = Source.Sha256Aggregate,
                    FirstQuoteUtc = FormatUtc(Source.FirstQuoteUtc),
                    LastQuoteUtc = FormatUtc(Source.LastQuoteUtc)
                },
                Sessions = Sessions.Select(session => (SessionDto?)new SessionDto
                {
                    StartUtc = FormatUtc(session.Start),
                    EndUtc = session.End.HasValue ? FormatUtc(session.End.Value) : null
                }).ToList()
            };
            File.WriteAllText(path, JsonConvert.SerializeObject(dto, Formatting.Indented), new UTF8Encoding(false));
        }

        /// <summary>Loads and validates a map file. Malformed or non-canonical input is refused.</summary>
        public static HistoricalSessionMap Load(string path)
        {
            if (path == null)
            {
                throw new ArgumentNullException(nameof(path));
            }

            string text;
            try
            {
                text = File.ReadAllText(path, Encoding.UTF8);
            }
            catch (IOException error)
            {
                throw new InvalidDataException($"session map could not be read: {path}: {error.Message}", error);
            }

            MapDto dto;
            try
            {
                dto = JsonConvert.DeserializeObject<MapDto>(text)
                    ?? throw new InvalidDataException($"session map is empty: {path}");
            }
            catch (JsonException error)
            {
                throw new InvalidDataException($"session map is not valid JSON: {path}: {error.Message}", error);
            }

            if (!string.Equals(dto.Contract, Contract, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    $"session map contract is '{dto.Contract}', expected '{Contract}': {path}");
            }
            if (string.IsNullOrWhiteSpace(dto.Symbol) || string.IsNullOrWhiteSpace(dto.ExchangeTimeZone))
            {
                throw new InvalidDataException($"session map is missing its symbol or exchange time zone: {path}");
            }
            if (dto.Sessions == null || dto.Sessions.Count == 0)
            {
                throw new InvalidDataException($"session map carries no sessions: {path}");
            }

            var sessions = new List<HistoricalSession>(dto.Sessions.Count);
            foreach (var session in dto.Sessions)
            {
                var start = ParseUtc(session?.StartUtc, "startUtc", path);
                var end = session?.EndUtc == null ? (DateTime?)null : ParseUtc(session.EndUtc, "endUtc", path);
                sessions.Add(new HistoricalSession(start, end));
            }

            HistoricalSessionMapSource? source = null;
            if (dto.Source != null)
            {
                source = new HistoricalSessionMapSource(
                    dto.Source.Directory ?? string.Empty,
                    dto.Source.FileCount,
                    dto.Source.RowCount,
                    dto.Source.Sha256Aggregate ?? string.Empty,
                    ParseUtc(dto.Source.FirstQuoteUtc, "source.firstQuoteUtc", path),
                    ParseUtc(dto.Source.LastQuoteUtc, "source.lastQuoteUtc", path));
            }

            try
            {
                return new HistoricalSessionMap(dto.Symbol, dto.ExchangeTimeZone, sessions, source);
            }
            catch (ArgumentException error)
            {
                throw new InvalidDataException($"session map is invalid: {path}: {error.Message}", error);
            }
        }

        private static DateTime ToLocal(DateTime utc, DateTimeZone zone)
        {
            return Instant.FromDateTimeUtc(utc).InZone(zone).LocalDateTime.ToDateTimeUnspecified();
        }

        private static string FormatUtc(DateTime value)
        {
            return value.ToString(TimestampFormat, CultureInfo.InvariantCulture);
        }

        private static DateTime ParseUtc(string? text, string field, string path)
        {
            if (text == null
                || !DateTime.TryParseExact(
                    text,
                    TimestampFormat,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out var value)
                || value.Kind != DateTimeKind.Utc)
            {
                throw new InvalidDataException(
                    $"session map {field} is not a canonical UTC millisecond timestamp: '{text}' ({path})");
            }
            return value;
        }

        private sealed class MapDto
        {
            [JsonProperty("contract")] public string? Contract { get; set; }
            [JsonProperty("symbol")] public string? Symbol { get; set; }
            [JsonProperty("exchangeTimeZone")] public string? ExchangeTimeZone { get; set; }
            [JsonProperty("junctionRule")] public string? JunctionRule { get; set; }
            [JsonProperty("source")] public SourceDto? Source { get; set; }
            [JsonProperty("sessions")] public List<SessionDto?>? Sessions { get; set; }
        }

        private sealed class SourceDto
        {
            [JsonProperty("directory")] public string? Directory { get; set; }
            [JsonProperty("fileCount")] public int FileCount { get; set; }
            [JsonProperty("rowCount")] public long RowCount { get; set; }
            [JsonProperty("sha256Aggregate")] public string? Sha256Aggregate { get; set; }
            [JsonProperty("firstQuoteUtc")] public string? FirstQuoteUtc { get; set; }
            [JsonProperty("lastQuoteUtc")] public string? LastQuoteUtc { get; set; }
        }

        private sealed class SessionDto
        {
            [JsonProperty("startUtc")] public string? StartUtc { get; set; }
            [JsonProperty("endUtc")] public string? EndUtc { get; set; }
        }
    }
}
