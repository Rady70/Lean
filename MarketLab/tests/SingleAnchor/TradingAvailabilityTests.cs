using System;
using System.IO;
using NodaTime;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>Deterministic session fixtures: two complete sessions on one synthetic day.</summary>
    internal static class Sessions
    {
        public static readonly DateTime S0 = new DateTime(2024, 1, 2, 0, 0, 0);
        public static readonly DateTime S0End = new DateTime(2024, 1, 2, 2, 0, 0);
        public static readonly DateTime S1 = new DateTime(2024, 1, 2, 3, 0, 0);
        public static readonly DateTime S1End = new DateTime(2024, 1, 2, 5, 0, 0);

        public static HistoricalSession Window(DateTime start, DateTime? end)
        {
            return new HistoricalSession(start, end);
        }

        public static HistoricalTradingAvailability Availability(params HistoricalSession[] sessions)
        {
            return new HistoricalTradingAvailability(sessions);
        }

        public static HistoricalTradingAvailability Coverage(DateTime coverageEnd, params HistoricalSession[] sessions)
        {
            return new HistoricalTradingAvailability(sessions, coverageEnd);
        }

        public static HistoricalTradingAvailability TwoSessions()
        {
            return Availability(Window(S0, S0End), Window(S1, S1End));
        }

        public static HistoricalSessionMapSource Source(DateTime firstQuoteUtc, DateTime lastQuoteUtc, int files = 90, long rows = 413750130)
        {
            return new HistoricalSessionMapSource(files, rows, new string('a', 64), firstQuoteUtc, lastQuoteUtc);
        }

        public static DateTime U(int year, int month, int day, int hour, int minute, int second)
        {
            return new DateTime(year, month, day, hour, minute, second, DateTimeKind.Utc);
        }
    }

    [TestFixture]
    public class TradingAvailabilityClassificationTests
    {
        [Test]
        public void CompleteSessionHasExactOpeningAndClosingQuoteOnlyWindows()
        {
            var a = Sessions.Availability(Sessions.Window(Sessions.S0, Sessions.S0End));

            Assert.That(a.Classify(Sessions.S0), Is.EqualTo(QuoteTradability.QuoteOnlyOpeningBuffer),
                "t = T0 is quote-only");
            Assert.That(a.Classify(Sessions.S0.AddMilliseconds(299_999)), Is.EqualTo(QuoteTradability.QuoteOnlyOpeningBuffer),
                "t = T0 + 4m59.999s is quote-only");
            Assert.That(a.Classify(Sessions.S0.AddMilliseconds(300_000)), Is.EqualTo(QuoteTradability.Tradable),
                "t = T0 + 5m is tradable");
            Assert.That(a.Classify(Sessions.S0End.AddMilliseconds(-300_000)), Is.EqualTo(QuoteTradability.Tradable),
                "t = T1 - 5m is tradable");
            Assert.That(a.Classify(Sessions.S0End.AddMilliseconds(-299_999)), Is.EqualTo(QuoteTradability.QuoteOnlyClosingBuffer),
                "t = T1 - 4m59.999s is quote-only");
            Assert.That(a.Classify(Sessions.S0End), Is.EqualTo(QuoteTradability.QuoteOnlyClosingBuffer),
                "t = T1 is quote-only");
        }

        [Test]
        public void SessionWithoutObservableEndHasAnOpeningBufferAndStopsAtTheSourceCoverageEnd()
        {
            var coverageEnd = Sessions.S0.AddHours(10);
            var a = Sessions.Coverage(coverageEnd, Sessions.Window(Sessions.S0, null));

            Assert.That(a.Classify(Sessions.S0.AddMilliseconds(299_999)), Is.EqualTo(QuoteTradability.QuoteOnlyOpeningBuffer));
            Assert.That(a.Classify(Sessions.S0.AddMilliseconds(300_000)), Is.EqualTo(QuoteTradability.Tradable));
            Assert.That(a.Classify(coverageEnd), Is.EqualTo(QuoteTradability.Tradable),
                "the natural close is unknown, so no closing buffer is fabricated, but coverage is finite");
            Assert.Throws<InvalidOperationException>(() => a.Classify(coverageEnd.AddMilliseconds(1)),
                "one millisecond after the last observed quote is outside the map");
        }

        [Test]
        public void ATruncatedFinalSessionMayBeShorterThanTenMinutes()
        {
            // The ten-minute minimum applies to completed sessions; a dataset-end session has no
            // fabricated close, so a short tail is all opening-buffer quote-only.
            var coverageEnd = Sessions.S0.AddMinutes(3);
            var a = Sessions.Coverage(coverageEnd, Sessions.Window(Sessions.S0, null));

            Assert.That(a.Classify(Sessions.S0), Is.EqualTo(QuoteTradability.QuoteOnlyOpeningBuffer));
            Assert.That(a.Classify(coverageEnd), Is.EqualTo(QuoteTradability.QuoteOnlyOpeningBuffer));
            Assert.Throws<InvalidOperationException>(() => a.Classify(coverageEnd.AddMilliseconds(1)));
        }

        [Test]
        public void AFinalSessionWithoutObservableEndRequiresTheCoverageEnd()
        {
            var error = Assert.Throws<ArgumentException>(() =>
                new HistoricalTradingAvailability(new[] { Sessions.Window(Sessions.S0, null) }))!;

            Assert.That(error.Message, Does.Contain("coverage end"));
        }

        [Test]
        public void TheSessionIndexOfTheQuoteIsReported()
        {
            var a = Sessions.TwoSessions();

            a.Classify(Sessions.S0, out var first);
            a.Classify(Sessions.S1.AddMinutes(1), out var second);
            a.Classify(Sessions.S1End, out var stillSecond);

            Assert.That(first, Is.EqualTo(0));
            Assert.That(second, Is.EqualTo(1));
            Assert.That(stillSecond, Is.EqualTo(1));
        }

        [Test]
        public void AQuoteOutsideEverySessionIsRefused()
        {
            var before = Sessions.Availability(Sessions.Window(Sessions.S0, Sessions.S0End));
            Assert.Throws<InvalidOperationException>(() => before.Classify(Sessions.S0.AddMinutes(-1)));

            var after = Sessions.Availability(Sessions.Window(Sessions.S0, Sessions.S0End));
            Assert.Throws<InvalidOperationException>(() => after.Classify(Sessions.S0End.AddMinutes(1)));
        }

        [Test]
        public void TheSameMapServesAnyQuoteClock()
        {
            // 2024-01-02 23:00:00Z is 18:00 New York: the junction rule is New York based, but the
            // replay may deliver quotes in another clock, so the UTC boundaries are converted to
            // whatever clock the run uses.
            var map = new HistoricalSessionMap(
                "XAUUSD", SessionJunctionRule.TimeZoneId,
                new[] { Sessions.Window(Sessions.U(2024, 1, 2, 23, 0, 0), Sessions.U(2024, 1, 3, 2, 0, 0)) });

            var newYork = map.ToAvailability(DateTimeZoneProviders.Tzdb["America/New_York"]);
            Assert.That(newYork.Classify(new DateTime(2024, 1, 2, 18, 0, 0)), Is.EqualTo(QuoteTradability.QuoteOnlyOpeningBuffer));
            Assert.That(newYork.Classify(new DateTime(2024, 1, 2, 18, 5, 0)), Is.EqualTo(QuoteTradability.Tradable));

            var utc = map.ToAvailability(DateTimeZone.Utc);
            Assert.That(utc.Classify(new DateTime(2024, 1, 2, 23, 0, 0)), Is.EqualTo(QuoteTradability.QuoteOnlyOpeningBuffer));
            Assert.That(utc.Classify(new DateTime(2024, 1, 2, 23, 5, 0)), Is.EqualTo(QuoteTradability.Tradable));
        }
    }

    [TestFixture]
    public class SessionJunctionRuleTests
    {
        [Test]
        public void AGapContainingTheNewYork17To18IntervalIsAJunction()
        {
            // 2024-01-02 21:59:59Z = 16:59:59 New York; 23:00:00Z = 18:00:00 New York.
            Assert.That(SessionJunctionRule.IsJunction(
                Sessions.U(2024, 1, 2, 21, 59, 59), Sessions.U(2024, 1, 2, 23, 0, 0)), Is.True);
        }

        [Test]
        public void TheGapBoundariesAreStrictOnTheLastTickAndInclusiveOnTheNextTick()
        {
            var at17 = Sessions.U(2024, 1, 2, 22, 0, 0);          // 17:00:00 New York
            var at18 = Sessions.U(2024, 1, 2, 23, 0, 0);          // 18:00:00 New York
            var justBefore18 = Sessions.U(2024, 1, 2, 22, 59, 59).AddMilliseconds(999);

            Assert.That(SessionJunctionRule.IsJunction(at17, at18), Is.False,
                "a run ending exactly at 17:00 does not itself contain the settlement interval");
            Assert.That(SessionJunctionRule.IsJunction(at17.AddMilliseconds(-1), at18), Is.True);
            Assert.That(SessionJunctionRule.IsJunction(at17.AddMilliseconds(-1), justBefore18), Is.False,
                "the interval is complete only when the next run reaches 18:00");
        }

        [Test]
        public void ALargeInternalGapThatDoesNotContainTheSettlementWindowIsNotAJunction()
        {
            // A 127-minute gap like the known 2019-07-04 anomaly: 11:00-14:07 New York.
            Assert.That(SessionJunctionRule.IsJunction(
                Sessions.U(2019, 7, 4, 15, 0, 0), Sessions.U(2019, 7, 4, 17, 7, 0)), Is.False);
        }

        [Test]
        public void TheRuleFollowsDaylightSavingTransitionsInsteadOfFixedUtcTimes()
        {
            // Spring forward (2024-03-10): Friday's last quote is 16:59:59 EST = 21:59:59Z and the
            // next run starts 18:00:00 EDT = 22:00:00Z, one hour earlier in UTC than in winter.
            Assert.That(SessionJunctionRule.IsJunction(
                Sessions.U(2024, 3, 8, 21, 59, 59), Sessions.U(2024, 3, 10, 22, 0, 0)), Is.True);
            // Fall back (2024-11-03): Friday's last quote is 16:59:59 EDT = 20:59:59Z and the
            // next run starts 18:00:00 EST = 23:00:00Z.
            Assert.That(SessionJunctionRule.IsJunction(
                Sessions.U(2024, 11, 1, 20, 59, 59), Sessions.U(2024, 11, 3, 23, 0, 0)), Is.True);
            // The same UTC hour is not a junction when it does not bracket the New York interval.
            Assert.That(SessionJunctionRule.IsJunction(
                Sessions.U(2024, 3, 10, 21, 0, 0), Sessions.U(2024, 3, 10, 22, 0, 0)), Is.False);
        }

        [Test]
        public void AShortenedSessionEndingAt1300NewYorkIsStillSeparatedByTheJunction()
        {
            // 2024-11-28 18:00:00Z = 13:00 EST (early close); 23:00:00Z = 18:00 EST (reopen).
            Assert.That(SessionJunctionRule.IsJunction(
                Sessions.U(2024, 11, 28, 18, 0, 0), Sessions.U(2024, 11, 28, 23, 0, 0)), Is.True);
        }
    }

    [TestFixture]
    public class HistoricalSessionMapTests
    {
        [Test]
        public void DerivationSplitsOnlyAtSettlementJunctionsAndLeavesTheFinalEndUnobservable()
        {
            // Run 1 ends 16:59:59 New York; run 2 starts 18:00 New York: one junction. Run 2 and
            // run 3 are junction-separated the same way. Run 1's first segment is followed by an
            // internal 10-hour hole (14:00Z is 09:00 New York) that must not split it.
            var segments = new[]
            {
                new HistoricalSegment(Sessions.U(2024, 1, 2, 0, 0, 0), Sessions.U(2024, 1, 2, 12, 0, 0)),
                new HistoricalSegment(Sessions.U(2024, 1, 2, 14, 0, 0), Sessions.U(2024, 1, 2, 21, 59, 59)),
                new HistoricalSegment(Sessions.U(2024, 1, 2, 23, 0, 0), Sessions.U(2024, 1, 3, 21, 59, 59)),
                new HistoricalSegment(Sessions.U(2024, 1, 3, 23, 0, 0), Sessions.U(2024, 1, 4, 21, 59, 59))
            };

            var map = HistoricalSessionMap.Derive(segments);

            Assert.That(map.Sessions, Has.Count.EqualTo(3));
            Assert.That(map.Sessions[0]!.Start, Is.EqualTo(Sessions.U(2024, 1, 2, 0, 0, 0)));
            Assert.That(map.Sessions[0]!.End, Is.EqualTo(Sessions.U(2024, 1, 2, 21, 59, 59)));
            Assert.That(map.Sessions[1]!.Start, Is.EqualTo(Sessions.U(2024, 1, 2, 23, 0, 0)));
            Assert.That(map.Sessions[1]!.End, Is.EqualTo(Sessions.U(2024, 1, 3, 21, 59, 59)));
            Assert.That(map.Sessions[2]!.Start, Is.EqualTo(Sessions.U(2024, 1, 3, 23, 0, 0)));
            Assert.That(map.Sessions[2]!.End, Is.Null, "the dataset cannot prove the final close");
        }

        [Test]
        public void DeriveRefusesUnorderedOrOverlappingSegments()
        {
            var outOfOrder = new[]
            {
                new HistoricalSegment(Sessions.U(2024, 1, 2, 10, 0, 0), Sessions.U(2024, 1, 2, 12, 0, 0)),
                new HistoricalSegment(Sessions.U(2024, 1, 2, 9, 0, 0), Sessions.U(2024, 1, 2, 9, 30, 0))
            };
            Assert.Throws<ArgumentException>(() => HistoricalSessionMap.Derive(outOfOrder));

            var overlapping = new[]
            {
                new HistoricalSegment(Sessions.U(2024, 1, 2, 10, 0, 0), Sessions.U(2024, 1, 2, 12, 0, 0)),
                new HistoricalSegment(Sessions.U(2024, 1, 2, 11, 0, 0), Sessions.U(2024, 1, 2, 13, 0, 0))
            };
            Assert.Throws<ArgumentException>(() => HistoricalSessionMap.Derive(overlapping));
        }

        [Test]
        public void ASessionCanSpanAMonthBoundary()
        {
            // 2024-01-31 23:59:59Z = 18:59:59 New York and 2024-02-01 00:00:00Z is one second
            // later: no junction, so the run continues across the month file boundary. A following
            // run after the 2024-02-01 New York settlement makes the month-spanning session end
            // observable.
            var segments = new[]
            {
                new HistoricalSegment(Sessions.U(2024, 1, 31, 23, 0, 0), Sessions.U(2024, 1, 31, 23, 59, 59)),
                new HistoricalSegment(Sessions.U(2024, 2, 1, 0, 0, 0), Sessions.U(2024, 2, 1, 21, 59, 59)),
                new HistoricalSegment(Sessions.U(2024, 2, 1, 23, 0, 0), Sessions.U(2024, 2, 2, 21, 59, 59))
            };

            var map = HistoricalSessionMap.Derive(segments);

            Assert.That(map.Sessions, Has.Count.EqualTo(2));
            Assert.That(map.Sessions[0]!.Start, Is.EqualTo(Sessions.U(2024, 1, 31, 23, 0, 0)));
            Assert.That(map.Sessions[0]!.End, Is.EqualTo(Sessions.U(2024, 2, 1, 21, 59, 59)));
        }

        [Test]
        public void AMapRoundTripsThroughItsFileContractWithProvenance()
        {
            var directory = Path.Combine(Path.GetTempPath(), "marketlab-session-map-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "xauusd-sessions.json");
            try
            {
                var first = Sessions.U(2024, 1, 2, 0, 0, 0);
                var last = Sessions.U(2024, 1, 3, 21, 59, 59);
                var map = HistoricalSessionMap.Derive(
                    new[]
                    {
                        new HistoricalSegment(first, Sessions.U(2024, 1, 2, 21, 59, 59)),
                        new HistoricalSegment(Sessions.U(2024, 1, 2, 23, 0, 0), last)
                    },
                    source: Sessions.Source(first, last));
                map.Save(path);

                var loaded = HistoricalSessionMap.Load(path);

                Assert.That(loaded.Symbol, Is.EqualTo("XAUUSD"));
                Assert.That(loaded.JunctionTimeZone, Is.EqualTo("America/New_York"));
                Assert.That(loaded.Sessions, Has.Count.EqualTo(2));
                Assert.That(loaded.Sessions[0]!.Start, Is.EqualTo(map.Sessions[0]!.Start));
                Assert.That(loaded.Sessions[0]!.End, Is.EqualTo(map.Sessions[0]!.End));
                Assert.That(loaded.Sessions[1]!.Start, Is.EqualTo(map.Sessions[1]!.Start));
                Assert.That(loaded.Sessions[1]!.End, Is.Null);
                Assert.That(loaded.Source!.FileCount, Is.EqualTo(90));
                Assert.That(loaded.Source.RowCount, Is.EqualTo(413750130));
                Assert.That(loaded.Source.Sha256Aggregate, Is.EqualTo(new string('a', 64)));
                Assert.That(loaded.Source.FirstQuoteUtc, Is.EqualTo(first));
                Assert.That(loaded.Source.LastQuoteUtc, Is.EqualTo(last));

                var rules = loaded.ToAvailability(DateTimeZone.Utc);
                Assert.That(rules.CoverageEnd, Is.EqualTo(last), "the coverage end survives the file round trip");
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        [Test]
        public void ACompletedSessionShorterThanTheTwoBuffersIsRefused()
        {
            var shortSession = Sessions.Window(Sessions.U(2024, 1, 2, 0, 0, 0), Sessions.U(2024, 1, 2, 0, 8, 0));

            var mapError = Assert.Throws<ArgumentException>(() => new HistoricalSessionMap(
                "XAUUSD", SessionJunctionRule.TimeZoneId, new[] { shortSession },
                Sessions.Source(Sessions.U(2024, 1, 2, 0, 0, 0), Sessions.U(2024, 1, 2, 0, 8, 0))));
            Assert.That(mapError!.Message, Does.Contain("shorter than ten minutes"));

            var availabilityError = Assert.Throws<ArgumentException>(() =>
                new HistoricalTradingAvailability(new[] { shortSession }));
            Assert.That(availabilityError!.Message, Does.Contain("shorter than ten minutes"));
        }

        [Test]
        public void SavingAMapWithoutSourceProvenanceIsRefused()
        {
            var path = Path.Combine(Path.GetTempPath(), "marketlab-session-map-" + Guid.NewGuid().ToString("N") + ".json");
            var map = HistoricalSessionMap.Derive(new[]
            {
                new HistoricalSegment(Sessions.U(2024, 1, 2, 0, 0, 0), Sessions.U(2024, 1, 2, 21, 59, 59))
            });

            Assert.Throws<InvalidOperationException>(() => map.Save(path));
            Assert.That(File.Exists(path), Is.False, "nothing is written for a map that could not be loaded again");
        }

        [Test]
        public void AMapWithAJunctionZoneOtherThanTheV1RuleIsRefused()
        {
            var error = Assert.Throws<ArgumentException>(() => new HistoricalSessionMap(
                "XAUUSD", "UTC",
                new[] { Sessions.Window(Sessions.U(2024, 1, 2, 0, 0, 0), Sessions.U(2024, 1, 2, 2, 0, 0)) }));

            Assert.That(error!.Message, Does.Contain("America/New_York"));
        }

        [Test]
        public void AMalformedOrIncompleteMapFileIsRefused()
        {
            var directory = Path.Combine(Path.GetTempPath(), "marketlab-session-map-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "bad.json");
            var first = Sessions.U(2024, 1, 2, 0, 0, 0);
            var last = Sessions.U(2024, 1, 3, 21, 59, 59);
            try
            {
                File.WriteAllText(path, "{\"contract\":\"wrong\"}");
                Assert.Throws<InvalidDataException>(() => HistoricalSessionMap.Load(path));

                File.WriteAllText(path, $"{{" +
                    $"\"contract\":\"{HistoricalSessionMap.Contract}\"," +
                    $"\"symbol\":\"XAUUSD\"," +
                    $"\"junctionTimeZone\":\"America/New_York\"," +
                    $"\"junctionRule\":\"a different rule\"," +
                    $"\"sessions\":[{{\"startUtc\":\"2024-01-02T00:00:00.000Z\",\"endUtc\":null}}]}}");
                Assert.Throws<InvalidDataException>(() => HistoricalSessionMap.Load(path),
                    "a map with a different junction rule must be refused even with the same contract");

                File.WriteAllText(path, $"{{" +
                    $"\"contract\":\"{HistoricalSessionMap.Contract}\"," +
                    $"\"symbol\":\"XAUUSD\"," +
                    $"\"junctionTimeZone\":\"America/New_York\"," +
                    $"\"junctionRule\":\"{HistoricalSessionMap.JunctionRuleText}\"," +
                    $"\"sessions\":[{{\"startUtc\":\"2024-01-02T00:00:00.000Z\",\"endUtc\":null}}]}}");
                Assert.Throws<InvalidDataException>(() => HistoricalSessionMap.Load(path),
                    "production map files must carry source provenance");

                File.WriteAllText(path, $"{{" +
                    $"\"contract\":\"{HistoricalSessionMap.Contract}\"," +
                    $"\"symbol\":\"XAUUSD\"," +
                    $"\"junctionTimeZone\":\"America/New_York\"," +
                    $"\"junctionRule\":\"{HistoricalSessionMap.JunctionRuleText}\"," +
                    $"\"source\":{{\"fileCount\":90,\"rowCount\":413750130,\"sha256Aggregate\":\"nothex\"," +
                    $"\"firstQuoteUtc\":\"2024-01-02T00:00:00.000Z\",\"lastQuoteUtc\":\"2024-01-03T21:59:59.000Z\"}}," +
                    $"\"sessions\":[{{\"startUtc\":\"2024-01-02T00:00:00.000Z\",\"endUtc\":null}}]}}");
                Assert.Throws<InvalidDataException>(() => HistoricalSessionMap.Load(path),
                    "a malformed source aggregate hash must be refused");

                File.WriteAllText(path, $"{{" +
                    $"\"contract\":\"{HistoricalSessionMap.Contract}\"," +
                    $"\"symbol\":\"XAUUSD\"," +
                    $"\"junctionTimeZone\":\"America/New_York\"," +
                    $"\"junctionRule\":\"{HistoricalSessionMap.JunctionRuleText}\"," +
                    $"\"source\":{{\"fileCount\":1,\"rowCount\":2,\"sha256Aggregate\":\"{new string('a', 64)}\"," +
                    $"\"firstQuoteUtc\":\"2024-01-02T00:00:01.000Z\",\"lastQuoteUtc\":\"2024-01-02T01:00:00.000Z\"}}," +
                    $"\"sessions\":[{{\"startUtc\":\"2024-01-02T00:00:00.000Z\",\"endUtc\":\"2024-01-02T00:30:00.000Z\"}}]}}");
                Assert.Throws<InvalidDataException>(() => HistoricalSessionMap.Load(path),
                    "the first session must start at the source's first observed quote");

                File.WriteAllText(path, $"{{" +
                    $"\"contract\":\"{HistoricalSessionMap.Contract}\"," +
                    $"\"symbol\":\"XAUUSD\"," +
                    $"\"junctionTimeZone\":\"America/New_York\"," +
                    $"\"junctionRule\":\"{HistoricalSessionMap.JunctionRuleText}\"," +
                    $"\"source\":{{\"fileCount\":1,\"rowCount\":2,\"sha256Aggregate\":\"{new string('a', 64)}\"," +
                    $"\"firstQuoteUtc\":\"2024-01-02T00:00:00.000Z\",\"lastQuoteUtc\":\"2024-01-03T21:59:59.000Z\"}}," +
                    $"\"sessions\":[" +
                    $"{{\"startUtc\":\"2024-01-02T00:00:00.000Z\",\"endUtc\":null}}," +
                    $"{{\"startUtc\":\"2024-01-03T00:00:00.000Z\",\"endUtc\":null}}]}}");
                Assert.Throws<InvalidDataException>(() => HistoricalSessionMap.Load(path),
                    "only the final session may have no observable end");

                File.WriteAllText(path, $"{{" +
                    $"\"contract\":\"{HistoricalSessionMap.Contract}\"," +
                    $"\"symbol\":\"XAUUSD\"," +
                    $"\"junctionTimeZone\":\"America/New_York\"," +
                    $"\"junctionRule\":\"{HistoricalSessionMap.JunctionRuleText}\"," +
                    $"\"source\":{{\"fileCount\":1,\"rowCount\":2,\"sha256Aggregate\":\"{new string('a', 64)}\"," +
                    $"\"firstQuoteUtc\":\"2024-01-02T00:00:00.000Z\",\"lastQuoteUtc\":\"2024-01-02T02:00:00.000Z\"}}," +
                    $"\"sessions\":[" +
                    $"{{\"startUtc\":\"2024-01-02T00:00:00.000Z\",\"endUtc\":\"2024-01-02T01:00:00.000Z\"}}," +
                    $"{{\"startUtc\":\"2024-01-02T01:30:00.000Z\",\"endUtc\":\"2024-01-02T02:00:00.000Z\"}}]}}");
                Assert.Throws<InvalidDataException>(() => HistoricalSessionMap.Load(path),
                    "adjacent sessions must be separated by the declared junction rule, not an arbitrary intraday gap");

                File.WriteAllText(path, $"{{" +
                    $"\"contract\":\"{HistoricalSessionMap.Contract}\"," +
                    $"\"symbol\":\"XAUUSD\"," +
                    $"\"junctionTimeZone\":\"America/New_York\"," +
                    $"\"junctionRule\":\"{HistoricalSessionMap.JunctionRuleText}\"," +
                    $"\"source\":{{\"fileCount\":1,\"rowCount\":2,\"sha256Aggregate\":\"{new string('a', 64)}\"," +
                    $"\"firstQuoteUtc\":\"2024-01-02T00:00:00.000Z\",\"lastQuoteUtc\":\"2024-01-02T02:00:00.000Z\"}}," +
                    $"\"sessions\":[{{\"startUtc\":\"2024-01-02T00:00:00.000Z\",\"endUtc\":\"2024-01-02T01:00:00.000Z\"}}]}}");
                Assert.Throws<InvalidDataException>(() => HistoricalSessionMap.Load(path),
                    "a source quote after the final session's observed end belongs to no session");
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }
    }

    [TestFixture]
    public class SessionMapStatsTests
    {
        [Test]
        public void OverallAndCompleteSessionPercentagesUseTheirOwnNumerator()
        {
            var map = new HistoricalSessionMap(
                "XAUUSD", SessionJunctionRule.TimeZoneId,
                new[]
                {
                    Sessions.Window(Sessions.U(2024, 1, 2, 0, 0, 0), Sessions.U(2024, 1, 2, 21, 59, 59)),
                    Sessions.Window(Sessions.U(2024, 1, 2, 23, 0, 0), null)
                },
                Sessions.Source(Sessions.U(2024, 1, 2, 0, 0, 0), Sessions.U(2024, 1, 3, 2, 0, 0)));

            var stats = SessionMapStats.Compute(map, new long[] { 10, 5 }, new long[] { 3, 0 }, 100);

            Assert.That(stats.Sessions, Is.EqualTo(2));
            Assert.That(stats.Junctions, Is.EqualTo(1));
            Assert.That(stats.CompleteSessions, Is.EqualTo(1));
            Assert.That(stats.QuoteOnlyRows, Is.EqualTo(18), "all sessions: 10 + 3 + 5 opening + 0 closing");
            Assert.That(stats.CompleteSessionQuoteOnlyRows, Is.EqualTo(13), "complete sessions only: 10 + 3");
            Assert.That(stats.FinalSessionOpenBufferRows, Is.EqualTo(5));
            Assert.That(stats.TradableRows, Is.EqualTo(82));
            Assert.That(stats.QuoteOnlyPercentOfSourceRows, Is.EqualTo(18d));
            Assert.That(stats.CompleteSessionQuoteOnlyPercentOfSourceRows, Is.EqualTo(13d));
        }
    }

    [TestFixture]
    public class QuoteOnlyBufferEngineTests
    {
        [Test]
        public void AQuoteOnlyQuoteDoesNotAnchorAndTheFirstTradableQuoteUsesItsOwnPrices()
        {
            var h = new Harness(null, Sessions.TwoSessions());

            h.FeedAt(Sessions.S0.AddMinutes(1), 1999.9m, 2000.1m);

            Assert.That(h.Engine.Basket, Is.Null, "no basket is anchored from a quote-only quote");
            Assert.That(h.AnchorsCreated, Is.Empty);
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(1), "the delivered quote is still counted");
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(1));
            Assert.That(h.Engine.StrategyEligibleQuotes, Is.EqualTo(0));

            h.FeedAt(Sessions.S0.AddMinutes(5), 1899.9m, 1900.1m);

            Assert.That(h.Engine.Basket, Is.Not.Null);
            Assert.That(h.Engine.Basket!.Anchor, Is.EqualTo(1900m), "the anchor comes from the tradable quote");
            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(1));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(2), "every legitimate quote stays in the delivery count");
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(1));
            Assert.That(h.Engine.StrategyEligibleQuotes, Is.EqualTo(1));
        }

        [Test]
        public void AnEntryTriggerInsideTheOpeningBufferIsSuppressedAndStillFiresOnTheFirstTradableQuote()
        {
            var h = new Harness(Harness.NoExits(), Sessions.TwoSessions());
            h.FeedAt(Sessions.S0.AddMinutes(5), 1999.9m, 2000.1m);          // anchors at 2000, tradable

            h.FeedAt(Sessions.S1.AddMinutes(1), 2019.8m, 2020m);            // quote-only: Ask >= Upper

            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0), "no leg is opened on a quote-only quote");
            Assert.That(h.EntriesOpened, Is.Empty);
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(0));

            h.FeedAt(Sessions.S1.AddMinutes(5), 2019.8m, 2020m);            // first tradable quote, same trigger

            Assert.That(h.EntriesOpened, Has.Count.EqualTo(1));
            Assert.That(h.Engine.Basket!.Legs[0].QuoteSequence, Is.EqualTo(3));
            Assert.That(h.Engine.Basket!.Legs[0].TriggerQuote.Ask, Is.EqualTo(2020m));
            Assert.That(h.Engine.Basket!.Legs[0].EntryPrice, Is.EqualTo(2020m));
        }

        [Test]
        public void AnEntryTriggerThatDisappearsBeforeTheOpeningBufferEndsNeverFires()
        {
            var h = new Harness(Harness.NoExits(), Sessions.TwoSessions());
            h.FeedAt(Sessions.S0.AddMinutes(5), 1999.9m, 2000.1m);          // anchors at 2000
            h.FeedAt(Sessions.S1.AddMinutes(1), 2019.8m, 2020m);            // quote-only trigger
            h.FeedAt(Sessions.S1.AddMinutes(5), 1999.8m, 2000m);            // back inside: nothing queued

            Assert.That(h.EntriesOpened, Is.Empty);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(0));
        }

        [Test]
        public void AnExitConditionInsideTheClosingBufferIsSuppressedAndReEvaluatedOnTheNextTradableQuote()
        {
            var h = new Harness(null, Sessions.TwoSessions());
            h.FeedAt(Sessions.S0.AddMinutes(5), 1999.9m, 2000.1m);          // anchor 2000
            h.FeedAt(Sessions.S0.AddMinutes(6), 2019.8m, 2020m);            // BUY 0.01
            h.FeedAt(Sessions.S0.AddMinutes(7), 1980m, 1980.2m);            // SELL 0.02
            var basket = h.Engine.Basket!;

            h.FeedAt(Sessions.S0End.AddMinutes(-1), 1900m, 1900.2m);        // escape condition in the closing buffer

            Assert.That(h.BasketsClosed, Is.Empty, "no close on a quote-only quote");
            Assert.That(h.Engine.Basket, Is.SameAs(basket));
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(1));

            h.FeedAt(Sessions.S1.AddMinutes(1), 1900m, 1900.2m);            // the next session's opening buffer

            Assert.That(h.BasketsClosed, Is.Empty);
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(2));

            h.FeedAt(Sessions.S1.AddMinutes(5), 2000m, 2000.2m);            // first tradable quote, condition gone

            Assert.That(h.BasketsClosed, Is.Empty, "the missed opportunity is not replayed");

            h.FeedAt(Sessions.S1.AddMinutes(6), 1900m, 1900.2m);            // tradable quote with the condition again

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.Escape));
        }

        [Test]
        public void TrailingNeitherActivatesNorAdvancesItsPeakOnAQuoteOnlyQuote()
        {
            var p = Harness.NoExits() with
            {
                TrailingEnabled = true,
                TrailingActivationUnits = 0.05m,
                TrailingDropUnits = 0.025m
            };
            var h = new Harness(p, Sessions.TwoSessions());
            h.FeedAt(Sessions.S0.AddMinutes(5), 1999.9m, 2000.1m);          // anchor 2000
            h.FeedAt(Sessions.S0.AddMinutes(6), 2019.8m, 2020m);            // BUY 0.01 at 2020
            var basket = h.Engine.Basket!;

            h.FeedAt(Sessions.S0End.AddMinutes(-1), 2200m, 2200.2m);        // +180 in the closing buffer

            Assert.That(h.TrailingActivations, Is.Empty);
            Assert.That(basket.TrailingActive, Is.False);
            Assert.That(basket.PeakProfit, Is.EqualTo(0m), "the peak is not advanced by a quote-only quote");
            Assert.That(h.BasketsClosed, Is.Empty);

            h.FeedAt(Sessions.S1.AddMinutes(5), 2200m, 2200.2m);            // first tradable quote activates trailing

            Assert.That(h.TrailingActivations, Has.Count.EqualTo(1));
            Assert.That(basket.TrailingActive, Is.True);
            Assert.That(basket.PeakProfit, Is.EqualTo(180m));

            h.FeedAt(Sessions.S1.AddMinutes(6), 2100m, 2100.2m);            // below the floor: trailing closes

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.Reason, Is.EqualTo(ExitReason.Trailing));
        }

        [Test]
        public void ARejectedEntryAttemptIsOnlyRecordedOnAStrategyEligibleQuote()
        {
            var p = Harness.NoExits() with { BaseLot = 0.05m, MaximumVolume = 0.01m };
            var h = new Harness(p, Sessions.TwoSessions());
            h.FeedAt(Sessions.S0.AddMinutes(5), 1999.9m, 2000.1m);          // anchor 2000

            h.FeedAt(Sessions.S1.AddMinutes(1), 2019.8m, 2020m);            // quote-only trigger, would reject

            Assert.That(h.Engine.Basket!.Rejections, Is.Empty);
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(0));
            Assert.That(h.EntriesRejected, Is.Empty);

            h.FeedAt(Sessions.S1.AddMinutes(5), 2019.8m, 2020m);            // first tradable quote

            Assert.That(h.Engine.Basket!.Rejections, Has.Count.EqualTo(1));
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(1));
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(1), "the buffer quote is still accounted for");
        }

        [Test]
        public void AReversalThresholdCrossingInsideABufferDoesNotAdvanceTheGrid()
        {
            var h = new Harness(Harness.NoExits(), Sessions.TwoSessions());
            h.FeedAt(Sessions.S0.AddMinutes(5), 1999.9m, 2000.1m);          // anchor 2000, tradable
            h.FeedAt(Sessions.S0.AddMinutes(6), 2019.8m, 2020m);            // BUY 0.01 at 2020
            var basket = h.Engine.Basket!;
            Assert.That(basket.NextTradeNumber, Is.EqualTo(2));
            Assert.That(basket.NextRequiredSide, Is.EqualTo(TradeSide.Sell));

            // The opposite (lower) grid level is crossed inside the closing buffer: the strictly
            // alternating reversal leg must not be added and the sequence must not advance.
            h.FeedAt(Sessions.S0End.AddMinutes(-1), 1980m, 1980.2m);
            Assert.That(basket.Legs, Has.Count.EqualTo(1), "no reversal leg on a quote-only quote");
            Assert.That(basket.NextTradeNumber, Is.EqualTo(2), "the sequence does not advance");

            // ... and again inside the next session's opening buffer.
            h.FeedAt(Sessions.S1.AddMinutes(1), 1980m, 1980.2m);
            Assert.That(basket.Legs, Has.Count.EqualTo(1));
            Assert.That(basket.NextTradeNumber, Is.EqualTo(2));
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(2));

            // First eligible quote: the crossing is gone, so the missed opportunity is not replayed.
            h.FeedAt(Sessions.S1.AddMinutes(5), 1999.9m, 2000.1m);
            Assert.That(basket.Legs, Has.Count.EqualTo(1));

            // A later eligible quote that crosses the level fresh adds the alternating leg.
            h.FeedAt(Sessions.S1.AddMinutes(6), 1980m, 1980.2m);
            Assert.That(basket.Legs, Has.Count.EqualTo(2));
            Assert.That(basket.Legs[1].Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(basket.Legs[1].Lots, Is.EqualTo(0.02m));
            Assert.That(basket.NextTradeNumber, Is.EqualTo(3));
        }

        [Test]
        public void WithoutAnAvailabilityMapEveryDeliveredQuoteIsStrategyEligible()
        {
            var h = new Harness(Harness.NoExits());
            h.FeedAt(Sessions.S0.AddMinutes(1), 1999.9m, 2000.1m);
            h.FeedAt(Sessions.S0.AddMinutes(2), 2019.8m, 2020m);

            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(2));
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(0));
            Assert.That(h.Engine.StrategyEligibleQuotes, Is.EqualTo(2));
            Assert.That(h.Engine.Basket!.Legs, Has.Count.EqualTo(1));
        }

        [Test]
        public void AQuoteAfterTheSourceCoverageEndIsAStructuredRunFailure()
        {
            var coverageEnd = Sessions.S0.AddHours(2);
            var h = new Harness(Harness.NoExits(), Sessions.Coverage(coverageEnd, Sessions.Window(Sessions.S0, null)));
            h.FeedAt(Sessions.S0.AddMinutes(6), 1999.9m, 2000.1m);          // anchors, tradable

            var failure = Assert.Throws<SessionMapException>(() =>
                h.FeedAt(coverageEnd.AddMilliseconds(1), 1999.9m, 2000.1m))!;

            Assert.That(failure.Kind, Is.EqualTo("SessionMap"));
            Assert.That(failure.Condition, Is.EqualTo("QuoteOutsideMapCoverage"));
            Assert.That(h.Engine.Faulted, Is.True);
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(1), "the out-of-coverage quote is not counted");
            Assert.That(h.Engine.LastProcessedQuote!.Value.Time, Is.EqualTo(Sessions.S0.AddMinutes(6)));
            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(0));

            Assert.Throws<SessionMapException>(() => h.FeedAt(coverageEnd.AddMinutes(30), 1999.9m, 2000.1m));
        }
    }

    [TestFixture]
    public class SessionMapGeneratorTests
    {
        [Test]
        public void TheGeneratorRefusesANonXauusdSource()
        {
            var directory = Path.Combine(Path.GetTempPath(), "marketlab-session-map-gen-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            var foreignSource = Path.Combine(directory, "EURUSD_2024_01_DUKASCOPY_JFOREX_FULL.csv");
            var foreignMap = Path.Combine(directory, "foreign-map.json");
            var otherProvider = Path.Combine(directory, "XAUUSD_2024_01_OTHER_FEED_FULL.csv");
            var otherMap = Path.Combine(directory, "other-map.json");
            try
            {
                File.WriteAllText(foreignSource,
                    "timestamp,bid,ask,bidVolume,askVolume\n" +
                    "2024-01-02T21:59:00.000Z,1.1000,1.1002,1,1\n" +
                    "2024-01-02T21:59:59.000Z,1.1000,1.1002,1,1\n" +
                    "2024-01-02T23:00:00.000Z,1.1000,1.1002,1,1\n");

                Assert.Throws<InvalidDataException>(
                    () => MarketLab.SessionMapTool.Program.Run(new[] { "--source", directory, "--out", foreignMap }),
                    "the junction rule is XAUUSD-specific; another instrument must be refused, not relabeled");
                Assert.That(File.Exists(foreignMap), Is.False);

                File.Delete(foreignSource);
                File.WriteAllText(otherProvider,
                    "timestamp,bid,ask,bidVolume,askVolume\n" +
                    "2024-01-02T21:59:00.000Z,2000.0,2000.5,1,1\n" +
                    "2024-01-02T21:59:59.000Z,2000.0,2000.5,1,1\n" +
                    "2024-01-02T23:00:00.000Z,2000.0,2000.5,1,1\n");

                Assert.Throws<InvalidDataException>(
                    () => MarketLab.SessionMapTool.Program.Run(new[] { "--source", directory, "--out", otherMap }),
                    "only the expected Dukascopy/JForex XAUUSD monthly file form is accepted");
                Assert.That(File.Exists(otherMap), Is.False);
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }

        [Test]
        public void TheGeneratorRefusesARowThatIsNotALegitimateQuote()
        {
            var directory = Path.Combine(Path.GetTempPath(), "marketlab-session-map-gen-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(directory);
            var source = Path.Combine(directory, "XAUUSD_2024_01_DUKASCOPY_JFOREX_FULL.csv");
            var mapPath = Path.Combine(directory, "map.json");
            try
            {
                File.WriteAllText(source,
                    "timestamp,bid,ask,bidVolume,askVolume\n" +
                    "2024-01-02T21:59:59.000Z,2000.0,1999.0,1,1\n");

                Assert.Throws<InvalidDataException>(() => MarketLab.SessionMapTool.Program.Run(
                    new[] { "--source", directory, "--out", mapPath }));
                Assert.That(File.Exists(mapPath), Is.False, "nothing is published for an invalid source");
            }
            finally
            {
                Directory.Delete(directory, true);
            }
        }
    }
}
