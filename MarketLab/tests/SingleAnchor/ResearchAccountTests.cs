using System;
using System.Collections.Generic;
using System.Text.Json;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    /// <summary>
    /// The research account definitions of roadmap section 3.11: Balance is the initial balance
    /// plus the engine's realized profit, FloatingPL is the executable basket mark-to-market
    /// (close-side slippage and round-trip commission included) and Equity = Balance + FloatingPL.
    /// The optional CommissionBuffer is an exit-decision input only.
    /// </summary>
    [TestFixture]
    public class ResearchAccountDefinitionTests
    {
        [Test]
        public void BalanceEquityAndFloatingFollowTheDefinitions()
        {
            var p = Harness.Defaults();
            var h = TwoLegs.Build(p, 1000m);
            var account = h.ResearchAccount!;
            var basket = h.Engine.Basket!;

            var quote = h.Feed(2000m, 2000.3m);
            var expectedFloating = BasketEconomics.ExecutableProfit(basket, quote.Bid, quote.Ask, p);
            Assert.That(expectedFloating, Is.EqualTo(-60.6m));
            Assert.That(account.RealizedProfit, Is.EqualTo(0m));
            Assert.That(account.Balance, Is.EqualTo(1000m), "no close has realized anything yet");
            Assert.That(account.FloatingProfit, Is.EqualTo(expectedFloating));
            Assert.That(account.Equity, Is.EqualTo(1000m + expectedFloating));

            h.Feed(1900m, 1900.2m); // escape closes the two-leg basket at 39.6
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(39.6m));
            Assert.That(account.RealizedProfit, Is.EqualTo(h.Engine.RealizedProfit));
            Assert.That(account.Balance, Is.EqualTo(1039.6m));
            Assert.That(account.FloatingProfit, Is.EqualTo(0m), "the basket is closed");
            Assert.That(account.Equity, Is.EqualTo(1039.6m));
        }

        [Test]
        public void CommissionBufferIsNotAnAccountLoss()
        {
            var p = Harness.Defaults() with { CommissionBuffer = 3m };
            var h = TwoLegs.Build(p, 1000m);
            var account = h.ResearchAccount!;
            var basket = h.Engine.Basket!;

            var quote = h.Feed(2000m, 2000.3m);
            var executable = BasketEconomics.ExecutableProfit(basket, quote.Bid, quote.Ask, p);
            Assert.That(BasketEconomics.ExitProfit(basket, quote, p), Is.EqualTo(executable - 3m));
            Assert.That(account.FloatingProfit, Is.EqualTo(executable), "the buffer is an exit threshold, never an account loss");
            Assert.That(account.Equity, Is.EqualTo(1000m + executable));
        }

        [Test]
        public void FloatingIncludesCloseSlippageAndRoundTripCommission()
        {
            var p = Harness.Defaults() with { CommissionPerLot = 5m, Slippage = 0.1m };
            var h = new Harness(p, null, 1000m);
            h.Anchor();
            var quote = h.AtUpper(); // BUY 0.01 at the ask plus slippage 2020.1
            var basket = h.Engine.Basket!;

            var expected = BasketEconomics.ExecutableProfit(basket, quote.Bid - 0.1m, quote.Ask + 0.1m, p);
            Assert.That(expected, Is.EqualTo(-0.45m), "price P/L -0.40 less the 5 * 0.01 round-trip commission");
            Assert.That(h.ResearchAccount!.FloatingProfit, Is.EqualTo(expected));
            Assert.That(h.ResearchAccount.Equity, Is.EqualTo(1000m + expected));
        }
    }

    /// <summary>
    /// The observation timing of roadmap section 3.14: the incoming quote valuation is observed
    /// before an exit can remove the basket, and the post-entry valuation is observed after the
    /// new leg and its immediate execution costs are in the ledger.
    /// </summary>
    [TestFixture]
    public class ResearchAccountObservationTimingTests
    {
        [Test]
        public void ExitTickValuationIsObservedBeforeTheBasketCloses()
        {
            var h = TwoLegs.Build(Harness.Defaults(), 1000m);
            var account = h.ResearchAccount!;

            h.Feed(1900m, 1900.2m); // the escape quote itself: profit 39.6
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Record.RealizedProfit, Is.EqualTo(39.6m));

            Assert.That(account.MaxExecutableFloatingProfit, Is.EqualTo(39.6m), "the exit tick's valuation is not lost");
            Assert.That(account.MaxExecutableFloatingLoss, Is.EqualTo(-40.4m));
            Assert.That(account.PeakEquity, Is.EqualTo(1039.6m));
            Assert.That(account.MaxEquityDrawdown, Is.EqualTo(40.4m));

            var record = account.BasketRecords[0];
            Assert.That(record.MaxExecutableFloatingProfit, Is.EqualTo(39.6m));
            Assert.That(record.MaxExecutableFloatingLoss, Is.EqualTo(-40.4m));
        }

        [Test]
        public void PostEntryCostsAreObservedOnTheEntryTick()
        {
            var p = Harness.Defaults() with { CommissionPerLot = 5m };
            var h = new Harness(p, null, 1000m);
            h.Anchor();
            h.AtUpper(); // BUY 0.01 at 2020, price P/L at bid 2019.8 = -0.20, commission 0.05

            Assert.That(h.ResearchAccount!.MaxExecutableFloatingLoss, Is.EqualTo(-0.25m));
            Assert.That(h.ResearchAccount.FloatingProfit, Is.EqualTo(-0.25m));
            Assert.That(h.ResearchAccount.Equity, Is.EqualTo(999.75m));
        }

        [Test]
        public void PostEntryObservationSurvivesAHardBreakevenViolation()
        {
            var h = new Harness(Harness.NoExits(), null, 1000m);
            var basket = h.PingPongFourLegs();
            h.Executor.EntryOverride = _ => EntryExecution.Filled(2030m); // departs from the sizing model

            Assert.Throws<StrategyInvariantException>(() => h.AtUpper());

            var account = h.ResearchAccount!;
            Assert.That(basket.OpenPositions, Is.EqualTo(5), "the faulting leg stays in the ledger for the post-mortem");
            Assert.That(account.CurrentOpenPositions, Is.EqualTo(5), "the post-entry observation happened before the fault");
            var expected = BasketEconomics.ExecutableProfit(basket, 2019.8m, 2020m, h.Parameters);
            Assert.That(expected, Is.EqualTo(-302m));
            Assert.That(account.FloatingProfit, Is.EqualTo(expected));
            Assert.That(account.MaxExecutableFloatingLoss, Is.EqualTo(expected));
            Assert.That(account.FloatingObservable, Is.True);
        }

        [Test]
        public void QuoteOnlyBufferQuoteUpdatesTheAccountButNotTheStrategy()
        {
            var sessions = new[] { new HistoricalSession(new DateTime(2024, 1, 2, 9, 0, 0), new DateTime(2024, 1, 2, 9, 30, 0)) };
            var availability = new HistoricalTradingAvailability(sessions);
            var h = new Harness(Harness.Defaults(), availability, 1000m);
            var account = h.ResearchAccount!;

            h.FeedAt(new DateTime(2024, 1, 2, 9, 6, 0), 1999.9m, 2000.1m);
            h.FeedAt(new DateTime(2024, 1, 2, 9, 6, 1), 2019.8m, 2020m); // BUY 0.01
            h.FeedAt(new DateTime(2024, 1, 2, 9, 6, 2), 1980m, 1980.2m); // SELL 0.02

            // 09:26 is in the closing buffer (09:25, 09:30]: observed, never strategy-eligible.
            h.FeedAt(new DateTime(2024, 1, 2, 9, 26, 0), 1900m, 1900.2m);

            Assert.That(h.Engine.QuoteOnlyQuotes, Is.EqualTo(1));
            Assert.That(h.BasketsClosed, Is.Empty, "the quote-only quote cannot fire the escape exit");
            Assert.That(h.Engine.RealizedProfit, Is.EqualTo(0m));
            Assert.That(account.Balance, Is.EqualTo(1000m));
            Assert.That(account.MaxExecutableFloatingProfit, Is.EqualTo(39.6m), "the account still marks the basket to the delivered quote");
            Assert.That(account.Equity, Is.EqualTo(1039.6m));
        }

        [Test]
        public void EndOfRunMarkIsObservedWithTheLastProcessedQuote()
        {
            var p = Harness.Defaults();
            var h = new Harness(p, null, 1000m);
            h.Anchor();
            h.AtUpper(); // BUY 0.01 at 2020
            var last = h.Feed(1999.9m, 2000.1m);

            h.ResearchAccount!.ObserveEndOfRun(last, h.Engine.Basket, h.Engine.RealizedProfit);
            var expected = BasketEconomics.ExecutableProfit(h.Engine.Basket!, last.Bid, last.Ask, p);
            Assert.That(expected, Is.EqualTo(-20.1m));
            Assert.That(h.ResearchAccount.FloatingProfit, Is.EqualTo(expected));
            Assert.That(h.ResearchAccount.Equity, Is.EqualTo(1000m + expected));
        }

        [Test]
        public void AFailedCloseLeavesTheBasketAndTheObservedExtremaIntact()
        {
            var h = TwoLegs.Build(Harness.Defaults(), 1000m);
            var account = h.ResearchAccount!;
            h.Executor.CloseOverride = _ => CloseExecution.Failure("injected close failure");

            h.Feed(1900m, 1900.2m);

            Assert.That(h.CloseFailures, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed, Is.Empty);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(2));
            Assert.That(account.MaxExecutableFloatingProfit, Is.EqualTo(39.6m));
            Assert.That(account.Balance, Is.EqualTo(1000m));
        }

        [Test]
        public void UnusableExecutablePricesSkipTheFloatingObservation()
        {
            var p = Harness.Defaults() with { Slippage = 2500m };
            var h = new Harness(p, null, 1000m);
            h.Anchor();
            h.AtUpper(); // the BUY close price bid - slippage is not positive

            Assert.That(h.ResearchAccount!.MaxExecutableFloatingProfit, Is.Null);
            Assert.That(h.ResearchAccount.MaxExecutableFloatingLoss, Is.Null);
            Assert.That(h.ResearchAccount.FloatingProfit, Is.EqualTo(0m), "no fabricated executable mark");
            Assert.That(h.ResearchAccount.FloatingObservable, Is.False, "the unobservable mark is explicit, not presented as current");
            Assert.That(h.ResearchAccount.Summary.FloatingObservable, Is.False);
            Assert.That(h.ResearchAccount.Equity, Is.EqualTo(1000m));
        }
    }

    /// <summary>
    /// The per-basket research record of roadmap section 3.13: path extrema, tail-lot concepts
    /// kept separate and rejection attempts distinguished from rejection episodes.
    /// </summary>
    [TestFixture]
    public class ResearchAccountBasketRecordTests
    {
        [Test]
        public void FiveLegTailBasketRecordCarriesThePathAndTailFacts()
        {
            var h = new Harness(Harness.Defaults(), null, 1000m);
            var basket = h.PingPongFourLegs();
            h.AtUpper(); // trade 5: BUY 0.06, hard-BE
            Assert.That(basket.OpenPositions, Is.EqualTo(5));
            var last = h.Feed(2100m, 2100.2m); // escape close at 78.8

            var account = h.ResearchAccount!;
            Assert.That(account.BasketRecords, Has.Count.EqualTo(1));
            var record = account.BasketRecords[0];

            Assert.That(record.Basket, Is.EqualTo(1));
            Assert.That(record.AnchorTime, Is.EqualTo(Harness.T0));
            Assert.That(record.FirstEntryTime, Is.EqualTo(Harness.T0.AddSeconds(1)));
            Assert.That(record.CloseTime, Is.EqualTo(last.Time));
            Assert.That(record.DurationFromFirstEntrySeconds, Is.EqualTo(5m));
            Assert.That(record.FirstSide, Is.EqualTo(TradeSide.Buy));
            Assert.That(record.EntryCount, Is.EqualTo(5));
            Assert.That(record.DeepestTradeNumber, Is.EqualTo(5));
            Assert.That(record.MaxOpenPositions, Is.EqualTo(5));
            Assert.That(record.MaxGrossLots, Is.EqualTo(0.16m));
            Assert.That(record.MaxAbsoluteNetLots, Is.EqualTo(0.04m));
            Assert.That(record.MaxIndividualPlacedLot, Is.EqualTo(0.06m));
            Assert.That(record.MaxExecutableFloatingProfit, Is.EqualTo(78.8m));
            Assert.That(record.MaxExecutableFloatingLoss, Is.EqualTo(-242m));
            Assert.That(record.CloseReason, Is.EqualTo(ExitReason.Escape));
            Assert.That(record.RealizedProfit, Is.EqualTo(78.8m));
            Assert.That(record.HardBreakevenModeActivated, Is.True);
            Assert.That(record.FirstHardBreakevenTradeNumber, Is.EqualTo(5));
            Assert.That(record.LargestExactRequiredTailLot, Is.EqualTo(380.32m / 6956m));
            Assert.That(record.LargestNormalizedRequiredTailLot, Is.EqualTo(0.06m));
            Assert.That(record.LargestPlacedTailLot, Is.EqualTo(0.06m));
            Assert.That(record.HardBreakevenRejectedAttempts, Is.EqualTo(0));
            Assert.That(record.HardBreakevenRejectionEpisodes, Is.EqualTo(0));
            Assert.That(record.Rejections, Is.Empty);
        }

        [Test]
        public void RejectionAttemptsAndEpisodesStayDistinctInTheBasketRecord()
        {
            var p = Harness.Defaults() with { MaximumVolume = 0.05m };
            var h = new Harness(p, null, 1000m);
            h.PingPongFourLegs();
            h.AtUpper();                       // trade 5 requires 0.06 > 0.05: episode starts
            h.AtUpper();                       // the same episode
            h.Feed(2060m, 2060.2m);            // a larger normalized requirement: still the episode
            h.Feed(1898.4m, 1898.6m);          // escape at exactly 2

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            var record = h.ResearchAccount!.BasketRecords[0];
            Assert.That(record.EntryCount, Is.EqualTo(4));
            Assert.That(record.DeepestTradeNumber, Is.EqualTo(5), "the infeasible trade 5 was attempted even though no leg was placed");
            Assert.That(record.HardBreakevenModeActivated, Is.True);
            Assert.That(record.FirstHardBreakevenTradeNumber, Is.EqualTo(5));
            Assert.That(record.HardBreakevenRejectedAttempts, Is.EqualTo(3), "every attempt is counted");
            Assert.That(record.HardBreakevenRejectionEpisodes, Is.EqualTo(1), "the repeats fold into one episode");
            Assert.That(record.LargestExactRequiredTailLot, Is.EqualTo(380.32m / 2936m), "the entry ask 2060.2 makes one lot worth 2936 at the boundary");
            Assert.That(record.LargestNormalizedRequiredTailLot, Is.EqualTo(0.13m));
            Assert.That(record.LargestPlacedTailLot, Is.Null, "no tail leg was ever placed");
            Assert.That(record.Rejections, Has.Count.EqualTo(1));
            Assert.That(record.Rejections[0].Reason, Is.EqualTo(EntryRejectionReason.HardBreakevenInfeasible));
            Assert.That(record.Rejections[0].Outcome, Is.EqualTo(HardBreakevenOutcome.ExceedsMaximumVolume));
            Assert.That(record.Rejections[0].Episodes, Is.EqualTo(1));
            Assert.That(record.Rejections[0].Attempts, Is.EqualTo(3));
        }

        [Test]
        public void AFeasibleTailWhoseExecutionFailsStillContributesItsRequirement()
        {
            var h = new Harness(Harness.Defaults(), null, 1000m);
            h.PingPongFourLegs();
            h.Executor.EntryOverride = order => order.TradeNumber == 5
                ? EntryExecution.Failure("injected execution failure")
                : EntryExecution.Filled(BasketEconomics.ExecutableEntryPrice(order.Side, order.Quote, h.Parameters));

            h.AtUpper();                 // trade 5: the sizing is feasible but the execution fails
            h.Feed(1898.4m, 1898.6m);    // no retry: escape closes the four-leg basket at 2

            var record = h.ResearchAccount!.BasketRecords[0];
            Assert.That(record.EntryCount, Is.EqualTo(4));
            Assert.That(record.DeepestTradeNumber, Is.EqualTo(5), "the failed tail attempt is the deepest trade number");
            Assert.That(record.LargestPlacedTailLot, Is.Null, "no tail leg was placed, so the maxima can only come from the rejection row");
            Assert.That(record.Rejections, Has.Count.EqualTo(1));
            Assert.That(record.Rejections[0].Reason, Is.EqualTo(EntryRejectionReason.ExecutionFailed));
            Assert.That(record.Rejections[0].Outcome, Is.EqualTo(HardBreakevenOutcome.Feasible));
            Assert.That(record.HardBreakevenRejectedAttempts, Is.EqualTo(0), "an execution failure is counted by its reason, not as hard-BE infeasibility");
            Assert.That(record.HardBreakevenRejectionEpisodes, Is.EqualTo(0));
            Assert.That(record.LargestExactRequiredTailLot, Is.EqualTo(380.32m / 6956m));
            Assert.That(record.LargestNormalizedRequiredTailLot, Is.EqualTo(0.06m));
        }

        [Test]
        public void ArithmeticRejectionIsCountedByReasonWithoutAnOutcome()
        {
            var p = Harness.NoExits() with { BaseLot = 60m, FixedTakeProfitUnits = 0.05m };
            var h = new Harness(p, null, 1000m);
            h.Anchor();
            h.AtUpper();                       // BUY 60 lots, placed
            h.AtLower();                       // trade 2 = 120 lots > 100: rejected
            h.Feed(2021m, 2021.2m);            // fixed TP at 6000

            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            var record = h.ResearchAccount!.BasketRecords[0];
            Assert.That(record.EntryCount, Is.EqualTo(1));
            Assert.That(record.MaxIndividualPlacedLot, Is.EqualTo(60m));
            Assert.That(record.HardBreakevenModeActivated, Is.False);
            Assert.That(record.FirstHardBreakevenTradeNumber, Is.Null);
            Assert.That(record.HardBreakevenRejectedAttempts, Is.EqualTo(0));
            Assert.That(record.HardBreakevenRejectionEpisodes, Is.EqualTo(0));
            Assert.That(record.Rejections, Has.Count.EqualTo(1));
            Assert.That(record.Rejections[0].Reason, Is.EqualTo(EntryRejectionReason.VolumeExceedsMaximum));
            Assert.That(record.Rejections[0].Outcome, Is.Null);
            Assert.That(record.Rejections[0].Episodes, Is.EqualTo(1));
            Assert.That(record.Rejections[0].Attempts, Is.EqualTo(1));
        }
    }

    /// <summary>
    /// The run-level analytics of roadmap section 3.12.
    /// </summary>
    [TestFixture]
    public class ResearchAccountRunAggregateTests
    {
        [Test]
        public void RunExposureMaximaCoverEveryBasket()
        {
            var h = new Harness(Harness.Defaults(), null, 1000m);
            h.PingPongFourLegs();
            var account = h.ResearchAccount!;

            Assert.That(account.MaxOpenPositions, Is.EqualTo(4));
            Assert.That(account.MaxGrossLots, Is.EqualTo(0.10m));
            Assert.That(account.MaxAbsoluteNetLots, Is.EqualTo(0.02m));
            Assert.That(account.CurrentOpenPositions, Is.EqualTo(4));
            Assert.That(account.CurrentGrossLots, Is.EqualTo(0.10m));
            Assert.That(account.CurrentAbsoluteNetLots, Is.EqualTo(0.02m));

            h.Feed(1898.4m, 1898.6m); // escape at exactly 2
            Assert.That(account.CurrentOpenPositions, Is.EqualTo(0));
            Assert.That(account.CurrentGrossLots, Is.EqualTo(0m));
            Assert.That(account.CurrentAbsoluteNetLots, Is.EqualTo(0m));
            Assert.That(account.MaxOpenPositions, Is.EqualTo(4), "the maximum is not reset by a close");
        }

        [Test]
        public void PeakBalanceAndDrawdownFollowRealizedChanges()
        {
            var account = new SingleAnchorResearchAccount(Harness.Defaults(), 1000m);
            account.ObserveQuote(default, null, 100m);  // balance 1100
            account.ObserveQuote(default, null, -50m);  // balance 950

            Assert.That(account.PeakBalance, Is.EqualTo(1100m));
            Assert.That(account.Balance, Is.EqualTo(950m));
            Assert.That(account.MaxBalanceDrawdown, Is.EqualTo(150m));
            Assert.That(account.PeakEquity, Is.EqualTo(1100m));
            Assert.That(account.Equity, Is.EqualTo(950m));
            Assert.That(account.MaxEquityDrawdown, Is.EqualTo(150m));
        }

        [Test]
        public void NoActivityKeepsTheInitialAccount()
        {
            var account = new SingleAnchorResearchAccount(Harness.Defaults(), 1000m);
            var summary = account.Summary;

            Assert.That(summary.InitialBalance, Is.EqualTo(1000m));
            Assert.That(summary.Balance, Is.EqualTo(1000m));
            Assert.That(summary.Equity, Is.EqualTo(1000m));
            Assert.That(summary.FloatingProfit, Is.EqualTo(0m));
            Assert.That(summary.RealizedProfit, Is.EqualTo(0m));
            Assert.That(summary.PeakBalance, Is.EqualTo(1000m));
            Assert.That(summary.MaxBalanceDrawdown, Is.EqualTo(0m));
            Assert.That(summary.PeakEquity, Is.EqualTo(1000m));
            Assert.That(summary.MaxEquityDrawdown, Is.EqualTo(0m));
            Assert.That(summary.MaxExecutableFloatingProfit, Is.Null);
            Assert.That(summary.MaxExecutableFloatingLoss, Is.Null);
            Assert.That(summary.ClosedBasketsObserved, Is.EqualTo(0));
        }

        [Test]
        public void EveryClosedBasketKeepsOneResearchRecordInOrder()
        {
            var h = new Harness(Harness.Defaults(), null, 1000m);
            h.Anchor();
            h.AtUpper();
            h.AtLower();
            h.Feed(1900m, 1900.2m);       // basket 1 escapes at 39.6

            h.Feed(1899.9m, 1900.1m);     // basket 2 anchors at 1900, step 19
            h.Feed(1919m, 1919.2m);       // BUY 0.01 at 1919.2
            h.Feed(1881m, 1881.2m);       // SELL 0.02 at 1881
            h.Feed(1841.45m, 1841.65m);   // escape at exactly 0.95

            var account = h.ResearchAccount!;
            Assert.That(h.Engine.BasketsClosed, Is.EqualTo(2));
            Assert.That(account.BasketRecords, Has.Count.EqualTo(2));
            Assert.That(account.BasketRecords[0].Basket, Is.EqualTo(1));
            Assert.That(account.BasketRecords[1].Basket, Is.EqualTo(2));
            Assert.That(account.BasketRecords[0].RealizedProfit, Is.EqualTo(39.6m));
            Assert.That(account.BasketRecords[1].RealizedProfit, Is.EqualTo(0.95m));
            Assert.That(account.Balance, Is.EqualTo(1000m + 39.6m + 0.95m));
        }
    }

    /// <summary>
    /// Bounded retention and per-quote work (roadmap sections 3.12 and 3.15): the account keeps
    /// one record per closed basket, nothing per quote, and its steady-state observation path
    /// allocates nothing.
    /// </summary>
    [TestFixture]
    public class ResearchAccountBoundednessTests
    {
        [Test]
        public void ARepeatingRejectionStaysCompactInTheBasketRecord()
        {
            var p = Harness.Defaults() with { MaximumVolume = 0.05m };
            var h = new Harness(p, null, 1000m);
            h.PingPongFourLegs();
            for (var i = 0; i < 100_000; i++)
            {
                h.AtUpper();
            }

            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(100_000));
            Assert.That(h.ResearchAccount!.BasketRecords, Is.Empty, "the basket is still open; nothing is retained per quote");

            h.Feed(1898.4m, 1898.6m);
            var record = h.ResearchAccount!.BasketRecords[0];
            Assert.That(record.HardBreakevenRejectedAttempts, Is.EqualTo(100_000));
            Assert.That(record.HardBreakevenRejectionEpisodes, Is.EqualTo(1));
            Assert.That(record.Rejections, Has.Count.EqualTo(1));
            Assert.That(record.Rejections[0].Attempts, Is.EqualTo(100_000));
        }

        [Test]
        public void ObservingQuotesAllocatesNothingOnTheSteadyStatePath()
        {
            var p = Harness.Defaults();
            var account = new SingleAnchorResearchAccount(p, 1000m);
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            var quote = new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m);

            var allocated = MeasureSteadyStateAllocation(() => account.ObserveQuote(quote, basket, 0m));
            Assert.That(allocated, Is.EqualTo(0), "the per-quote research observation must not allocate");
        }

        [Test]
        public void SkippingAnUnobservableMarkAllocatesNothing()
        {
            var p = Harness.Defaults() with { Slippage = 2500m };
            var account = new SingleAnchorResearchAccount(p, 1000m);
            var basket = new Basket(1, new Quote(Harness.T0, 1999.9m, 2000.1m), p);
            basket.AddLeg(new BasketLeg(1, TradeSide.Buy, 0.01m, 2020m, Harness.T0, SizingRegime.Arithmetic));
            var quote = new Quote(Harness.T0.AddSeconds(1), 2019.8m, 2020m);

            var allocated = MeasureSteadyStateAllocation(() => account.ObserveQuote(quote, basket, 0m));
            Assert.That(allocated, Is.EqualTo(0), "the skipped-observation branch must not allocate either");
            Assert.That(account.FloatingObservable, Is.False);
        }

        /// <summary>
        /// Measures the managed allocation of one observation action over one million calls
        /// after a one-million-call warm-up. The measurement runs on a dedicated thread so the
        /// per-thread allocation counter sees only the observed action (the test runner's own
        /// thread activity stays outside).
        /// </summary>
        private static long MeasureSteadyStateAllocation(Action observe)
        {
            var allocated = 0L;
            Exception? failure = null;
            var thread = new System.Threading.Thread(() =>
            {
                try
                {
                    for (var i = 0; i < 1_000_000; i++)
                    {
                        observe();
                    }
                    var before = GC.GetAllocatedBytesForCurrentThread();
                    for (var i = 0; i < 1_000_000; i++)
                    {
                        observe();
                    }
                    allocated = GC.GetAllocatedBytesForCurrentThread() - before;
                }
                catch (Exception error)
                {
                    failure = error;
                }
            });
            thread.Start();
            thread.Join();

            Assert.That(failure, Is.Null);
            return allocated;
        }
    }

    /// <summary>
    /// Roadmap section 3.15: with the research account enabled the strategy path must be exactly
    /// the same in anchors, entries, lots, rejections, closes, realized strategy P/L and the
    /// end-of-data basket state.
    /// </summary>
    [TestFixture]
    public class ResearchAccountParityTests
    {
        [Test]
        public void EnablingTheAccountChangesNoStrategyOutcome()
        {
            var p = Harness.Defaults() with
            {
                StepPercent = 0.5m,
                HardBreakevenCeilingPercent = 0.3m,
                MaximumVolume = 0.05m
            };
            var withAccount = new Harness(p, null, 1000m);
            var without = new Harness(p);

            foreach (var quote in DeterministicStream())
            {
                withAccount.Engine.OnQuote(quote);
                without.Engine.OnQuote(quote);
            }

            Assert.That(withAccount.Engine.EntriesOpened, Is.GreaterThan(0), "the stream must exercise entries for the parity claim to mean anything");
            Assert.That(withAccount.Engine.BasketsClosed, Is.GreaterThan(0), "the stream must exercise closes");
            Assert.That(withAccount.Engine.RejectedEntryAttempts, Is.GreaterThan(0), "the stream must exercise rejected attempts");
            Assert.That(withAccount.Engine.SkippedFirstEntryQuotes, Is.GreaterThan(0), "the stream must exercise the ambiguous first-entry skip");

            Assert.That(withAccount.Engine.QuotesProcessed, Is.EqualTo(without.Engine.QuotesProcessed));
            Assert.That(withAccount.Engine.QuoteOnlyQuotes, Is.EqualTo(without.Engine.QuoteOnlyQuotes));
            Assert.That(withAccount.Engine.StrategyEligibleQuotes, Is.EqualTo(without.Engine.StrategyEligibleQuotes));
            Assert.That(withAccount.Engine.EntriesOpened, Is.EqualTo(without.Engine.EntriesOpened));
            Assert.That(withAccount.Engine.EntriesRejected, Is.EqualTo(without.Engine.EntriesRejected));
            Assert.That(withAccount.Engine.RejectedEntryAttempts, Is.EqualTo(without.Engine.RejectedEntryAttempts));
            Assert.That(withAccount.Engine.SkippedFirstEntryQuotes, Is.EqualTo(without.Engine.SkippedFirstEntryQuotes));
            Assert.That(withAccount.Engine.BasketsClosed, Is.EqualTo(without.Engine.BasketsClosed));
            Assert.That(withAccount.Engine.RealizedProfit, Is.EqualTo(without.Engine.RealizedProfit));
            Assert.That(StrategyProjection(withAccount.Engine), Is.EqualTo(StrategyProjection(without.Engine)));
        }

        [Test]
        public void QuoteOnlyQuotesAreObservedWithoutChangingTheStrategyPath()
        {
            // One completed 50-minute session: the first and last five minutes are quote-only.
            var sessions = new[] { new HistoricalSession(new DateTime(2024, 3, 1, 0, 0, 0), new DateTime(2024, 3, 1, 0, 50, 0)) };
            var p = Harness.Defaults() with
            {
                StepPercent = 0.5m,
                HardBreakevenCeilingPercent = 0.3m,
                MaximumVolume = 0.05m
            };
            var withAccount = new Harness(p, new HistoricalTradingAvailability(sessions), 1000m);
            var without = new Harness(p, new HistoricalTradingAvailability(sessions));

            foreach (var quote in DeterministicStream())
            {
                withAccount.Engine.OnQuote(quote);
                without.Engine.OnQuote(quote);
            }

            Assert.That(withAccount.Engine.QuoteOnlyQuotes, Is.GreaterThan(0), "the session buffers must classify quotes quote-only");
            Assert.That(withAccount.Engine.StrategyEligibleQuotes, Is.EqualTo(without.Engine.StrategyEligibleQuotes));
            Assert.That(StrategyProjection(withAccount.Engine), Is.EqualTo(StrategyProjection(without.Engine)));
            Assert.That(withAccount.ResearchAccount!.Balance, Is.EqualTo(withAccount.ResearchAccount.InitialBalance + withAccount.Engine.RealizedProfit));
        }

        private static List<Quote> DeterministicStream()
        {
            var quotes = new List<Quote>();
            var time = new DateTime(2024, 3, 1, 0, 0, 0);
            var price = 2000m;
            quotes.Add(new Quote(time, price, price + 0.2m));                    // anchors at 2000
            quotes.Add(new Quote(time.AddMilliseconds(1), price - 30m, price + 30m)); // both boundaries: skipped
            var seed = 987654321;
            for (var i = 1; i < 3000; i++)
            {
                seed = (int)((seed * 1103515245L + 12345L) & 0x7fffffffL);
                var delta = ((seed % 11) - 5) * 0.9m;
                price = Math.Clamp(price + delta, 1850m, 2150m);
                quotes.Add(new Quote(time.AddSeconds(i), price, price + 0.2m));
            }
            return quotes;
        }

        /// <summary>The strategy-facing projection of a run: records, traces and final basket state.</summary>
        private static string StrategyProjection(SingleAnchorEngine engine)
        {
            var payload = new
            {
                engine.QuotesProcessed,
                engine.QuoteOnlyQuotes,
                engine.StrategyEligibleQuotes,
                engine.EntriesOpened,
                engine.EntriesRejected,
                engine.RejectedEntryAttempts,
                engine.SkippedFirstEntryQuotes,
                engine.BasketsClosed,
                engine.RealizedProfit,
                ClosedBaskets = engine.ClosedBaskets,
                LastProcessedQuote = engine.LastProcessedQuote,
                OpenBasket = engine.LastProcessedQuote.HasValue ? engine.MarkToMarket(engine.LastProcessedQuote.Value) : null
            };
            return JsonSerializer.Serialize(payload);
        }
    }
}
