using System;
using NUnit.Framework;

namespace MarketLab.SingleAnchor.Tests
{
    [TestFixture]
    public class LifecycleTests
    {
        [Test]
        public void ClosingResetsBasketTrailingAndTradeSequenceState()
        {
            var h = new Harness();
            var first = h.PingPongFourLegs();
            h.AtUpper();                                  // trade 5, hard-BE mode
            Assert.That(first.HardBreakevenModeActive, Is.True);
            Assert.That(first.OpenPositions, Is.EqualTo(5));

            // net long 0.04: a rally gives profit 78.8 >= escape 4 (M_step 80)
            var closing = h.Feed(2100m, 2100.2m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Reason, Is.EqualTo(ExitReason.Escape));
            Assert.That(h.BasketsClosed[0].ExitProfit, Is.EqualTo(78.8m));
            Assert.That(h.BasketsClosed[0].Quote, Is.EqualTo(closing));
            Assert.That(h.Engine.Basket, Is.Null, "no basket until the next quote");
            Assert.That(h.Engine.BasketsClosed, Is.EqualTo(1));

            var next = h.Feed(2099.9m, 2100.1m);          // a later quote anchors afresh
            var second = h.Engine.Basket;
            Assert.That(second, Is.Not.Null);
            Assert.That(second, Is.Not.SameAs(first));
            Assert.That(second!.Anchor, Is.EqualTo(next.Mid));
            Assert.That(second.Anchor, Is.EqualTo(2100m));
            Assert.That(second.Upper, Is.EqualTo(2121m));
            Assert.That(second.Lower, Is.EqualTo(2079m));
            Assert.That(second.OpenPositions, Is.EqualTo(0));
            Assert.That(second.HardBreakevenModeActive, Is.False);
            Assert.That(second.TrailingActive, Is.False);
            Assert.That(second.PeakProfit, Is.EqualTo(0m));
            Assert.That(second.LastSide, Is.Null);
            Assert.That(second.NextTradeNumber, Is.EqualTo(1));
            Assert.That(second.LastRejection, Is.Null);
            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(2));

            h.Feed(2120.8m, 2121m);                       // first trade of the new basket
            Assert.That(second.Legs[0].TradeNumber, Is.EqualTo(1));
            Assert.That(second.Legs[0].Lots, Is.EqualTo(0.01m));
            Assert.That(second.Legs[0].Regime, Is.EqualTo(SizingRegime.Arithmetic));
        }

        [Test]
        public void NoReplacementBasketIsInitializedOnTheClosingQuote()
        {
            var h = TwoLegs.Build();
            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(1));

            h.Feed(1900m, 1900.2m);                       // escape close

            Assert.That(h.Engine.Basket, Is.Null);
            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(1));
            Assert.That(h.Executor.Entries, Has.Count.EqualTo(2));

            h.Feed(1900m, 1900.2m);                       // the very next quote, same prices: new anchor, no entry
            Assert.That(h.AnchorsCreated, Has.Count.EqualTo(2));
            Assert.That(h.Engine.Basket!.Anchor, Is.EqualTo(1900.1m));
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));
        }

        [Test]
        public void ClosedBasketObjectIsDetachedAndKeepsItsLedger()
        {
            var h = TwoLegs.Build();
            var basket = h.Engine.Basket!;
            h.Feed(1900m, 1900.2m);
            h.Feed(1900m, 1900.2m);

            Assert.That(basket.OpenPositions, Is.EqualTo(2));
            Assert.That(basket.Legs[0].EntryPrice, Is.EqualTo(2020m));
            Assert.That(h.BasketsClosed[0].RawProfit, Is.EqualTo(39.6m));
        }

        [Test]
        public void OpenBasketIsMarkedToMarketNotClosedAtTheEndOfData()
        {
            var h = TwoLegs.Build();
            var basket = h.Engine.Basket!;
            var last = h.Feed(2000m, 2000.3m);

            var valuation = h.Engine.MarkToMarket(last);

            Assert.That(valuation, Is.Not.Null);
            Assert.That(valuation!.Quote, Is.EqualTo(last));
            Assert.That(valuation.OpenPositions, Is.EqualTo(2));
            Assert.That(valuation.BuyLots, Is.EqualTo(0.01m));
            Assert.That(valuation.SellLots, Is.EqualTo(0.02m));
            Assert.That(valuation.GrossLots, Is.EqualTo(0.03m));
            Assert.That(valuation.NetLots, Is.EqualTo(-0.01m));
            Assert.That(valuation.RawProfit, Is.EqualTo(-60.6m));
            Assert.That(valuation.ExitProfit, Is.EqualTo(-60.6m));
            Assert.That(valuation.StepMoney, Is.EqualTo(20m));
            Assert.That(valuation.HardBreakevenModeActive, Is.False);
            Assert.That(valuation.TrailingActive, Is.False);

            Assert.That(h.Engine.Basket, Is.SameAs(basket), "still open");
            Assert.That(basket.OpenPositions, Is.EqualTo(2));
            Assert.That(h.BasketsClosed, Is.Empty);
            Assert.That(h.Executor.Closes, Is.Empty);
        }

        [Test]
        public void MarkToMarketIsNullWithoutOpenLegs()
        {
            var h = new Harness();
            Assert.That(h.Engine.MarkToMarket(new Quote(Harness.T0, 2000m, 2000.2m)), Is.Null);
            h.Anchor();
            Assert.That(h.Engine.MarkToMarket(new Quote(Harness.T0, 2000m, 2000.2m)), Is.Null);
        }
    }

    [TestFixture]
    public class ExecutionFailureTests
    {
        [Test]
        public void RejectedEntryIsSurfacedOnceAndTheGridWaits()
        {
            var h = new Harness();
            h.Executor.EntryOverride = _ => ExecutionResult.Failure("insufficient margin");
            h.Anchor();
            h.AtUpper();
            h.AtUpper();

            var basket = h.Engine.Basket!;
            Assert.That(basket.OpenPositions, Is.EqualTo(0));
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.ExecutionFailed));
            Assert.That(h.EntriesRejected[0].Rejection.Message, Is.EqualTo("insufficient margin"));
            Assert.That(h.Engine.RejectedEntryAttempts, Is.EqualTo(2));
            Assert.That(h.Engine.EntriesRejected, Is.EqualTo(1));

            h.Executor.EntryOverride = null;
            h.AtUpper();
            Assert.That(basket.OpenPositions, Is.EqualTo(1));
            Assert.That(basket.LastRejection, Is.Null, "a filled entry clears the rejection state");
            Assert.That(h.Engine.EntriesOpened, Is.EqualTo(1));
        }

        [Test]
        public void UnusableFillIsTreatedAsAFailure()
        {
            var h = new Harness();
            h.Executor.EntryOverride = _ => ExecutionResult.Fill(0m, 0.01m);
            h.Anchor();
            h.AtUpper();

            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.ExecutionFailed));
        }

        [Test]
        public void FailedCloseKeepsTheBasketBlocksEntriesOnThatQuoteAndIsRetried()
        {
            var h = new Harness();
            h.Anchor();
            h.AtUpper();                                  // BUY 0.01 @ 2020
            h.Feed(2035m, 2035.2m);                       // trailing active, floor 10
            var basket = h.Engine.Basket!;

            h.Executor.CloseOverride = _ => ExecutionResult.Failure("broker busy");
            h.AtLower();                                  // trailing close fires and fails; SELL trigger is also true

            Assert.That(h.CloseFailures, Has.Count.EqualTo(1));
            Assert.That(h.CloseFailures[0].Reason, Is.EqualTo(ExitReason.Trailing));
            Assert.That(h.CloseFailures[0].Message, Is.EqualTo("broker busy"));
            Assert.That(h.Engine.Basket, Is.SameAs(basket));
            Assert.That(basket.OpenPositions, Is.EqualTo(1), "no entry on a quote whose exit failed");
            Assert.That(h.Executor.Entries, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed, Is.Empty);

            h.Executor.CloseOverride = null;
            h.AtLower();
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Reason, Is.EqualTo(ExitReason.Trailing));
            Assert.That(h.Engine.Basket, Is.Null);
        }
    }

    [TestFixture]
    public class PendingExecutionTests
    {
        [Test]
        public void PendingEntryIsRecordedWithTheActualFillAndQuotesAreOnlyObservedMeanwhile()
        {
            var h = new Harness();
            h.Executor.EntryOverride = _ => ExecutionResult.Pending("submitted");
            h.Anchor();
            var trigger = h.AtUpper();
            var basket = h.Engine.Basket!;

            Assert.That(h.Engine.HasPendingExecution, Is.True);
            Assert.That(h.Engine.PendingEntryOrder, Is.Not.Null);
            Assert.That(h.Engine.PendingEntryOrder!.TradeNumber, Is.EqualTo(1));
            Assert.That(h.EntriesPending, Has.Count.EqualTo(1));
            Assert.That(basket.OpenPositions, Is.EqualTo(0));

            h.AtUpper();
            h.AtLower();                                  // would be a SELL trigger, but nothing happens while pending
            Assert.That(h.SkippedWhilePending, Has.Count.EqualTo(1), "reported once per pending operation");
            Assert.That(h.Executor.Entries, Has.Count.EqualTo(1));

            var fillTime = trigger.Time.AddMilliseconds(5);
            h.Engine.ConfirmPendingEntry(2020.05m, 0.01m, fillTime);

            Assert.That(h.Engine.HasPendingExecution, Is.False);
            Assert.That(basket.OpenPositions, Is.EqualTo(1));
            Assert.That(basket.Legs[0].EntryPrice, Is.EqualTo(2020.05m), "the ledger holds the host's fill, not the trigger price");
            Assert.That(basket.Legs[0].EntryTime, Is.EqualTo(fillTime));
            Assert.That(h.EntriesOpened, Has.Count.EqualTo(1));
            Assert.That(h.EntriesOpened[0].Quote, Is.EqualTo(trigger));

            h.Executor.EntryOverride = null;
            h.AtLower();                                  // normal operation resumes
            Assert.That(basket.OpenPositions, Is.EqualTo(2));
        }

        [Test]
        public void RejectedPendingEntryLeavesTheGridUnchanged()
        {
            var h = new Harness();
            h.Executor.EntryOverride = _ => ExecutionResult.Pending();
            h.Anchor();
            h.AtUpper();

            h.Engine.RejectPendingEntry("cancelled by broker");

            Assert.That(h.Engine.HasPendingExecution, Is.False);
            Assert.That(h.Engine.Basket!.OpenPositions, Is.EqualTo(0));
            Assert.That(h.EntriesRejected, Has.Count.EqualTo(1));
            Assert.That(h.EntriesRejected[0].Rejection.Reason, Is.EqualTo(EntryRejectionReason.ExecutionFailed));
            Assert.That(h.EntriesRejected[0].Rejection.Message, Is.EqualTo("cancelled by broker"));
        }

        [Test]
        public void PendingCloseCompletesOnConfirmationWithTheHostFill()
        {
            var h = TwoLegs.Build();
            var basket = h.Engine.Basket!;
            h.Executor.CloseOverride = _ => ExecutionResult.Pending();

            var closing = h.Feed(1900m, 1900.2m);
            Assert.That(h.ClosesPending, Has.Count.EqualTo(1));
            Assert.That(h.ClosesPending[0].Reason, Is.EqualTo(ExitReason.Escape));
            Assert.That(h.Engine.PendingCloseOrder, Is.Not.Null);
            Assert.That(h.Engine.Basket, Is.SameAs(basket), "still open until the host confirms");

            h.Feed(1890m, 1890.2m);
            h.Feed(1890m, 1890.2m);
            Assert.That(h.SkippedWhilePending, Has.Count.EqualTo(1));

            h.Engine.ConfirmPendingClose(1900.1m);

            Assert.That(h.Engine.Basket, Is.Null);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
            Assert.That(h.BasketsClosed[0].Quote, Is.EqualTo(closing), "profit is accounted at the closing quote");
            Assert.That(h.BasketsClosed[0].ExitProfit, Is.EqualTo(39.6m));
            Assert.That(h.BasketsClosed[0].HostFillPrice, Is.EqualTo(1900.1m));
            Assert.That(h.Engine.BasketsClosed, Is.EqualTo(1));
        }

        [Test]
        public void RejectedPendingCloseKeepsTheBasketAndTheExitIsReEvaluated()
        {
            var h = TwoLegs.Build();
            var basket = h.Engine.Basket!;
            h.Executor.CloseOverride = _ => ExecutionResult.Pending();
            h.Feed(1900m, 1900.2m);

            h.Engine.RejectPendingClose("rejected");

            Assert.That(h.CloseFailures, Has.Count.EqualTo(1));
            Assert.That(h.Engine.Basket, Is.SameAs(basket));
            Assert.That(basket.OpenPositions, Is.EqualTo(2));

            h.Executor.CloseOverride = null;
            h.Feed(1900m, 1900.2m);
            Assert.That(h.BasketsClosed, Has.Count.EqualTo(1));
        }

        [Test]
        public void ConfirmingWithoutAPendingOperationIsAProgrammingError()
        {
            var h = new Harness();
            Assert.Throws<InvalidOperationException>(() => h.Engine.ConfirmPendingEntry(1m, 1m, Harness.T0));
            Assert.Throws<InvalidOperationException>(() => h.Engine.RejectPendingEntry("x"));
            Assert.Throws<InvalidOperationException>(() => h.Engine.ConfirmPendingClose(null));
            Assert.Throws<InvalidOperationException>(() => h.Engine.RejectPendingClose("x"));
        }
    }
}
