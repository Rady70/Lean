using System;
using System.Collections.Generic;
using System.Globalization;
using NodaTime;
using Newtonsoft.Json;
using QuantConnect;

namespace MarketLab.HistoricalDataProbe
{
    /// <summary>One delivered native partition: quotes and their semantic digest.</summary>
    public sealed class DeliveredPartition
    {
        [JsonProperty("quote_count")]
        public long QuoteCount { get; set; }

        [JsonProperty("semantic_digest")]
        public string SemanticDigest { get; set; } = string.Empty;
    }

    /// <summary>The quote stream LEAN actually delivered to the probe.</summary>
    public sealed class DeliveredSummary
    {
        [JsonProperty("quote_count")]
        public long QuoteCount { get; set; }

        [JsonProperty("semantic_digest")]
        public string SemanticDigest { get; set; } = string.Empty;

        [JsonProperty("first_canonical_utc")]
        public string FirstCanonicalUtc { get; set; } = string.Empty;

        [JsonProperty("last_canonical_utc")]
        public string LastCanonicalUtc { get; set; } = string.Empty;

        [JsonProperty("per_partition")]
        public Dictionary<string, DeliveredPartition> PerPartition { get; set; } = new Dictionary<string, DeliveredPartition>();
    }

    /// <summary>Every qualified-source check the probe evaluated against the delivery.</summary>
    public sealed class ReplayComparison
    {
        [JsonProperty("count_matches")]
        public bool CountMatches { get; set; }

        [JsonProperty("digest_matches")]
        public bool DigestMatches { get; set; }

        [JsonProperty("first_matches")]
        public bool FirstMatches { get; set; }

        [JsonProperty("last_matches")]
        public bool LastMatches { get; set; }

        [JsonProperty("per_partition_counts_match")]
        public bool PerPartitionCountsMatch { get; set; }

        [JsonProperty("per_partition_digests_match")]
        public bool PerPartitionDigestsMatch { get; set; }

        [JsonProperty("session_delivery_difference")]
        public long SessionDeliveryDifference { get; set; }
    }

    /// <summary>The engine condition that stopped a probe run, when one did.</summary>
    public sealed class EngineFault
    {
        [JsonProperty("kind")]
        public string Kind { get; set; } = string.Empty;

        [JsonProperty("condition")]
        public string Condition { get; set; } = string.Empty;

        [JsonProperty("message")]
        public string Message { get; set; } = string.Empty;

        [JsonProperty("quote")]
        public string? Quote { get; set; }
    }

    /// <summary>The actual runtime configuration the probe observed.</summary>
    public sealed class ProbeRuntime
    {
        [JsonProperty("data_time_zone")]
        public string DataTimeZone { get; set; } = string.Empty;

        [JsonProperty("exchange_time_zone")]
        public string ExchangeTimeZone { get; set; } = string.Empty;

        [JsonProperty("algorithm_time_zone")]
        public string AlgorithmTimeZone { get; set; } = string.Empty;

        [JsonProperty("market_hours_database_path")]
        public string MarketHoursDatabasePath { get; set; } = string.Empty;

        [JsonProperty("market_hours_database_sha256")]
        public string MarketHoursDatabaseSha256 { get; set; } = string.Empty;

        [JsonProperty("lean_data_folder")]
        public string LeanDataFolder { get; set; } = string.Empty;

        [JsonProperty("start_date")]
        public string StartDate { get; set; } = string.Empty;

        [JsonProperty("end_date")]
        public string EndDate { get; set; } = string.Empty;

        [JsonProperty("engine_quotes_processed")]
        public long EngineQuotesProcessed { get; set; }

        [JsonProperty("engine_non_quote_ticks")]
        public long EngineNonQuoteTicks { get; set; }

        [JsonProperty("engine_fault")]
        public EngineFault? EngineFault { get; set; }
    }

    /// <summary>The probe's machine-readable result, written to the run's object store.</summary>
    public sealed class ReplayProbeResult
    {
        [JsonProperty("probe")]
        public string Probe { get; set; } = "MarketLab.HistoricalDataReplayProbe";

        [JsonProperty("contract")]
        public string Contract { get; set; } = "marketlab-single-anchor-replay-probe-v1";

        [JsonProperty("completed")]
        public bool Completed { get; set; }

        [JsonProperty("qualification")]
        public string Qualification { get; set; } = "FAIL";

        [JsonProperty("failure_reasons")]
        public List<string> FailureReasons { get; set; } = new List<string>();

        [JsonProperty("expected")]
        public ReplayExpectation Expected { get; set; } = new ReplayExpectation();

        [JsonProperty("delivered")]
        public DeliveredSummary Delivered { get; set; } = new DeliveredSummary();

        [JsonProperty("comparison")]
        public ReplayComparison Comparison { get; set; } = new ReplayComparison();

        [JsonProperty("runtime")]
        public ProbeRuntime Runtime { get; set; } = new ProbeRuntime();
    }

    /// <summary>
    /// Accumulates the delivered quote stream and derives the same canonical semantic
    /// digest the converter produced for the qualified source.
    /// </summary>
    public sealed class DeliveredStream
    {
        private readonly SemanticDigest _global = new SemanticDigest();
        private readonly SortedDictionary<string, SemanticDigest> _partitions =
            new SortedDictionary<string, SemanticDigest>(StringComparer.Ordinal);
        private readonly DateTimeZone _exchangeTimeZone;
        private readonly DateTimeZone _dataTimeZone;

        public DeliveredStream(DateTimeZone exchangeTimeZone, DateTimeZone dataTimeZone)
        {
            _exchangeTimeZone = exchangeTimeZone;
            _dataTimeZone = dataTimeZone;
        }

        public long Count => _global.Count;

        /// <summary>Adds one delivered quote; the time is the exchange-local <c>Tick.Time</c>.</summary>
        public void Add(DateTime exchangeLocalTime, decimal bid, decimal ask)
        {
            // LEAN's ConvertTo returns Kind.Unspecified even when the result is UTC wall time,
            // so the canonical UTC kind is stated explicitly here.
            var utc = DateTime.SpecifyKind(
                exchangeLocalTime.ConvertTo(_exchangeTimeZone, TimeZones.Utc),
                DateTimeKind.Utc);
            _global.Add(utc, bid, ask);
            var partition = utc.ConvertTo(TimeZones.Utc, _dataTimeZone).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (!_partitions.TryGetValue(partition, out var digest))
            {
                digest = new SemanticDigest();
                _partitions[partition] = digest;
            }

            digest.Add(utc, bid, ask);
        }

        public DeliveredSummary ToSummary()
        {
            var partitions = new Dictionary<string, DeliveredPartition>(StringComparer.Ordinal);
            foreach (var pair in _partitions)
            {
                partitions[pair.Key] = new DeliveredPartition
                {
                    QuoteCount = pair.Value.Count,
                    SemanticDigest = pair.Value.Digest()
                };
            }

            return new DeliveredSummary
            {
                QuoteCount = _global.Count,
                SemanticDigest = _global.Digest(),
                FirstCanonicalUtc = _global.FirstTimestamp ?? string.Empty,
                LastCanonicalUtc = _global.LastTimestamp ?? string.Empty,
                PerPartition = partitions
            };
        }
    }

    /// <summary>Compares the qualified source expectation with the delivered stream.</summary>
    public static class ReplayQualification
    {
        public static ReplayComparison Compare(ReplayExpectation expected, DeliveredSummary delivered)
        {
            var expectedPartitions = expected.Partitions ?? new Dictionary<string, ExpectedPartition>();
            var partitionCountsMatch = expectedPartitions.Count == delivered.PerPartition.Count;
            var partitionDigestsMatch = partitionCountsMatch;
            if (partitionCountsMatch)
            {
                foreach (var pair in expectedPartitions)
                {
                    if (!delivered.PerPartition.TryGetValue(pair.Key, out var actual))
                    {
                        partitionCountsMatch = false;
                        partitionDigestsMatch = false;
                        break;
                    }

                    if (actual.QuoteCount != pair.Value.AcceptedRowCount)
                    {
                        partitionCountsMatch = false;
                    }

                    if (!string.Equals(actual.SemanticDigest, pair.Value.SemanticDigest, StringComparison.Ordinal))
                    {
                        partitionDigestsMatch = false;
                    }
                }
            }

            return new ReplayComparison
            {
                CountMatches = expected.AcceptedRowCount == delivered.QuoteCount,
                DigestMatches = string.Equals(
                    expected.OrderedSourceSemanticDigest,
                    delivered.SemanticDigest,
                    StringComparison.Ordinal),
                FirstMatches = string.Equals(
                    expected.FirstCanonicalUtc,
                    delivered.FirstCanonicalUtc,
                    StringComparison.Ordinal),
                LastMatches = string.Equals(
                    expected.LastCanonicalUtc,
                    delivered.LastCanonicalUtc,
                    StringComparison.Ordinal),
                PerPartitionCountsMatch = partitionCountsMatch,
                PerPartitionDigestsMatch = partitionDigestsMatch,
                SessionDeliveryDifference = expected.AcceptedRowCount - delivered.QuoteCount
            };
        }

        public static List<string> FailureReasons(ReplayComparison comparison)
        {
            var reasons = new List<string>();
            if (!comparison.CountMatches)
            {
                reasons.Add("ExpectedAndDeliveredCountsDiffer");
            }

            if (!comparison.DigestMatches)
            {
                reasons.Add("DeliveredSemanticDigestMismatches");
            }

            if (!comparison.FirstMatches)
            {
                reasons.Add("FirstDeliveredQuoteMismatches");
            }

            if (!comparison.LastMatches)
            {
                reasons.Add("LastDeliveredQuoteMismatches");
            }

            if (!comparison.PerPartitionCountsMatch)
            {
                reasons.Add("PerPartitionCountsDiffer");
            }

            if (!comparison.PerPartitionDigestsMatch)
            {
                reasons.Add("PerPartitionDigestsDiffer");
            }

            return reasons;
        }
    }
}
