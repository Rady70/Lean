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

            var basket = new Basket(1, quote, p);
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

            Assert.That(record.Sequence, Is.EqualTo(1));
            Assert.That(record.AnchorEvent.Basket, Is.EqualTo(1));
            Assert.That(record.AnchorEvent.QuoteSequence, Is.EqualTo(1));
            Assert.That(record.AnchorEvent.Time, Is.EqualTo(created.Time));
            Assert.That(record.AnchorEvent.Bid, Is.EqualTo(1999.9m));
            Assert.That(record.AnchorEvent.Ask, Is.EqualTo(2000.1m));
            Assert.That(record.AnchorEvent.Anchor, Is.EqualTo(2000m));
            Assert.That(record.AnchorEvent.UpperTarget, Is.EqualTo(2089.56m));
            Assert.That(record.RejectionTrace, Is.Empty);
            Assert.That(record.CloseQuoteSequence, Is.EqualTo(4), "anchor, upper, lower, close");
            Assert.That(record.CloseBid, Is.EqualTo(1900m));
            Assert.That(record.CloseAsk, Is.EqualTo(1900.2m));
            Assert.That(record.LegTrace, Has.Count.EqualTo(2));
            var first = record.LegTrace[0];
            Assert.That(first.Basket, Is.EqualTo(1));
            Assert.That(first.TradeNumber, Is.EqualTo(1));
            Assert.That(first.QuoteSequence, Is.EqualTo(2));
            Assert.That(first.DecisionBid, Is.EqualTo(2019.8m));
            Assert.That(first.DecisionAsk, Is.EqualTo(2020m));
            Assert.That(first.Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(first.FillPrice, Is.EqualTo(2020.1m));
            Assert.That(first.Regime, Is.EqualTo(SizingRegime.Arithmetic));
            Assert.That(first.HardBreakevenTarget, Is.Null);
            Assert.That(first.TargetSpread, Is.Null);
            Assert.That(record.LegTrace[1].Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(record.LegTrace[1].Lots, Is.EqualTo(0.02m));
            Assert.That(record.LegTrace[1].QuoteSequence, Is.EqualTo(3));
            Assert.That(record.LegTrace[1].DecisionBid, Is.EqualTo(1980m));
        }

        [Test]
        public void TailLegsCarryTheirSizingInTheTrace()
        {
            var h = new Harness();
            h.PingPongFourLegs();
            h.AtUpper();                                  // trade 5: BUY 0.06, hard-BE
            Assert.That(h.Engine.OpenBasketLegTrace(), Has.Count.EqualTo(5));
            h.Feed(2100m, 2100.2m);                       // escape close

            var trace = h.Engine.ClosedBaskets[0].LegTrace;
            Assert.That(trace, Has.Count.EqualTo(5));
            Assert.That(trace[3].Regime, Is.EqualTo(SizingRegime.Arithmetic));
            Assert.That(trace[3].RequiredLot, Is.Null);
            var tail = trace[4];
            Assert.That(tail.TradeNumber, Is.EqualTo(5));
            Assert.That(tail.Regime, Is.EqualTo(SizingRegime.HardBreakeven));
            Assert.That(tail.Lots, Is.EqualTo(0.06m));
            Assert.That(tail.HardBreakevenTarget, Is.EqualTo(2089.56m));
            Assert.That(tail.TargetSpread, Is.EqualTo(0.2m));
            Assert.That(tail.TargetBid, Is.EqualTo(2089.46m));
            Assert.That(tail.TargetAsk, Is.EqualTo(2089.66m));
            Assert.That(tail.QuoteSequence, Is.EqualTo(6));
            Assert.That(tail.DecisionAsk, Is.EqualTo(2020m));
            Assert.That(tail.ExistingProfitAtTarget, Is.EqualTo(-380.12m));
            Assert.That(tail.MarginalProfitPerLot, Is.EqualTo(6946m));
            Assert.That(tail.RequiredLot, Is.EqualTo(380.12m / 6946m));
            Assert.That(tail.ProjectedProfitAfter, Is.EqualTo(36.64m));
            Assert.That(h.Engine.OpenBasketLegTrace(), Is.Empty);
        }

        [Test]
        public void RejectedAttemptsArePersistedWithTheirSizingFiguresAndRepeatFlags()
        {
            var h = new Harness(Harness.Defaults() with { MaximumVolume = 0.05m });
            var basket = h.PingPongFourLegs();
            var first = h.AtUpper();                      // trade 5 needs 0.06 > 0.05: infeasible
            var second = h.AtUpper();                     // the same situation again
            var third = h.Feed(2060m, 2060.2m);           // a materially larger requirement: new situation

            var trace = basket.Rejections;
            Assert.That(trace, Has.Count.EqualTo(2), "one row per distinct situation, repeats counted on their row");
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(2), "two distinct situations were raised");
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(3));

            var row = trace[0];
            Assert.That(row.Basket, Is.EqualTo(1));
            Assert.That(row.FirstQuoteSequence, Is.EqualTo(6));
            Assert.That(row.FirstTime, Is.EqualTo(first.Time));
            Assert.That(row.FirstBid, Is.EqualTo(2019.8m));
            Assert.That(row.FirstAsk, Is.EqualTo(2020m));
            Assert.That(row.TradeNumber, Is.EqualTo(5));
            Assert.That(row.Side, Is.EqualTo(TradeSide.Buy));
            Assert.That(row.Reason, Is.EqualTo(EntryRejectionReason.HardBreakevenInfeasible));
            Assert.That(row.Outcome, Is.EqualTo(HardBreakevenOutcome.ExceedsMaximumVolume));
            Assert.That(row.RequestedLots, Is.EqualTo(380.12m / 6946m));
            Assert.That(row.NormalizedLot, Is.EqualTo(0m));
            Assert.That(row.HardBreakevenTarget, Is.EqualTo(2089.56m));
            Assert.That(row.TargetSpread, Is.EqualTo(0.2m));
            Assert.That(row.TargetBid, Is.EqualTo(2089.46m));
            Assert.That(row.TargetAsk, Is.EqualTo(2089.66m));
            Assert.That(row.ExistingProfitAtTarget, Is.EqualTo(-380.12m));
            Assert.That(row.MarginalProfitPerLot, Is.EqualTo(6946m));
            Assert.That(row.Attempts, Is.EqualTo(2), "the second AtUpper repeated the same situation");
            Assert.That(row.LastQuoteSequence, Is.EqualTo(7));
            Assert.That(row.LastTime, Is.EqualTo(second.Time));
            Assert.That(row.LastBid, Is.EqualTo(2019.8m));

            var changed = trace[1];
            Assert.That(changed.FirstQuoteSequence, Is.EqualTo(8));
            Assert.That(changed.FirstTime, Is.EqualTo(third.Time));
            Assert.That(changed.FirstAsk, Is.EqualTo(2060.2m));
            Assert.That(changed.MarginalProfitPerLot, Is.EqualTo(2926m));
            Assert.That(changed.RequestedLots, Is.GreaterThan(row.RequestedLots), "the required lot changed materially: a new row");
            Assert.That(changed.Attempts, Is.EqualTo(1));
            Assert.That(changed.LastQuoteSequence, Is.EqualTo(8));

            var snapshot = h.Engine.MarkToMarket(third)!;
            Assert.That(snapshot.RejectionTrace, Is.SameAs(trace));

            h.Feed(1898.4m, 1898.6m);                     // escape (M_step 40, threshold 2, profit 2)
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.RejectionTrace, Has.Count.EqualTo(2));
            Assert.That(h.BasketsClosed[0].Record.RejectionTrace[0].Attempts, Is.EqualTo(2));
        }

        [Test]
        public void APersistingRejectionStaysOneRowHoweverManyTicksRepeatIt()
        {
            var h = new Harness(Harness.NoExits() with { MaximumVolume = 0.05m });
            var basket = h.PingPongFourLegs();
            for (var i = 0; i < 500; i++)
            {
                h.AtUpper();
            }

            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(500));
            Assert.That(basket.Rejections, Has.Count.EqualTo(1));
            Assert.That(basket.Rejections[0].Attempts, Is.EqualTo(500));
            Assert.That(basket.Rejections[0].FirstQuoteSequence, Is.EqualTo(6));
            Assert.That(basket.Rejections[0].LastQuoteSequence, Is.EqualTo(505));
        }

        [Test]
        public void ArithmeticAndExecutionRejectionsAreTracedWithoutSizingFigures()
        {
            var h = new Harness(Harness.NoExits() with { BaseLot = 60m });
            h.Anchor();
            h.AtUpper();
            h.AtLower();                                  // trade 2 = 120 lots > 100: rejected

            var row = h.Engine.Basket!.Rejections[0];
            Assert.That(row.Reason, Is.EqualTo(EntryRejectionReason.VolumeExceedsMaximum));
            Assert.That(row.TradeNumber, Is.EqualTo(2));
            Assert.That(row.Side, Is.EqualTo(TradeSide.Sell));
            Assert.That(row.RequestedLots, Is.EqualTo(120m));
            Assert.That(row.Outcome, Is.Null);
            Assert.That(row.HardBreakevenTarget, Is.Null);
            Assert.That(row.Attempts, Is.EqualTo(1));
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

        [Test]
        public void MarkToMarketHasNoExecutableValueWhenSlippageMakesAClosePriceNonPositive()
        {
            var h = new Harness(Harness.NoExits() with { Slippage = 2100m });
            h.Anchor();
            h.AtUpper();                                  // BUY fills at 2020 + 2100 = 4120
            Assert.That(h.Engine.Basket!.Legs[0].EntryPrice, Is.EqualTo(4120m));

            var valuation = h.Engine.MarkToMarket(new Quote(Harness.T0.AddMinutes(1), 2019.8m, 2020m))!;

            Assert.That(valuation.RawProfit, Is.EqualTo((2019.8m - 4120m) * 1m));
            Assert.That(valuation.ExecutableProfit, Is.Null, "Bid - slippage is not a price");
        }

        [Test]
        public void MarkToMarketOfASellOnlyBasketIgnoresTheUnusedBuyClosePrice()
        {
            var h = new Harness(Harness.NoExits() with { Slippage = 2100m });
            h.Anchor();
            h.Engine.Basket!.AddLeg(new BasketLeg(1, TradeSide.Sell, 0.01m, 1980m, Harness.T0, SizingRegime.Arithmetic));

            var valuation = h.Engine.MarkToMarket(new Quote(Harness.T0.AddMinutes(1), 2019.8m, 2020m))!;

            // sells close at 2020 + 2100; the negative BUY close does not matter without BUY legs
            Assert.That(valuation.ExecutableProfit, Is.EqualTo((1980m - 4120m) * 0.01m * 100m));
        }

        [Test]
        public void ACloseReportingANonPositivePriceFailsExplicitlyAndIsRetried()
        {
            var h = TwoLegs.Build();
            var basket = h.Engine.Basket!;
            h.Executor.CloseOverride = _ => CloseExecution.Closed(0m, 1900.2m);

            h.Feed(1900m, 1900.2m);                       // escape fires, the executor's BUY close price is unusable

            Assert.That(h.BasketsClosed, Is.Empty);
            Assert.That(h.CloseFailures, Has.Count.EqualTo(1));
            Assert.That(h.CloseFailures[0].Message, Does.Contain("non-positive close prices"));
            Assert.That(h.Engine.Basket, Is.SameAs(basket));

            h.Executor.CloseOverride = null;
            h.Feed(1900m, 1900.2m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
        }
    }

    [TestFixture]
    public class HardBreakevenGuaranteeTests
    {
        [Test]
        public void ZeroSwapRunIsQualifiedAndStatesItsAssumptionsAndLimits()
        {
            var g = HardBreakevenGuarantee.For(Harness.Defaults());

            Assert.That(g.Qualified, Is.True);
            Assert.That(g.UnqualifiedReasons, Is.Empty);
            Assert.That(g.Scope, Does.Contain("once, immediately after each tail entry"));
            Assert.That(g.Assumptions, Has.Some.Contains("target spread 0.2"));
            Assert.That(g.Assumptions, Has.Some.Contains("pending owner approval"));
            Assert.That(g.NotCovered, Has.Some.Contains("wider than the configured target spread"));
            Assert.That(g.NotCovered, Has.Some.Contains("financing accrued after the entry"));
        }

        [Test]
        public void NonZeroSwapRunIsNotQualifiedAndSaysWhy()
        {
            var g = HardBreakevenGuarantee.For(Harness.Defaults() with { SellSwapPerLotPerDay = -1.5m });

            Assert.That(g.Qualified, Is.False);
            Assert.That(g.UnqualifiedReasons, Has.Count.EqualTo(1));
            Assert.That(g.UnqualifiedReasons[0], Does.Contain("Swap is configured"));
            Assert.That(g.UnqualifiedReasons[0], Does.Contain("not re-verified"));
            Assert.That(new Harness(Harness.Defaults() with { BuySwapPerLotPerDay = -2m }).Engine.HardBreakevenGuarantee.Qualified, Is.False);
            Assert.That(new Harness().Engine.HardBreakevenGuarantee.Qualified, Is.True);
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
            Assert.That(h.Engine.Basket!.Legs[0].QuoteSequence, Is.EqualTo(2));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(4));
            Assert.That(h.Engine.LastProcessedQuote!.Value.Ask, Is.EqualTo(2019.2m));
        }

        [Test]
        public void OutOfOrderQuoteTickIsADataQualityFailureTheHostCannotIgnore()
        {
            var h = new Harness();
            var feed = new QuoteTickFeed();
            var t = Harness.T0;
            feed.Feed(new List<Tick> { new Tick(t.AddSeconds(5), Xauusd, 1999.9m, 2000.1m) }, h.Engine);

            var failure = Assert.Throws<DataQualityException>(() =>
                feed.Feed(new List<Tick> { new Tick(t.AddSeconds(4), Xauusd, 2019.8m, 2020m) }, h.Engine))!;

            Assert.That(failure.Issue, Is.EqualTo(DataQualityIssue.OutOfOrderQuote));
            Assert.That(failure.Quote.Time, Is.EqualTo(t.AddSeconds(4)));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(1), "the refused quote was never processed");
            Assert.That(h.Engine.LastProcessedQuote!.Value.Time, Is.EqualTo(t.AddSeconds(5)));
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0), "nothing traded on the bad tick");
            Assert.That(h.Engine.Faulted, Is.True, "the engine itself is faulted at the lowest layer");

            // a host that swallowed the exception and kept feeding valid ticks could not continue:
            Assert.Throws<DataQualityException>(() =>
                feed.Feed(new List<Tick> { new Tick(t.AddSeconds(6), Xauusd, 2019.8m, 2020m) }, h.Engine));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(1));
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));
        }

        [Test]
        public void SameTimestampTicksAreInOrderAndUniquelySequenced()
        {
            var h = new Harness();
            var feed = new QuoteTickFeed();
            var t = Harness.T0;
            feed.Feed(new List<Tick> { new Tick(t, Xauusd, 1999.9m, 2000.1m), new Tick(t, Xauusd, 2019.8m, 2020m) }, h.Engine);

            var basket = h.Engine.Basket!;
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(2));
            Assert.That(basket.AnchorEvent.QuoteSequence, Is.EqualTo(1));
            Assert.That(basket.AnchorEvent.Time, Is.EqualTo(t));
            Assert.That(basket.Legs[0].QuoteSequence, Is.EqualTo(2));
            Assert.That(basket.Legs[0].EntryTime, Is.EqualTo(t), "identical timestamps; the sequence numbers tell the ticks apart");
        }

        [Test]
        public void AnInvariantFailurePropagatesThroughTheFeed()
        {
            var h = new Harness();
            var feed = new QuoteTickFeed();
            var t = Harness.T0;
            feed.Feed(new List<Tick> { new Tick(t, Xauusd, 1999.9m, 2000.1m) }, h.Engine);

            var fault = Assert.Throws<StrategyInvariantException>(() =>
                feed.Feed(new List<Tick> { new Tick(t.AddSeconds(1), Xauusd, 1979m, 2021m) }, h.Engine))!;

            Assert.That(fault.Invariant, Is.EqualTo(StrategyInvariant.BothBoundariesSatisfied));
            Assert.That(h.Engine.Faulted, Is.True);
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(2), "the faulting quote was processed");
            Assert.That(h.Engine.LastProcessedQuote!.Value.Time, Is.EqualTo(t.AddSeconds(1)));
            Assert.That(h.Engine.LastProcessedQuote, Is.EqualTo(h.Engine.Fault!.Quote), "one meaning of processed: the fault quote is the last processed quote");
        }

        [Test]
        public void NonQuoteTicksAreCountedAndUnused()
        {
            var h = new Harness();
            var feed = new QuoteTickFeed();
            var t = Harness.T0;
            var slice = new List<Tick>
            {
                new Tick(t, Xauusd, "", "", 1m, 2000m),           // a trade tick
                new Tick(t, Xauusd, 1999.9m, 2000.1m)              // the quote
            };
            feed.Feed(slice, h.Engine);

            Assert.That(feed.NonQuoteTicks, Is.EqualTo(1));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(1));
            Assert.That(h.Engine.Basket!.Anchor, Is.EqualTo(2000m));
        }

        [TestCase(0, 2000.1)]
        [TestCase(1999.9, 0)]
        [TestCase(2000.2, 2000.1)]
        public void InvalidQuoteTickIsADataQualityFailure(decimal bid, decimal ask)
        {
            var h = new Harness();
            var feed = new QuoteTickFeed();
            var t = Harness.T0;
            feed.Feed(new List<Tick> { new Tick(t, Xauusd, 1999.9m, 2000.1m) }, h.Engine);

            var failure = Assert.Throws<DataQualityException>(() =>
                feed.Feed(new List<Tick> { new Tick(t.AddSeconds(1), Xauusd, bid, ask) }, h.Engine))!;

            Assert.That(failure.Issue, Is.EqualTo(DataQualityIssue.InvalidQuote));
            Assert.That(failure.Quote.Bid, Is.EqualTo(bid));
            Assert.That(h.Engine.QuotesProcessed, Is.EqualTo(1), "the invalid tick was not processed");
            Assert.That(h.Engine.Faulted, Is.True);
        }
    }
}
