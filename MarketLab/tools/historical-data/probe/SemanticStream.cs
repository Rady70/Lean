using System;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace MarketLab.HistoricalDataProbe
{
    /// <summary>
    /// Canonical value forms and the semantic stream digest shared with the offline
    /// qualification tool (<c>MarketLab/tools/historical-data/python</c>).
    ///
    /// One accepted quote serializes as one UTF-8 line:
    /// <c>{ordinal}|{yyyy-MM-ddTHH:mm:ss.fffZ}|{canonical bid}|{canonical ask}\n</c>
    /// where the ordinal is 1-based in stream order, the timestamp is canonical UTC
    /// with exactly millisecond precision and the prices are fixed-point invariant
    /// decimals without trailing fractional zeros. The digest is the SHA-256 of the
    /// concatenated lines, rendered as <c>sha256:&lt;lowercase hex&gt;</c>.
    ///
    /// This type performs no conversion and truncation of its own: a timestamp with
    /// sub-millisecond precision is rejected explicitly, exactly like the converter.
    /// </summary>
    public static class SemanticStream
    {
        /// <summary>Formats one canonical semantic tuple line, newline-terminated.</summary>
        public static string FormatLine(long ordinal, DateTime utcTimestamp, decimal bid, decimal ask)
        {
            if (ordinal < 1)
            {
                throw new ArgumentOutOfRangeException(nameof(ordinal), "ordinal must be at least 1");
            }

            var builder = new StringBuilder(64);
            builder.Append(ordinal.ToString(CultureInfo.InvariantCulture));
            builder.Append('|');
            builder.Append(CanonicalUtcTimestamp(utcTimestamp));
            builder.Append('|');
            builder.Append(CanonicalDecimal(bid));
            builder.Append('|');
            builder.Append(CanonicalDecimal(ask));
            builder.Append('\n');
            return builder.ToString();
        }

        /// <summary>Canonical fixed-point decimal text; numerically equal values share one text.</summary>
        public static string CanonicalDecimal(decimal value)
        {
            if (value == 0m)
            {
                return "0";
            }

            var bits = decimal.GetBits(value);
            var flags = bits[3];
            var negative = (flags & unchecked((int)0x80000000)) != 0;
            var scale = (flags >> 16) & 0x7F;
            var coefficient = (BigInteger)(uint)bits[0]
                | ((BigInteger)(uint)bits[1] << 32)
                | ((BigInteger)(uint)bits[2] << 64);
            var raw = coefficient.ToString(CultureInfo.InvariantCulture);
            var stripped = raw.TrimEnd('0');
            if (stripped.Length == 0)
            {
                return "0";
            }

            scale -= raw.Length - stripped.Length;
            string text;
            if (scale <= 0)
            {
                text = stripped + new string('0', -scale);
            }
            else if (stripped.Length > scale)
            {
                text = stripped.Substring(0, stripped.Length - scale) + "." + stripped.Substring(stripped.Length - scale);
            }
            else
            {
                text = "0." + new string('0', scale - stripped.Length) + stripped;
            }

            return negative ? "-" + text : text;
        }

        /// <summary>Canonical UTC timestamp text with exactly millisecond precision.</summary>
        public static string CanonicalUtcTimestamp(DateTime value)
        {
            if (value.Kind != DateTimeKind.Utc)
            {
                throw new ArgumentException("timestamp must be UTC", nameof(value));
            }

            if (value.Ticks % TimeSpan.TicksPerMillisecond != 0)
            {
                throw new ArgumentException(
                    "timestamp has sub-millisecond precision and has no native LEAN millisecond form",
                    nameof(value));
            }

            return value.ToString("yyyy-MM-ddTHH:mm:ss.fff", CultureInfo.InvariantCulture) + "Z";
        }
    }

    /// <summary>
    /// Incremental SHA-256 over canonical semantic tuple lines. Rows are added in
    /// stream order; <see cref="Digest"/> closes the stream.
    /// </summary>
    public sealed class SemanticDigest
    {
        private readonly IncrementalHash _hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        private string? _digest;

        public long Count { get; private set; }

        public string? FirstTimestamp { get; private set; }

        public string? LastTimestamp { get; private set; }

        public void Add(DateTime utcTimestamp, decimal bid, decimal ask)
        {
            if (_digest != null)
            {
                throw new InvalidOperationException("the digest is closed; no further row can be added");
            }

            var line = SemanticStream.FormatLine(Count + 1, utcTimestamp, bid, ask);
            _hash.AppendData(Encoding.UTF8.GetBytes(line));
            var timestampText = SemanticStream.CanonicalUtcTimestamp(utcTimestamp);
            FirstTimestamp ??= timestampText;
            LastTimestamp = timestampText;
            Count++;
        }

        /// <summary>Closes the stream; repeated calls return the same digest.</summary>
        public string Digest()
        {
            return _digest ??= "sha256:" + Convert.ToHexString(_hash.GetHashAndReset()).ToLowerInvariant();
        }
    }
}
