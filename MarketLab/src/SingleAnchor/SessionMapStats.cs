using System;
using System.Collections.Generic;
using Newtonsoft.Json;

namespace MarketLab.SingleAnchor
{
    /// <summary>
    /// Quote-only and tradable row counts for one generated session map, computed with the same
    /// classifier the replay uses (<see cref="HistoricalTradingAvailability"/>). Produced by the
    /// session-map generator as its machine-readable validation record. Overall and
    /// complete-session populations are kept separate and each carries its own percentage: the
    /// final dataset-end session contributes opening-buffer rows but has no closing buffer, so a
    /// single "percent" for a mixed population would be ambiguous.
    /// </summary>
    public sealed record SessionMapStats
    {
        /// <summary>Contract identifier of the stats document.</summary>
        public const string Contract = "marketlab-single-anchor-session-map-stats-v1";

        [JsonProperty("contract")] public string StatsContract { get; init; } = Contract;

        /// <summary>Total sessions in the map.</summary>
        [JsonProperty("sessions")] public int Sessions { get; init; }

        /// <summary>Session boundaries produced by junctions (sessions - 1).</summary>
        [JsonProperty("junctions")] public int Junctions { get; init; }

        /// <summary>Sessions with an observable end (all but the final dataset-end session).</summary>
        [JsonProperty("completeSessions")] public int CompleteSessions { get; init; }

        /// <summary>True when the final session has a natural observed end in this source.</summary>
        [JsonProperty("finalSessionEndObservable")] public bool FinalSessionEndObservable { get; init; }

        /// <summary>Quote rows in the immutable source.</summary>
        [JsonProperty("sourceRows")] public long SourceRows { get; init; }

        /// <summary>Opening-buffer rows over every session, the final one included.</summary>
        [JsonProperty("allOpenBufferRows")] public long AllOpenBufferRows { get; init; }

        /// <summary>Closing-buffer rows; the final session has no observable end and contributes none.</summary>
        [JsonProperty("observableCloseBufferRows")] public long ObservableCloseBufferRows { get; init; }

        /// <summary>All quote-only rows (every opening buffer + every observable closing buffer).</summary>
        [JsonProperty("quoteOnlyRows")] public long QuoteOnlyRows { get; init; }

        /// <summary>Rows in the tradable body of their session.</summary>
        [JsonProperty("tradableRows")] public long TradableRows { get; init; }

        /// <summary>Opening-buffer rows of the complete sessions only.</summary>
        [JsonProperty("completeSessionOpenBufferRows")] public long CompleteSessionOpenBufferRows { get; init; }

        /// <summary>Closing-buffer rows of the complete sessions only.</summary>
        [JsonProperty("completeSessionCloseBufferRows")] public long CompleteSessionCloseBufferRows { get; init; }

        /// <summary>Quote-only rows of the complete sessions only.</summary>
        [JsonProperty("completeSessionQuoteOnlyRows")] public long CompleteSessionQuoteOnlyRows { get; init; }

        /// <summary>Opening-buffer rows of the final, dataset-end session.</summary>
        [JsonProperty("finalSessionOpenBufferRows")] public long FinalSessionOpenBufferRows { get; init; }

        /// <summary>Percentage of all source rows that are quote-only (all sessions).</summary>
        [JsonProperty("quoteOnlyPercentOfSourceRows")] public double QuoteOnlyPercentOfSourceRows { get; init; }

        /// <summary>Percentage of all source rows that are quote-only in the complete sessions.</summary>
        [JsonProperty("completeSessionQuoteOnlyPercentOfSourceRows")] public double CompleteSessionQuoteOnlyPercentOfSourceRows { get; init; }

        /// <summary>
        /// Computes the counts for one map from per-session opening/closing buffer counts produced
        /// by the classifier, and the total source row count.
        /// </summary>
        public static SessionMapStats Compute(
            HistoricalSessionMap map,
            IReadOnlyList<long> openBufferRows,
            IReadOnlyList<long> closeBufferRows,
            long sourceRows)
        {
            if (map == null) throw new ArgumentNullException(nameof(map));
            if (openBufferRows == null) throw new ArgumentNullException(nameof(openBufferRows));
            if (closeBufferRows == null) throw new ArgumentNullException(nameof(closeBufferRows));
            if (sourceRows <= 0) throw new ArgumentOutOfRangeException(nameof(sourceRows), "source row count must be positive");
            if (openBufferRows.Count != map.Sessions.Count || closeBufferRows.Count != map.Sessions.Count)
            {
                throw new ArgumentException("per-session buffer counts must match the map's session count");
            }

            long allOpen = 0;
            long observableClose = 0;
            long completeOpen = 0;
            long completeClose = 0;
            var completeSessions = 0;
            for (var i = 0; i < map.Sessions.Count; i++)
            {
                var open = openBufferRows[i];
                var close = closeBufferRows[i];
                if (open < 0 || close < 0)
                {
                    throw new ArgumentException("buffer counts cannot be negative");
                }
                allOpen += open;
                observableClose += close;
                if (map.Sessions[i]!.End.HasValue)
                {
                    completeSessions++;
                    completeOpen += open;
                    completeClose += close;
                }
            }

            var quoteOnly = allOpen + observableClose;
            var completeQuoteOnly = completeOpen + completeClose;
            return new SessionMapStats
            {
                Sessions = map.Sessions.Count,
                Junctions = map.Sessions.Count - 1,
                CompleteSessions = completeSessions,
                FinalSessionEndObservable = map.Sessions[map.Sessions.Count - 1]!.End.HasValue,
                SourceRows = sourceRows,
                AllOpenBufferRows = allOpen,
                ObservableCloseBufferRows = observableClose,
                QuoteOnlyRows = quoteOnly,
                TradableRows = sourceRows - quoteOnly,
                CompleteSessionOpenBufferRows = completeOpen,
                CompleteSessionCloseBufferRows = completeClose,
                CompleteSessionQuoteOnlyRows = completeQuoteOnly,
                FinalSessionOpenBufferRows = allOpen - completeOpen,
                QuoteOnlyPercentOfSourceRows = quoteOnly * 100d / sourceRows,
                CompleteSessionQuoteOnlyPercentOfSourceRows = completeQuoteOnly * 100d / sourceRows
            };
        }
    }
}
