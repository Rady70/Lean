using System;
using System.Collections.Generic;
using NUnit.Framework;
using QuantConnect;
using QuantConnect.Data.Market;

namespace MarketLab.SingleAnchor.Tests
{
    [TestFixture]
    public class ResearchExecutorTests
    {
        [Test]
        public void FillsUseExactlyTheSizingModel()
        {
            var p = Harness.Defaults() with { Slippage = 0.1m };
            var executor = new ResearchExecutor(p);
            var quote = new Quote(Harness.T0, 2019.8m, 2020m);

            var buy = executor.OpenPosition(new EntryOrder(1, TradeSide.Buy, 0.01m, quote, SizingRegime.Arithmetic, null));
            var sell = executor.OpenPosition(new EntryOrder(2, TradeSide.Sell, 0.02m, quote, SizingRegime.Arithmetic, null));
            Assert.That(buy.Succeeded, Is.True);
            Assert.That(buy.FillPrice, Is.EqualTo(2020.1m));
            Assert.That(buy.FillPrice, Is.EqualTo(BasketEconomics.ExecutableEntryPrice(TradeSide.Buy, quote, p)));
            Assert.That(sell.FillPrice, Is.EqualTo(2019.7m));

            var basket = new Basket(quote, p);
            var close = executor.CloseBasket(new CloseOrder(basket, ExitReason.Escape, quote));
            Assert.That(close.Succeeded, Is.True);
            Assert.That(close.BuyClosePrice, Is.EqualTo(2019.7m));
            Assert.That(close.SellClosePrice, Is.EqualTo(2020.1m));
        }

        [Test]
        public void EngineWithoutAnExplicitExecutorUsesTheResearchExecutor()
        {
            var engine = new SingleAnchorEngine(Harness.Defaults() with { Slippage = 0.05m });
            engine.OnQuote(new Quote(Harness.T0, 1999.9m, 2000.1m));
            engine.OnQuote(new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m));

            Assert.That(engine.Basket!.Legs[0].EntryPrice, Is.EqualTo(2020.05m));
        }
    }

    [TestFixture]
    public class RealizedResultTests
    {
        [Test]
        public void ClosedBasketRecordsTheDecisionAndTheRealizedExecutableResult()
        {
            var p = Harness.Defaults() with { Slippage = 0.1m, CommissionPerLot = 7m };
            var h = new Harness(p);
            var created = h.Anchor();
            h.AtUpper();                                  // BUY 0.01 @ 2020.1
            h.AtLower();                                  // SELL 0.02 @ 1979.9
            var basket = h.Engine.Basket!;
            Assert.That(basket.Legs[0].EntryPrice, Is.EqualTo(2020.1m));
            Assert.That(basket.Legs[1].EntryPrice, Is.EqualTo(1979.9m));

            var closing = h.Feed(1900m, 1900.2m);         // escape: exit profit 39.3 >= 1

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            var record = h.BasketsClosed[0].Record;
            Assert.That(record.Reason, Is.EqualTo(ExitReason.Escape));
            Assert.That(record.CreatedTime, Is.EqualTo(created.Time));
            Assert.That(record.ClosedTime, Is.EqualTo(closing.Time));
            Assert.That(record.Anchor, Is.EqualTo(2000m));
            Assert.That(record.Legs, Is.EqualTo(2));
            Assert.That(record.BuyLots, Is.EqualTo(0.01m));
            Assert.That(record.SellLots, Is.EqualTo(0.02m));
            Assert.That(record.GrossLots, Is.EqualTo(0.03m));
            Assert.That(record.NetLots, Is.EqualTo(-0.01m));
            Assert.That(record.RawProfit, Is.EqualTo((1900m - 2020.1m) * 1m + (1979.9m - 1900.2m) * 2m));
            Assert.That(record.ExitProfit, Is.EqualTo(39.3m));
            Assert.That(record.Threshold, Is.EqualTo(1m));
            Assert.That(record.BuyClosePrice, Is.EqualTo(1899.9m));
            Assert.That(record.SellClosePrice, Is.EqualTo(1900.3m));
            Assert.That(record.Swap, Is.EqualTo(0m));
            Assert.That(record.Commission, Is.EqualTo(0.21m));
            // (1899.9 - 2020.1) * 0.01 * 100 + (1979.9 - 1900.3) * 0.02 * 100 - 0.21
            Assert.That(record.RealizedProfit, Is.EqualTo(-120.2m + 159.2m - 0.21m));
            Assert.That(record.RealizedProfit, Is.EqualTo(38.79m));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(38.79m));
            Assert.That(h.Engine.ClosedBaskets, Has.Count.EqualTo(1));
            Assert.That(h.Engine.ClosedBaskets[0], Is.SameAs(record));
        }

        [Test]
        public void RealizedProfitAccumulatesAcrossBasketsAndIncludesSwap()
        {
            var h = new Harness(Harness.Defaults() with { BuySwapPerLotPerDay = -2m, TripleSwapDay = null });
            var tuesday = new DateTime(2024, 1, 2, 10, 0, 0);
            h.FeedAt(tuesday, 1999.9m, 2000.1m);
            h.FeedAt(tuesday.AddSeconds(1), 2019.8m, 2020m);          // BUY 0.01
            h.FeedAt(new DateTime(2024, 1, 2, 17, 0, 0), 2000m, 2000.2m); // rollover: -0.02
            h.FeedAt(new DateTime(2024, 1, 2, 18, 0, 0), 2035m, 2035.2m); // trailing active at 15 - 0.02
            h.FeedAt(new DateTime(2024, 1, 2, 18, 0, 1), 2025m, 2025.2m); // 4.98 <= 14.98 - 5: trailing close

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            var first = h.BasketsClosed[0].Record;
            Assert.That(first.Swap, Is.EqualTo(-0.02m));
            Assert.That(first.RealizedProfit, Is.EqualTo(5m - 0.02m));

            h.FeedAt(new DateTime(2024, 1, 2, 18, 0, 2), 1999.9m, 2000.1m);
            h.FeedAt(new DateTime(2024, 1, 2, 18, 0, 3), 2019.8m, 2020m);
            h.FeedAt(new DateTime(2024, 1, 2, 18, 0, 4), 2035m, 2035.2m);
            h.FeedAt(new DateTime(2024, 1, 2, 18, 0, 5), 2025m, 2025.2m);

            Assert.That(h.Engine.ClosedBaskets, Has.Count.EqualTo(2));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(4.98m + 5m));
        }

        [Test]
        public void MarkToMarketReportsTheExecutableValueOfAnOpenBasket()
        {
            var p = Harness.Defaults() with { Slippage = 0.1m, CommissionPerLot = 7m };
            var h = new Harness(p);
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            var quote = h.Feed(2000m, 2000.3m);

            var valuation = h.Engine.MarkToMarket(quote)!;
            // raw: (2000 - 2020.1) * 1 + (1979.9 - 2000.3) * 2 = -20.1 - 40.8
            Assert.That(valuation.RawProfit, Is.EqualTo(-60.9m));
            // executable: buys close 1999.9, sells close 2000.4, commission 0.21
            Assert.That(valuation.ExecutableProfit, Is.EqualTo((1999.9m - 2020.1m) * 1m + (1979.9m - 2000.4m) * 2m - 0.21m));
        }
    }

    [TestFixture]
    public class QuoteTickFeedTests
    {
        private static readonly Symbol Xauusd = Symbol.Create("XAUUSD", SecurityType.Cfd, Market.Oanda);

        [Test]
        public void EveryQuoteTickOfASliceReachesTheEngineInOrder()
        {
            var h = new Harness();
            var feed = new QuoteTickFeed();
            var t = Harness.T0;
            feed.Feed(new List<Tick> { new Tick(t, Xauusd, 1999.9m, 2000.1m) }, h.Engine);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));

            // the first tick of the slice crosses Upper, the last one is back below it
            var slice = new List<Tick>
            {
                new Tick(t.AddSeconds(1), Xauusd, 2019.8m, 2020m),
                new Tick(t.AddSeconds(1), Xauusd, 2019.5m, 2019.7m),
                new Tick(t.AddSeconds(1), Xauusd, 2019.0m, 2019.2m)
            };
            feed.Feed(slice, h.Engine);

            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(1), "the boundary crossed by the first tick is not missed");
            Assert.That(h.Engine.Basket!.Legs[0].EntryPrice, Is.EqualTo(2020m));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(4));
            Assert.That(feed.QuoteTicks, Is.EqualTo(4));
            Assert.That(feed.LastQuote!.Value.Ask, Is.EqualTo(2019.2m));
        }

        [Test]
        public void NonQuoteAndInvalidTicksAreCountedAndSkipped()
        {
            var h = new Harness();
            var feed = new QuoteTickFeed();
            var t = Harness.T0;
            var slice = new List<Tick>
            {
                new Tick(t, Xauusd, "", "", 1m, 2000m),           // a trade tick
                new Tick(t, Xauusd, 0m, 2000.1m),                  // invalid quote
                new Tick(t, Xauusd, 2000.2m, 2000.1m),             // crossed quote
                new Tick(t, Xauusd, 1999.9m, 2000.1m)              // the valid one
            };
            feed.Feed(slice, h.Engine);

            Assert.That(feed.NonQuoteTicks, Is.EqualTo(1));
            Assert.That(feed.InvalidQuoteTicks, Is.EqualTo(2));
            Assert.That(feed.QuoteTicks, Is.EqualTo(1));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(1));
            Assert.That(h.InvalidQuotes, Is.Empty, "invalid ticks never reach the engine");
            Assert.That(h.Engine.Basket!.Anchor, Is.EqualTo(2000m));
        }
    }
}
