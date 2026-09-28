using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using NUnit.Framework;
using QuantConnect;
using QuantConnect.Configuration;
using QuantConnect.Data.Market;
using QuantConnect.Securities;

namespace MarketLab.SingleAnchor.Tests
{
    [TestFixture]
    [NonParallelizable]
    public class DeliveryAndHostWindowTests
    {
        [Test]
        public void ProductionRunWindowUsesTheFullUtcDatesWithoutRequestingJulyFirst()
        {
            var root = new DirectoryInfo(TestContext.CurrentContext.TestDirectory);
            while (root != null && !Directory.Exists(Path.Combine(root.FullName, "Launcher"))) root = root.Parent;
            Assert.That(root, Is.Not.Null);
            var previous = Config.Get("data-folder");
            Config.Set("data-folder", Path.Combine(root!.FullName, "Data"));
            Globals.Reset();
            try
            {
                var host = new SingleAnchorVNextAlgorithm();
                host.SetParameters(new Dictionary<string, string>
                {
                    ["single-anchor-start-date"] = "2019-01-01",
                    ["single-anchor-end-date"] = "2026-06-30",
                    ["single-anchor-step-percent"] = "0.25",
                    ["single-anchor-base-lot"] = "0.10",
                    ["single-anchor-projected-spread"] = "0.50"
                });
                host.ConfigureRunWindow(); // The production window method called by Initialize.
                Assert.That(host.TimeZone, Is.EqualTo(TimeZones.Utc));
                var start = host.StartDate.ConvertToUtc(host.TimeZone);
                var end = host.EndDate.ConvertToUtc(host.TimeZone);
                Assert.That(start, Is.EqualTo(new DateTime(2019, 1, 1, 0, 0, 0, DateTimeKind.Utc)));
                Assert.That(end, Is.EqualTo(new DateTime(2026, 7, 1, 0, 0, 0, DateTimeKind.Utc).AddTicks(-1)));
                var days = Time.EachTradeableDayInTimeZone(SecurityExchangeHours.AlwaysOpen(TimeZones.Utc), start, end, TimeZones.Utc).ToArray();
                Assert.That(days.Length, Is.EqualTo(2738));
                Assert.That(days[0], Is.EqualTo(new DateTime(2019, 1, 1)));
                Assert.That(days[^1], Is.EqualTo(new DateTime(2026, 6, 30)));
            }
            finally
            {
                Config.Set("data-folder", previous);
                Globals.Reset();
            }
        }

        [Test]
        public void DeliveryPreservesDuplicateOrderAndResetsOnlyPartitionOrdinals()
        {
            var time = new DateTime(2019, 1, 1, 23, 59, 59, 999, DateTimeKind.Utc);
            var delivery = new QuoteDelivery(TimeZones.Utc, TimeZones.Utc);
            delivery.Add(new Quote(time, 100.00m, 100.500m));
            delivery.Add(new Quote(time, 101m, 101.5m));
            delivery.Add(new Quote(time.AddMilliseconds(1), 102m, 102.5m));
            var result = delivery.Snapshot();
            const string first = "1|2019-01-01T23:59:59.999Z|100|100.5\n2|2019-01-01T23:59:59.999Z|101|101.5\n";
            Assert.That(result.QuoteCount, Is.EqualTo(3));
            Assert.That(result.SemanticDigest, Is.EqualTo(Digest(first + "3|2019-01-02T00:00:00.000Z|102|102.5\n")));
            Assert.That(result.PerPartition["2019-01-01"].SemanticDigest, Is.EqualTo(Digest(first)));
            Assert.That(result.PerPartition["2019-01-02"].SemanticDigest, Is.EqualTo(Digest("1|2019-01-02T00:00:00.000Z|102|102.5\n")));
            Assert.That(result.LastQuote!.Value.Time.Kind, Is.EqualTo(DateTimeKind.Utc));
            Assert.That(delivery.Snapshot(), Is.SameAs(result));
        }

        [Test]
        public void FeedIncludesTheStopOutQuoteButExcludesTheRestOfItsSlice()
        {
            var h = new Harness(Harness.Defaults(), null, 4.05m, Harness.MarginDefaults());
            var delivery = new QuoteDelivery(TimeZones.Utc, TimeZones.Utc);
            var symbol = Symbol.Create("XAUUSD", SecurityType.Cfd, Market.Oanda);
            Tick TickAt(int second, decimal bid, decimal ask) => new Tick
            {
                Symbol = symbol, TickType = TickType.Quote, Time = Harness.T0.AddSeconds(second), BidPrice = bid, AskPrice = ask
            };
            var feed = new QuoteTickFeed();
            Assert.Throws<AccountStopOutException>(() => feed.Feed(new[]
            {
                TickAt(0, 1999.9m, 2000.1m), TickAt(1, 2010m, 2020m), TickAt(2, 2000m, 2000.2m)
            }, h.Engine, delivery.Add));
            var result = delivery.Snapshot();
            Assert.That(result.QuoteCount, Is.EqualTo(2));
            Assert.That(result.QuoteCount, Is.EqualTo(h.Engine.QuotesProcessed));
            Assert.That(result.LastQuote!.Value.Time, Is.EqualTo(h.Engine.LastProcessedQuote!.Value.Time));
            Assert.That(result.LastQuote.Value.Bid, Is.EqualTo(2010m));
        }

        private static string Digest(string text) => "sha256:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
    }
}
