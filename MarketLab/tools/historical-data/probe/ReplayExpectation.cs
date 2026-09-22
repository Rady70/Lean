using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Newtonsoft.Json;

namespace MarketLab.HistoricalDataProbe
{
    /// <summary>
    /// The replay expectation written by the offline qualification tool
    /// (<c>replay-expectation.json</c> in the runtime data folder). It is the
    /// qualified source stream in summary form: accepted count, ordered semantic
    /// digest, first/last canonical UTC, the replay window and the per-partition
    /// expectations.
    /// </summary>
    public sealed class ReplayExpectation
    {
        [JsonProperty("contract")]
        public string Contract { get; set; } = string.Empty;

        [JsonProperty("symbol")]
        public string Symbol { get; set; } = string.Empty;

        [JsonProperty("market")]
        public string Market { get; set; } = string.Empty;

        [JsonProperty("security_type")]
        public string SecurityType { get; set; } = string.Empty;

        [JsonProperty("data_time_zone")]
        public string DataTimeZone { get; set; } = string.Empty;

        [JsonProperty("exchange_time_zone")]
        public string ExchangeTimeZone { get; set; } = string.Empty;

        [JsonProperty("source_path")]
        public string SourcePath { get; set; } = string.Empty;

        [JsonProperty("source_file_sha256")]
        public string SourceFileSha256 { get; set; } = string.Empty;

        [JsonProperty("accepted_row_count")]
        public long AcceptedRowCount { get; set; }

        [JsonProperty("ordered_source_semantic_digest")]
        public string OrderedSourceSemanticDigest { get; set; } = string.Empty;

        [JsonProperty("first_canonical_utc")]
        public string FirstCanonicalUtc { get; set; } = string.Empty;

        [JsonProperty("last_canonical_utc")]
        public string LastCanonicalUtc { get; set; } = string.Empty;

        [JsonProperty("lean_run_window")]
        public LeanRunWindow RunWindow { get; set; } = new LeanRunWindow();

        [JsonProperty("partitions")]
        public Dictionary<string, ExpectedPartition> Partitions { get; set; } = new Dictionary<string, ExpectedPartition>();

        public static ReplayExpectation Load(string path)
        {
            var expectation = JsonConvert.DeserializeObject<ReplayExpectation>(File.ReadAllText(path));
            if (expectation == null)
            {
                throw new InvalidOperationException($"replay expectation is empty: {path}");
            }

            return expectation;
        }

        public DateTime ParseStartDate()
        {
            return DateTime.ParseExact(RunWindow.StartDate, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        }

        public DateTime ParseEndDate()
        {
            return DateTime.ParseExact(RunWindow.EndDate, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        }
    }

    /// <summary>The data-timezone date window the probe must ask LEAN to read.</summary>
    public sealed class LeanRunWindow
    {
        [JsonProperty("start_date")]
        public string StartDate { get; set; } = string.Empty;

        [JsonProperty("end_date")]
        public string EndDate { get; set; } = string.Empty;
    }

    /// <summary>One expected native partition: accepted rows and their semantic digest.</summary>
    public sealed class ExpectedPartition
    {
        [JsonProperty("accepted_row_count")]
        public long AcceptedRowCount { get; set; }

        [JsonProperty("semantic_digest")]
        public string SemanticDigest { get; set; } = string.Empty;
    }
}
