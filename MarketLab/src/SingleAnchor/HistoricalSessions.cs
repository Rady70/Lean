using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using Newtonsoft.Json;
using NodaTime;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// One source-derived historical session: the maximal run of observed quotes between two
    /// session junctions (<see cref="SessionJunctionRule"/>). <see cref="Start"/> is the exact
    /// timestamp of the first observed quote of the run and <see cref="End"/> the exact timestamp
    /// of the last one, in the clock the session set was loaded in (UTC for a session-map file,
    /// the subscription's quote clock once converted for a run). A null <see cref="End"/> means the
    /// natural end of the session is not observable inside the source (the dataset ends
    /// mid-session); it is never fabricated, and the source coverage end
    /// (<see cref="HistoricalSessionMapSource.LastQuoteUtc"/>) still bounds it.
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
    /// Provenance of the immutable source a session map was derived from. This is the semantic
    /// source identity: file count, row count, the aggregate SHA-256 over the per-file hashes and
    /// the first and last observed quote. The machine location of the source is deliberately not
    /// part of it, so moving identical data does not change the map.
    /// </summary>
    public sealed record HistoricalSessionMapSource(
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
    /// The recorded <see cref="JunctionTimeZone"/> is the clock the junction rule was evaluated in
    /// (America/New_York); the replay may deliver quotes in any clock, and the UTC boundaries are
    /// converted to that clock at load.
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
        private static readonly Regex AggregateHash = new Regex("^[0-9a-f]{64}$", RegexOptions.Compiled);

        /// <summary>Creates a map from validated sessions (UTC instants, sorted, non-overlapping).</summary>
        public HistoricalSessionMap(
            string symbol,
            string junctionTimeZone,
            IReadOnlyList<HistoricalSession> sessions,
            HistoricalSessionMapSource? source = null)
        {
            if (string.IsNullOrWhiteSpace(symbol))
            {
                throw new ArgumentException("a session map needs a symbol", nameof(symbol));
            }
            if (string.IsNullOrWhiteSpace(junctionTimeZone))
            {
                throw new ArgumentException("a session map needs the junction-rule time zone", nameof(junctionTimeZone));
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
                    // The sessions claim to come from the declared junction rule: a map that splits
                    // a run at an arbitrary intraday gap would invent closing/opening buffers and
                    // is not a session map under this contract.
                    if (!SessionJunctionRule.IsJunction(previous.End.Value, session.Start))
                    {
                        throw new ArgumentException(
                            $"sessions {i - 1} and {i} are not separated by the settlement-window junction; " +
                            "the map does not follow the declared junction rule", nameof(sessions));
                    }
                }
            }

            if (source != null)
            {
                ValidateSource(source, sessions);
            }

            Symbol = symbol;
            JunctionTimeZone = junctionTimeZone;
            Sessions = sessions.ToArray();
            Source = source;
        }

        /// <summary>The instrument the sessions were derived for.</summary>
        public string Symbol { get; }

        /// <summary>The clock the junction rule was evaluated in (the rule is New York based).</summary>
        public string JunctionTimeZone { get; }

        /// <summary>The source provenance recorded at derivation, when available.</summary>
        public HistoricalSessionMapSource? Source { get; }

        /// <summary>The ordered sessions (UTC). The final session may have no observable end.</summary>
        public IReadOnlyList<HistoricalSession> Sessions { get; }

        /// <summary>
        /// Derives the map from source segments in order. Segments must be ordered and
        /// non-overlapping (the generator guarantees it); adjacent segments are merged into one
        /// session unless <see cref="SessionJunctionRule.IsJunction"/> separates them. The final
        /// session of the dataset is always given no end: the source cannot prove that the last
        /// observed quote was a natural close, so no <c>T1</c> is fabricated for it. The source
        /// coverage end still bounds it at runtime.
        /// </summary>
        public static HistoricalSessionMap Derive(
            IEnumerable<HistoricalSegment> segments,
            string symbol = "XAUUSD",
            string junctionTimeZone = SessionJunctionRule.TimeZoneId,
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
                if (hasSegment && segment.First < currentLast)
                {
                    throw new ArgumentException(
                        "segments must be ordered and non-overlapping; a segment starts before the previous one ends",
                        nameof(segments));
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
            return new HistoricalSessionMap(symbol, junctionTimeZone, sessions, source);
        }

        /// <summary>
        /// Converts the UTC session boundaries into the given quote clock and returns the runtime
        /// classifier over the converted sessions. The conversion is unavoidable: LEAN hands the
        /// strategy quotes in its subscription clock, and a session boundary must be compared in
        /// the same clock as the quotes it bounds. The clock is whatever LEAN delivers (it is not
        /// tied to the junction-rule zone, which is New York for this rule).
        /// </summary>
        public HistoricalTradingAvailability ToAvailability(DateTimeZone quoteClock)
        {
            if (quoteClock == null)
            {
                throw new ArgumentNullException(nameof(quoteClock));
            }

            var local = new HistoricalSession[Sessions.Count];
            for (var i = 0; i < Sessions.Count; i++)
            {
                var session = Sessions[i]!;
                var start = ToClock(session.Start, quoteClock);
                var end = session.End.HasValue ? ToClock(session.End.Value, quoteClock) : (DateTime?)null;
                local[i] = new HistoricalSession(start, end);
            }
            var coverageEnd = Source == null ? (DateTime?)null : ToClock(Source.LastQuoteUtc, quoteClock);
            return new HistoricalTradingAvailability(local, coverageEnd);
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
                JunctionTimeZone = JunctionTimeZone,
                JunctionRule = JunctionRuleText,
                Source = Source == null ? null : new SourceDto
                {
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

        /// <summary>
        /// Loads and validates a production map file: the contract, the v1 junction rule, the
        /// junction time zone, ordered sessions that are actually separated by the junction rule,
        /// and the complete source provenance are all required, so a structurally malformed or
        /// self-contradictory map is refused. The loader validates structure, not derivation: a
        /// coherent hand edit cannot be cryptographically ruled out, which is why the map's
        /// SHA-256 and the source lineage are recorded with every run's results.
        /// </summary>
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
            if (!string.Equals(dto.JunctionRule, JunctionRuleText, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    $"session map junction rule is not the v1 rule: '{dto.JunctionRule}' ({path})");
            }
            if (string.IsNullOrWhiteSpace(dto.Symbol)
                || !string.Equals(dto.JunctionTimeZone, SessionJunctionRule.TimeZoneId, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    $"session map is missing its symbol or names a junction time zone other than '{SessionJunctionRule.TimeZoneId}': {path}");
            }
            if (dto.Sessions == null || dto.Sessions.Count == 0)
            {
                throw new InvalidDataException($"session map carries no sessions: {path}");
            }
            if (dto.Source == null)
            {
                throw new InvalidDataException(
                    $"session map carries no source provenance; a map without it cannot bound the dataset-end session or be reproduced: {path}");
            }

            var sessions = new List<HistoricalSession>(dto.Sessions.Count);
            foreach (var session in dto.Sessions)
            {
                var start = ParseUtc(session?.StartUtc, "startUtc", path);
                var end = session?.EndUtc == null ? (DateTime?)null : ParseUtc(session.EndUtc, "endUtc", path);
                sessions.Add(new HistoricalSession(start, end));
            }

            if (dto.Source.FileCount <= 0)
            {
                throw new InvalidDataException($"session map source file count must be positive: {path}");
            }
            if (dto.Source.RowCount <= 0)
            {
                throw new InvalidDataException($"session map source row count must be positive: {path}");
            }
            if (dto.Source.Sha256Aggregate == null || !AggregateHash.IsMatch(dto.Source.Sha256Aggregate))
            {
                throw new InvalidDataException(
                    $"session map source aggregate SHA-256 is not 64 lower-case hex characters: {path}");
            }
            var source = new HistoricalSessionMapSource(
                dto.Source.FileCount,
                dto.Source.RowCount,
                dto.Source.Sha256Aggregate,
                ParseUtc(dto.Source.FirstQuoteUtc, "source.firstQuoteUtc", path),
                ParseUtc(dto.Source.LastQuoteUtc, "source.lastQuoteUtc", path));

            try
            {
                return new HistoricalSessionMap(dto.Symbol!, dto.JunctionTimeZone!, sessions, source);
            }
            catch (ArgumentException error)
            {
                throw new InvalidDataException($"session map is invalid: {path}: {error.Message}", error);
            }
        }

        private static void ValidateSource(HistoricalSessionMapSource source, IReadOnlyList<HistoricalSession> sessions)
        {
            if (source.FileCount <= 0)
            {
                throw new ArgumentException("source file count must be positive", nameof(source));
            }
            if (source.RowCount <= 0)
            {
                throw new ArgumentException("source row count must be positive", nameof(source));
            }
            if (source.Sha256Aggregate == null || !AggregateHash.IsMatch(source.Sha256Aggregate))
            {
                throw new ArgumentException("source aggregate SHA-256 must be 64 lower-case hex characters", nameof(source));
            }
            if (source.FirstQuoteUtc.Kind != DateTimeKind.Utc || source.LastQuoteUtc.Kind != DateTimeKind.Utc)
            {
                throw new ArgumentException("source quote timestamps must be UTC instants", nameof(source));
            }
            if (source.LastQuoteUtc < source.FirstQuoteUtc)
            {
                throw new ArgumentException("source last quote precedes the first", nameof(source));
            }
            if (sessions[0]!.Start != source.FirstQuoteUtc)
            {
                throw new ArgumentException(
                    "the first session must start at the source's first observed quote", nameof(source));
            }
            var last = sessions[sessions.Count - 1]!;
            if (last.End.HasValue)
            {
                if (source.LastQuoteUtc != last.End.Value)
                {
                    throw new ArgumentException(
                        "when the final session has an observed end, the source coverage end must equal it; " +
                        "a later source quote belongs to no session", nameof(source));
                }
            }
            else if (source.LastQuoteUtc < last.Start)
            {
                throw new ArgumentException(
                    "the source coverage end must not precede the final session's last observed quote", nameof(source));
            }
        }

        private static DateTime ToClock(DateTime utc, DateTimeZone quoteClock)
        {
            return Instant.FromDateTimeUtc(utc).InZone(quoteClock).LocalDateTime.ToDateTimeUnspecified();
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
            [JsonProperty("junctionTimeZone")] public string? JunctionTimeZone { get; set; }
            [JsonProperty("junctionRule")] public string? JunctionRule { get; set; }
            [JsonProperty("source")] public SourceDto? Source { get; set; }
            [JsonProperty("sessions")] public List<SessionDto?>? Sessions { get; set; }
        }

        private sealed class SourceDto
        {
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
