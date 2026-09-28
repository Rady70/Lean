using System;

namespace MarketLab.HistoricalDataProbe
{
    // Keep the probe API while sharing the exact canonical serializer with the production host.
    public static class SemanticStream
    {
        public static string FormatLine(long ordinal, DateTime utcTimestamp, decimal bid, decimal ask) =>
            SingleAnchor.SemanticStream.FormatLine(ordinal, utcTimestamp, bid, ask);
        public static string CanonicalDecimal(decimal value) => SingleAnchor.SemanticStream.CanonicalDecimal(value);
        public static string CanonicalUtcTimestamp(DateTime value) => SingleAnchor.SemanticStream.CanonicalUtcTimestamp(value);
    }

    public sealed class SemanticDigest
    {
        private readonly SingleAnchor.SemanticDigest _inner = new SingleAnchor.SemanticDigest();
        public long Count => _inner.Count;
        public string? FirstTimestamp => _inner.FirstTimestamp;
        public string? LastTimestamp => _inner.LastTimestamp;
        public void Add(DateTime utcTimestamp, decimal bid, decimal ask) => _inner.Add(utcTimestamp, bid, ask);
        public string Digest() => _inner.Digest();
    }
}
