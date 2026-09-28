using System;
using System.Collections.Generic;
using System.Globalization;
using NodaTime;
using Newtonsoft.Json;
using QuantConnect;

namespace MarketLab.SingleAnchor
{
    /// <summary>Bounded evidence of the quotes actually processed, including a terminal quote.</summary>
    public sealed class QuoteDelivery
    {
        private readonly DateTimeZone _quoteZone;
        private readonly DateTimeZone _dataZone;
        private readonly SemanticDigest _global = new SemanticDigest();
        private readonly SortedDictionary<string, DeliveryPartition> _partitions = new(StringComparer.Ordinal);
        private SemanticDigest? _dayDigest;
        private string? _day;
        private Quote? _lastQuote;
        private DeliverySummary? _summary;

        public QuoteDelivery(DateTimeZone quoteZone, DateTimeZone dataZone)
        {
            _quoteZone = quoteZone;
            _dataZone = dataZone;
        }

        public void Add(Quote quote)
        {
            if (_summary != null) throw new InvalidOperationException("Delivery evidence is already closed.");
            var utc = DateTime.SpecifyKind(quote.Time.ConvertTo(_quoteZone, TimeZones.Utc), DateTimeKind.Utc);
            var day = utc.ConvertTo(TimeZones.Utc, _dataZone).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (day != _day)
            {
                CloseDay();
                _day = day;
                _dayDigest = new SemanticDigest();
            }
            _global.Add(utc, quote.Bid, quote.Ask);
            _dayDigest!.Add(utc, quote.Bid, quote.Ask);
            _lastQuote = new Quote(utc, quote.Bid, quote.Ask);
        }

        public DeliverySummary Snapshot()
        {
            if (_summary != null) return _summary;
            CloseDay();
            return _summary = new DeliverySummary(_global.Count, _global.Digest(),
                _global.FirstTimestamp, _global.LastTimestamp, _lastQuote, _partitions);
        }

        private void CloseDay()
        {
            if (_dayDigest == null || _day == null) return;
            _partitions.Add(_day, new DeliveryPartition(_dayDigest.Count, _dayDigest.Digest()));
            _dayDigest = null;
        }
    }

    public sealed record DeliveryPartition(
        [property: JsonProperty("quote_count")] long QuoteCount,
        [property: JsonProperty("semantic_digest")] string SemanticDigest);

    public sealed record DeliverySummary(
        [property: JsonProperty("quote_count")] long QuoteCount,
        [property: JsonProperty("semantic_digest")] string SemanticDigest,
        [property: JsonProperty("first_canonical_utc")] string? FirstCanonicalUtc,
        [property: JsonProperty("last_canonical_utc")] string? LastCanonicalUtc,
        [property: JsonProperty("last_quote")] Quote? LastQuote,
        [property: JsonProperty("per_partition")] IReadOnlyDictionary<string, DeliveryPartition> PerPartition);
}
