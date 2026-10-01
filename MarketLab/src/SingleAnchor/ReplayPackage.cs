using System;
using System.Collections.Generic;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Contract constants of the Phase E authoritative replay package: the deterministic,
    /// self-contained export the SingleAnchor host writes next to its strategy results so a later
    /// replay/visualization consumer (LuxAlgo, Phases F-H) can show exactly what happened without
    /// re-deriving any strategy or account value.
    /// </summary>
    /// <remarks>
    /// The package is additive output of the same authoritative run that persists
    /// <c>single-anchor/results.json</c>. Nothing here changes the strategy, the research account,
    /// the broker-liquidation model or the persisted results: the recorder only observes the
    /// engine's existing events and the account's existing observations.
    /// <list type="bullet">
    /// <item><c>events.jsonl</c> - one JSON object per line, in exact engine occurrence order,
    /// covering the plan's event stream (run identity, basket anchoring, boundaries, hard-BE
    /// state, entries, exits, closes, Margin Call, Stop Out, forced liquidations, rejections and
    /// the final outcome).</item>
    /// <item><c>telemetry-YYYY.jsonl</c> - bounded account telemetry chunks, one JSON object per
    /// line: an exact account snapshot for every event (<c>kind=event</c>) plus a periodic
    /// <c>kind=periodic</c> snapshot while positions are open, sampled every
    /// <see cref="TelemetryIntervalSeconds"/> of simulated time; sharded by UTC calendar year so a
    /// long history is loaded in bounded chunks.</item>
    /// <item><c>manifest.json</c> - the run identity (model revision, symbol, window, frozen
    /// parameter values, session-map identity), the sampling interval, per-file SHA-256/byte/line
    /// identities, event-type counts and the package fingerprint.</item>
    /// </list>
    /// Timestamps are UTC in <c>yyyy-MM-ddTHH:mm:ss.fffZ</c> form; every decimal is a
    /// JSON string in invariant-culture text exactly as the strategy computed it (never a JSON
    /// number, so a browser cannot re-read it as an IEEE double); the manifest's parameter block
    /// is stringified for the same reason; no wall-clock value, machine path or random value is
    /// written, so the same inputs produce the same bytes.
    /// <para>
    /// <c>packageSha256</c> is the SHA-256 of the concatenated payload rows
    /// <c>name\nsha256\nbytes\n</c> in the manifest's file order (events file first, then the
    /// telemetry shards by ascending year); the manifest itself is excluded because it cannot
    /// contain its own hash. Each <c>entry_rejection_summary</c> event is a run-end recap of a
    /// compressed rejection episode and deliberately has no <c>eventId</c>-correlated telemetry
    /// snapshot (its account state is historical, not current, when the package is built); the
    /// live <c>entry_rejected</c> event of the episode does carry one.
    /// </para>
    /// </remarks>
    public static class ReplayPackage
    {
        /// <summary>Package contract identifier written into the manifest.</summary>
        public const string Contract = "marketlab-single-anchor-replay-package-v1";

        /// <summary>Object-store directory of the package (under the run's storage root).</summary>
        public const string Directory = "single-anchor/replay";

        /// <summary>Event-stream file name.</summary>
        public const string EventsFile = "events.jsonl";

        /// <summary>Manifest file name.</summary>
        public const string ManifestFile = "manifest.json";

        /// <summary>
        /// Simulated-time interval of the bounded periodic account series while positions are
        /// open. Five simulated minutes bounds the full-history series (about 129k samples over
        /// 2019-01..2020-06) while the exact per-event snapshots carry every significant state.
        /// </summary>
        public const int TelemetryIntervalSeconds = 300;

        /// <summary>Telemetry chunk file name for one UTC calendar year.</summary>
        public static string TelemetryFile(int year)
        {
            return $"telemetry-{year.ToString("D4", CultureInfo.InvariantCulture)}.jsonl";
        }

        /// <summary>
        /// Canonical UTC timestamp text used throughout the package. A Local value is converted to
        /// UTC; an Unspecified value is treated as UTC, which is the convention of this host (the
        /// algorithm runs in UTC and every persisted strategy timestamp is a UTC wall time).
        /// </summary>
        public static string FormatUtc(DateTime value)
        {
            var utc = value.Kind switch
            {
                DateTimeKind.Local => value.ToUniversalTime(),
                DateTimeKind.Utc => value,
                _ => DateTime.SpecifyKind(value, DateTimeKind.Utc)
            };
            return utc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        }

        /// <summary>Canonical invariant decimal text exactly as computed.</summary>
        public static string FormatDecimal(decimal value)
        {
            return value.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>Lower-case hex SHA-256 of UTF-8 text.</summary>
        public static string Sha256Hex(string content)
        {
            var bytes = Encoding.UTF8.GetBytes(content);
            return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        }

        /// <summary>Number of lines in a JSON-lines payload (each line is '\n'-terminated).</summary>
        public static int CountLines(string content)
        {
            var lines = 0;
            for (var i = 0; i < content.Length; i++)
            {
                if (content[i] == '\n')
                {
                    lines++;
                }
            }
            return lines;
        }
    }

    /// <summary>
    /// Compact run identity copied from the authoritative run into the package manifest. Every
    /// value is available at the end of the run and is deterministic: no clock reading, path or
    /// process identity is added.
    /// </summary>
    public sealed record ReplayPackageMetadata(
        string ModelRevision,
        string StopOutModel,
        string Symbol,
        string Market,
        string SecurityType,
        string AlgorithmTimeZone,
        string QuoteTimeZone,
        string StartDate,
        string EndDate,
        DateTime StartUtc,
        DateTime EndUtc,
        SingleAnchorParameters Parameters,
        MarginParameters? MarginParameters,
        ReplaySessionMapIdentity? SessionMap,
        bool ResearchAccountEnabled,
        bool MarginEnabled);

    /// <summary>The session-map identity of the run, copied from the host's resolved session map.</summary>
    public sealed record ReplaySessionMapIdentity(
        string Map,
        string Sha256,
        string Symbol,
        string JunctionTimeZone,
        int Sessions,
        DateTime FirstSessionStartUtc,
        bool FinalSessionEndObservable,
        int SourceFileCount,
        long SourceRowCount,
        string SourceSha256Aggregate,
        DateTime SourceFirstQuoteUtc,
        DateTime SourceLastQuoteUtc);

    /// <summary>The compact delivered-stream identity copied from the run's delivery evidence.</summary>
    public sealed record ReplayDeliveryIdentity(
        long QuoteCount,
        string SemanticDigest,
        string? FirstCanonicalUtc,
        string? LastCanonicalUtc);

    /// <summary>
    /// The run-end facts the algorithm hands to the package builder: the engine's final counters,
    /// the failure (when the run stopped on one) and the authoritative rejection traces. The
    /// builder turns these into the <c>run_ended</c> event, the rejection summaries and the
    /// manifest counts; it reads no other state.
    /// </summary>
    public sealed record ReplayRunEnd(
        bool Completed,
        string? FailureKind,
        string? FailureCondition,
        string? FailureMessage,
        Quote? FailureQuote,
        DateTime? LastProcessedQuoteTime,
        long QuoteTicksProcessed,
        long QuoteOnlyQuotes,
        long StrategyEligibleQuotes,
        long LegsOpened,
        long BasketsClosed,
        long BasketsLiquidated,
        long ForcedLiquidations,
        long DistinctRejectedEntries,
        long RejectedEntryAttempts,
        long SkippedFirstEntryQuotes,
        decimal EngineRealizedProfit,
        ReplayDeliveryIdentity? Delivery,
        IReadOnlyList<EntryRejectionRecord> Rejections);

    /// <summary>One file of a built replay package, with its byte identity.</summary>
    public sealed record ReplayPackageFile(
        string Key,
        string Name,
        int? Year,
        string Content,
        string Sha256,
        int Bytes,
        int Lines);

    /// <summary>A complete built package: every file (manifest last) plus its counts and fingerprint.</summary>
    public sealed record ReplayPackageResult(
        IReadOnlyList<ReplayPackageFile> Files,
        string Manifest,
        string PackageSha256,
        int EventCount,
        int EventSnapshotCount,
        int PeriodicSampleCount)
    {
        /// <summary>Payload files (everything except the manifest), in deterministic order.</summary>
        public IReadOnlyList<ReplayPackageFile> PayloadFiles
        {
            get
            {
                var payload = new List<ReplayPackageFile>(Files.Count);
                foreach (var file in Files)
                {
                    if (file.Name != ReplayPackage.ManifestFile)
                    {
                        payload.Add(file);
                    }
                }
                return payload;
            }
        }
    }
}
