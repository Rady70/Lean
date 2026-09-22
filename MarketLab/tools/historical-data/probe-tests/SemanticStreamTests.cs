using System;
using NUnit.Framework;
using QuantConnect;

namespace MarketLab.HistoricalDataProbe.Tests
{
    [TestFixture]
    public class SemanticStreamTests
    {
        private static DateTime Utc(int hour, int minute, int second, int millisecond)
        {
            return new DateTime(2014, 5, 5, hour, minute, second, millisecond, DateTimeKind.Utc);
        }

        [TestCase("1.20", "1.2")]
        [TestCase("1.200", "1.2")]
        [TestCase("1000.000", "1000")]
        [TestCase("0.000", "0")]
        [TestCase("0.001", "0.001")]
        [TestCase("-0.0", "0")]
        [TestCase("1291.6770", "1291.677")]
        [TestCase("0.0500", "0.05")]
        [TestCase("1291.68", "1291.68")]
        public void CanonicalDecimal_MatchesTheOfflineContract(string input, string expected)
        {
            Assert.That(SemanticStream.CanonicalDecimal(decimal.Parse(input, System.Globalization.CultureInfo.InvariantCulture)), Is.EqualTo(expected));
        }

        [Test]
        public void CanonicalDecimal_NumericallyEqualValuesShareOneText()
        {
            Assert.That(
                SemanticStream.CanonicalDecimal(1.200m),
                Is.EqualTo(SemanticStream.CanonicalDecimal(1.2m)),
                "trailing fractional zeros must not change the canonical text");
        }

        [Test]
        public void CanonicalUtcTimestamp_IsFixedMillisecondForm()
        {
            Assert.That(
                SemanticStream.CanonicalUtcTimestamp(Utc(8, 0, 0, 250)),
                Is.EqualTo("2014-05-05T08:00:00.250Z"));
        }

        [Test]
        public void CanonicalUtcTimestamp_RejectsSubMillisecondPrecision()
        {
            var value = new DateTime(2014, 5, 5, 8, 0, 0, DateTimeKind.Utc).AddTicks(1234);
            Assert.Throws<ArgumentException>(() => SemanticStream.CanonicalUtcTimestamp(value));
        }

        [Test]
        public void CanonicalUtcTimestamp_RejectsNonUtcKind()
        {
            var value = new DateTime(2014, 5, 5, 8, 0, 0, DateTimeKind.Unspecified);
            Assert.Throws<ArgumentException>(() => SemanticStream.CanonicalUtcTimestamp(value));
        }

        [Test]
        public void FormatLine_UsesTheDocumentedTupleOrder()
        {
            Assert.That(
                SemanticStream.FormatLine(1, Utc(8, 0, 0, 0), 1291.6770m, 1292.0330m),
                Is.EqualTo("1|2014-05-05T08:00:00.000Z|1291.677|1292.033\n"));
        }

        [Test]
        public void Digest_MatchesTheCrossLanguageReferenceVector()
        {
            var digest = new SemanticDigest();
            digest.Add(Utc(8, 0, 0, 0), 1291.6770m, 1292.0330m);
            digest.Add(Utc(8, 0, 0, 100), 1291.680m, 1291.680m);
            digest.Add(Utc(8, 0, 0, 100), 1291.681m, 1291.684m);
            digest.Add(Utc(8, 0, 0, 250), 1291.69m, 1291.72m);

            Assert.That(digest.Count, Is.EqualTo(4));
            Assert.That(digest.FirstTimestamp, Is.EqualTo("2014-05-05T08:00:00.000Z"));
            Assert.That(digest.LastTimestamp, Is.EqualTo("2014-05-05T08:00:00.250Z"));
            Assert.That(
                digest.Digest(),
                Is.EqualTo("sha256:92db8c553e1229145d107d52e8da0e40f645b3f929bbe41a864d2c0e4053d218"),
                "the Python converter produced this digest for the same canonical tuples");
        }

        [Test]
        public void Digest_IsIdempotent()
        {
            var digest = new SemanticDigest();
            digest.Add(Utc(8, 0, 0, 0), 1.1m, 1.2m);
            var first = digest.Digest();
            Assert.That(digest.Digest(), Is.EqualTo(first), "closing the digest must not reset it");
            Assert.Throws<InvalidOperationException>(
                () => digest.Add(Utc(8, 0, 0, 1), 1.1m, 1.2m),
                "a closed digest must refuse further rows");

            var stream = new DeliveredStream(TimeZones.Utc, TimeZones.Utc);
            stream.Add(new DateTime(2014, 5, 5, 8, 0, 0, DateTimeKind.Unspecified), 1.1m, 1.2m);
            Assert.That(
                stream.ToSummary().SemanticDigest,
                Is.EqualTo(stream.ToSummary().SemanticDigest),
                "repeated summaries must report the same delivered digest");
        }

        [Test]
        public void Digest_DistinguishesOrder()
        {
            var first = new SemanticDigest();
            first.Add(Utc(8, 0, 0, 0), 1.1m, 1.2m);
            first.Add(Utc(8, 0, 0, 1), 1.3m, 1.4m);

            var second = new SemanticDigest();
            second.Add(Utc(8, 0, 0, 1), 1.3m, 1.4m);
            second.Add(Utc(8, 0, 0, 0), 1.1m, 1.2m);

            Assert.That(first.Digest(), Is.Not.EqualTo(second.Digest()));
        }

        [Test]
        public void Digest_PreservesDuplicateRows()
        {
            var once = new SemanticDigest();
            once.Add(Utc(8, 0, 0, 0), 1.1m, 1.2m);

            var twice = new SemanticDigest();
            twice.Add(Utc(8, 0, 0, 0), 1.1m, 1.2m);
            twice.Add(Utc(8, 0, 0, 0), 1.1m, 1.2m);

            Assert.That(twice.Count, Is.EqualTo(2));
            Assert.That(twice.Digest(), Is.Not.EqualTo(once.Digest()));
        }
    }
}
