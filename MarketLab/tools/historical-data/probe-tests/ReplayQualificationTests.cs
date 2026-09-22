using System;
using System.Collections.Generic;
using NodaTime;
using NUnit.Framework;
using QuantConnect;

namespace MarketLab.HistoricalDataProbe.Tests
{
    [TestFixture]
    public class ReplayQualificationTests
    {
        private static readonly DateTimeZone NewYork = DateTimeZoneProviders.Tzdb["America/New_York"];

        private static ReplayExpectation Expected()
        {
            return new ReplayExpectation
            {
                Contract = SingleAnchorReplayProbeAlgorithm.ExpectationContract,
                Symbol = "XAUUSD",
                Market = "oanda",
                SecurityType = "Cfd",
                DataTimeZone = "UTC",
                ExchangeTimeZone = "America/New_York",
                AcceptedRowCount = 2,
                OrderedSourceSemanticDigest = "sha256:expected",
                FirstCanonicalUtc = "2014-05-05T08:00:00.000Z",
                LastCanonicalUtc = "2014-05-05T08:00:00.001Z",
                RunWindow = new LeanRunWindow { StartDate = "2014-05-05", EndDate = "2014-05-05" },
                Partitions = new Dictionary<string, ExpectedPartition>
                {
                    ["2014-05-05"] = new ExpectedPartition
                    {
                        AcceptedRowCount = 2,
                        SemanticDigest = "sha256:expected"
                    }
                }
            };
        }

        private static DeliveredSummary MatchingDelivered()
        {
            return new DeliveredSummary
            {
                QuoteCount = 2,
                SemanticDigest = "sha256:expected",
                FirstCanonicalUtc = "2014-05-05T08:00:00.000Z",
                LastCanonicalUtc = "2014-05-05T08:00:00.001Z",
                PerPartition = new Dictionary<string, DeliveredPartition>
                {
                    ["2014-05-05"] = new DeliveredPartition
                    {
                        QuoteCount = 2,
                        SemanticDigest = "sha256:expected"
                    }
                }
            };
        }

        [Test]
        public void Compare_AcceptsAnExactDelivery()
        {
            var comparison = ReplayQualification.Compare(Expected(), MatchingDelivered());

            Assert.That(comparison.CountMatches, Is.True);
            Assert.That(comparison.DigestMatches, Is.True);
            Assert.That(comparison.FirstMatches, Is.True);
            Assert.That(comparison.LastMatches, Is.True);
            Assert.That(comparison.PerPartitionCountsMatch, Is.True);
            Assert.That(comparison.PerPartitionDigestsMatch, Is.True);
            Assert.That(comparison.SessionDeliveryDifference, Is.Zero);
            Assert.That(ReplayQualification.FailureReasons(comparison), Is.Empty);
        }

        [Test]
        public void Compare_FailsWhenLeanDropsAnAcceptedQuote()
        {
            var delivered = MatchingDelivered();
            delivered.QuoteCount = 1;
            delivered.LastCanonicalUtc = delivered.FirstCanonicalUtc;
            delivered.PerPartition["2014-05-05"].QuoteCount = 1;

            var comparison = ReplayQualification.Compare(Expected(), delivered);
            var reasons = ReplayQualification.FailureReasons(comparison);

            Assert.That(comparison.SessionDeliveryDifference, Is.EqualTo(1));
            Assert.That(comparison.CountMatches, Is.False);
            Assert.That(comparison.PerPartitionCountsMatch, Is.False);
            Assert.That(reasons, Does.Contain("ExpectedAndDeliveredCountsDiffer"));
            Assert.That(reasons, Does.Contain("PerPartitionCountsDiffer"));
        }

        [Test]
        public void Compare_FailsOnAPriceOrOrderMismatch()
        {
            var delivered = MatchingDelivered();
            delivered.SemanticDigest = "sha256:other";
            delivered.PerPartition["2014-05-05"].SemanticDigest = "sha256:other";

            var comparison = ReplayQualification.Compare(Expected(), delivered);
            var reasons = ReplayQualification.FailureReasons(comparison);

            Assert.That(comparison.CountMatches, Is.True);
            Assert.That(comparison.DigestMatches, Is.False);
            Assert.That(comparison.PerPartitionDigestsMatch, Is.False);
            Assert.That(reasons, Does.Contain("DeliveredSemanticDigestMismatches"));
            Assert.That(reasons, Does.Contain("PerPartitionDigestsDiffer"));
        }

        [Test]
        public void Compare_FailsOnFirstOrLastMismatch()
        {
            var delivered = MatchingDelivered();
            delivered.FirstCanonicalUtc = "2014-05-05T08:00:00.123Z";
            delivered.LastCanonicalUtc = "2014-05-05T08:00:00.999Z";

            var comparison = ReplayQualification.Compare(Expected(), delivered);
            var reasons = ReplayQualification.FailureReasons(comparison);

            Assert.That(reasons, Does.Contain("FirstDeliveredQuoteMismatches"));
            Assert.That(reasons, Does.Contain("LastDeliveredQuoteMismatches"));
        }

        [Test]
        public void DeliveredStream_NormalizesExchangeLocalTimeToCanonicalUtc()
        {
            var stream = new DeliveredStream(NewYork, TimeZones.Utc);
            stream.Add(new DateTime(2014, 5, 5, 4, 0, 0, DateTimeKind.Unspecified), 1.1m, 1.2m);

            var summary = stream.ToSummary();
            Assert.That(summary.QuoteCount, Is.EqualTo(1));
            Assert.That(summary.FirstCanonicalUtc, Is.EqualTo("2014-05-05T08:00:00.000Z"));
            Assert.That(summary.PerPartition.Keys, Is.EquivalentTo(new[] { "2014-05-05" }));
        }

        [Test]
        public void DeliveredStream_PreservesSameMillisecondOrderAndDuplicates()
        {
            var stream = new DeliveredStream(TimeZones.Utc, TimeZones.Utc);
            stream.Add(new DateTime(2014, 5, 5, 8, 0, 0, 100, DateTimeKind.Unspecified), 1.1m, 1.2m);
            stream.Add(new DateTime(2014, 5, 5, 8, 0, 0, 100, DateTimeKind.Unspecified), 1.1m, 1.2m);

            var summary = stream.ToSummary();
            Assert.That(summary.QuoteCount, Is.EqualTo(2));

            var reversed = new DeliveredStream(TimeZones.Utc, TimeZones.Utc);
            reversed.Add(new DateTime(2014, 5, 5, 8, 0, 0, 200, DateTimeKind.Unspecified), 1.1m, 1.2m);
            reversed.Add(new DateTime(2014, 5, 5, 8, 0, 0, 100, DateTimeKind.Unspecified), 1.1m, 1.2m);

            Assert.That(summary.SemanticDigest, Is.Not.EqualTo(reversed.ToSummary().SemanticDigest));
        }

        [Test]
        public void DeliveredStream_PartitionsUseTheDataTimeZone()
        {
            var stream = new DeliveredStream(NewYork, TimeZones.Utc);
            stream.Add(new DateTime(2014, 5, 4, 20, 30, 0, DateTimeKind.Unspecified), 1.1m, 1.2m);

            var summary = stream.ToSummary();
            Assert.That(
                summary.PerPartition.Keys,
                Is.EquivalentTo(new[] { "2014-05-05" }),
                "the partition is the data-timezone date (UTC here), not the exchange-timezone date");
            Assert.That(summary.FirstCanonicalUtc, Is.EqualTo("2014-05-05T00:30:00.000Z"));
        }
    }
}
